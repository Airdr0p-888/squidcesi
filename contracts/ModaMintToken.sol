// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ModaMintToken — BSC 公平发射代币合约（v3 重写）
 * @notice 对应 launch.html 所有配置项：
 *   1. name_ / symbol_ / totalSupply_      — 代币基础信息
 *   2. mintCostBNB_ / fillBNB_             — Mint 价格 & 硬顶
 *   3. buyTax_ / sellTax_                  — 买卖税（bps，最大 2500 = 25%）
 *   4. marketingPct_ / burnPct_ /
 *      dividendPct_ / liquidityPct_        — 税收四项分配（bps，总和 ≤ 10000）
 *   5. marketingWallet_                    — 营销收款地址
 *   6. minHoldForDividend_                 — 最低持币分红门槛（wei）
 *   7. presaleTokenPct_                    — 预售占比（1-99）
 *   8. whitelistMintOnly_                  — 白名单模式
 *   9. lpTokenPct_                         — LP 额外代币比例（0-100）
 *  10. autoOpenTrading_                    — 开盘模式（true=自动，false=手动）
 *
 * 架构说明：
 *  - 主合约不处理 swap，税费代币全部转发给独立的 TaxDistributor 异步处理
 *  - 手动开盘：presale 满额后 tradingActive 不自动设 true，需 owner 调用 enableTrading()
 *  - 自动开盘：presale 满额后自动 tradingActive = true
 *  - 分红合约（ModaDividendTracker）在构造函数内自动部署，无需额外操作
 */

// ═══════════════════════════════════════════
//  Interfaces
// ═══════════════════════════════════════════

interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
}

interface ITaxDistributor {
    function tryProcess() external;
}

// ═══════════════════════════════════════════
//  Libraries
// ═══════════════════════════════════════════

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) { return a + b; }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) { return a - b; }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) { return a * b; }
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: div by zero");
        return a / b;
    }
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: mod by zero");
        return a % b;
    }
    function sub(uint256 a, uint256 b, string memory err) internal pure returns (uint256) {
        require(b <= a, err);
        return a - b;
    }
}

library SafeMathInt {
    int256 private constant MIN_INT256 = int256(0x8000000000000000000000000000000000000000000000000000000000000000);
    function mul(int256 a, int256 b) internal pure returns (int256) {
        int256 c = a * b;
        require(a == 0 || c / a == b, "SafeMathInt: mul overflow");
        return c;
    }
    function div(int256 a, int256 b) internal pure returns (int256) {
        require(b != 0, "SafeMathInt: div by zero");
        require(!(a == MIN_INT256 && b == -1), "SafeMathInt: overflow");
        return a / b;
    }
    function sub(int256 a, int256 b) internal pure returns (int256) {
        int256 c = a - b;
        require((b >= 0 && c <= a) || (b < 0 && c > a), "SafeMathInt: underflow");
        return c;
    }
    function add(int256 a, int256 b) internal pure returns (int256) {
        int256 c = a + b;
        require((b >= 0 && c >= a) || (b < 0 && c < a), "SafeMathInt: overflow");
        return c;
    }
    function toUint256Safe(int256 a) internal pure returns (uint256) {
        require(a >= 0, "SafeMathInt: negative value");
        return uint256(a);
    }
}

library SafeMathUint {
    function toInt256Safe(uint256 a) internal pure returns (int256) {
        int256 b = int256(a);
        require(b >= 0, "SafeMathUint: overflow");
        return b;
    }
}

library IterableMapping {
    struct Map {
        address[] keys;
        mapping(address => uint256) values;
        mapping(address => uint256) indexOf;
        mapping(address => bool) inserted;
    }

    function get(Map storage map, address key) internal view returns (uint256) {
        return map.values[key];
    }

    function getIndexOfKey(Map storage map, address key) internal view returns (int256) {
        if (!map.inserted[key]) return -1;
        return int256(map.indexOf[key]);
    }

    function size(Map storage map) internal view returns (uint256) {
        return map.keys.length;
    }

    function set(Map storage map, address key, uint256 val) internal {
        if (map.inserted[key]) {
            map.values[key] = val;
            return;
        }
        map.inserted[key] = true;
        map.values[key] = val;
        map.indexOf[key] = map.keys.length;
        map.keys.push(key);
    }

    function remove(Map storage map, address key) internal {
        if (!map.inserted[key]) return;
        uint256 idx = map.indexOf[key];
        uint256 lastIdx = map.keys.length - 1;
        if (idx != lastIdx) {
            address lastKey = map.keys[lastIdx];
            map.keys[idx] = lastKey;
            map.indexOf[lastKey] = idx;
        }
        map.keys.pop();
        delete map.inserted[key];
        delete map.values[key];
        delete map.indexOf[key];
    }
}

// ═══════════════════════════════════════════
//  Ownable
// ═══════════════════════════════════════════

abstract contract Ownable {
    address internal _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address owner_) {
        address initOwner = owner_ == address(0) ? msg.sender : owner_;
        _owner = initOwner;
        emit OwnershipTransferred(address(0), initOwner);
    }

    function owner() public view virtual returns (address) { return _owner; }

    modifier onlyOwner() {
        require(_owner == msg.sender, "Ownable: caller is not owner");
        _;
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }
}

// ═══════════════════════════════════════════
//  DividendPayingToken（抽象）
// ═══════════════════════════════════════════

abstract contract DividendPayingTokenInterface {
    event DividendsDistributed(address indexed from, uint256 weiAmount);
    event DividendWithdrawn(address indexed to, uint256 weiAmount);

    function distributeBNBDividends(uint256 amount) external virtual;
    function withdrawDividend() public virtual;
    function withdrawnDividendOf(address _owner) public view virtual returns (uint256);
    function accumulativeDividendOf(address _owner) public view virtual returns (uint256);
}

abstract contract DividendPayingTokenOptionalInterface {
    function withdrawableDividendOf(address _owner) public view virtual returns (uint256);
    function dividendTokenBalanceOf(address _owner) public view virtual returns (uint256);
}

abstract contract DividendPayingToken is
    Ownable,
    DividendPayingTokenInterface,
    DividendPayingTokenOptionalInterface
{
    using SafeMathUint for uint256;
    using SafeMathInt for int256;

    uint256 internal constant MAGNITUDE = 2 ** 128;
    uint256 internal magnifiedDividendPerShare;
    mapping(address => int256) internal magnifiedDividendCorrections;
    mapping(address => uint256) internal withdrawnDividends;
    uint256 public totalDividendsDistributed;

    /**
     * @dev 直接接收 BNB 时按当前持仓自动分红
     *      TaxDistributor 向此合约转账 BNB 触发该 receive
     */
    receive() external payable {
        uint256 supply = totalSupply();
        if (supply > 0 && msg.value > 0) {
            magnifiedDividendPerShare = magnifiedDividendPerShare +
                (msg.value * MAGNITUDE) / supply;
            emit DividendsDistributed(msg.sender, msg.value);
            totalDividendsDistributed = totalDividendsDistributed + msg.value;
        }
    }

    function distributeBNBDividends(uint256 amount) public virtual override onlyOwner {
        uint256 supply = totalSupply();
        require(supply > 0, "DividendPayingToken: supply=0");
        if (amount > 0) {
            magnifiedDividendPerShare = magnifiedDividendPerShare +
                (amount * MAGNITUDE) / supply;
            emit DividendsDistributed(msg.sender, amount);
            totalDividendsDistributed = totalDividendsDistributed + amount;
        }
    }

    function _withdrawDividendOfUser(address payable user) internal returns (bool) {
        uint256 withdrawable = withdrawableDividendOf(user);
        if (withdrawable > 0) {
            withdrawnDividends[user] = withdrawnDividends[user] + withdrawable;
            emit DividendWithdrawn(user, withdrawable);
            (bool success, ) = user.call{value: withdrawable}("");
            if (!success) {
                withdrawnDividends[user] = withdrawnDividends[user] - withdrawable;
                return false;
            }
            return true;
        }
        return false;
    }

    function withdrawableDividendOf(address _owner) public view override returns (uint256) {
        uint256 accumulated = accumulativeDividendOf(_owner);
        uint256 withdrawn = withdrawnDividends[_owner];
        if (accumulated <= withdrawn) return 0;
        return accumulated - withdrawn;
    }

    function withdrawnDividendOf(address _owner) public view override returns (uint256) {
        return withdrawnDividends[_owner];
    }

    function accumulativeDividendOf(address _owner) public view virtual override returns (uint256) {
        uint256 bal = balanceOf(_owner);
        int256 raw = int256((magnifiedDividendPerShare * bal) / MAGNITUDE);
        int256 corrected = SafeMathInt.add(raw, magnifiedDividendCorrections[_owner]);
        if (corrected < 0) return 0;
        return uint256(corrected);
    }

    function withdrawDividend() public virtual override {}
    function dividendTokenBalanceOf(address) public view virtual override returns (uint256) { return 0; }
    function totalSupply() public view virtual returns (uint256) { return 0; }
    function balanceOf(address) public view virtual returns (uint256) { return 0; }
}

// ═══════════════════════════════════════════
//  ModaDividendTracker
// ═══════════════════════════════════════════

contract ModaDividendTracker is DividendPayingToken {
    using IterableMapping for IterableMapping.Map;

    IterableMapping.Map private tokenHoldersMap;
    uint256 public lastProcessedIndex;
    mapping(address => bool) public excludedFromDividends;
    mapping(address => uint256) public lastClaimTimes;
    uint256 public claimWait = 300;
    uint256 public minimumTokenBalanceForDividends;
    uint256 private totalTrackedSupply;

    event ExcludedFromDividends(address indexed account, bool excluded);
    event ClaimWaitUpdated(uint256 newClaimWait);
    event Claim(address indexed account, uint256 amount, bool autoClaim);

    constructor(uint256 minBalance_, address owner_) Ownable(owner_) {
        minimumTokenBalanceForDividends = minBalance_;
    }

    function totalSupply() public view override returns (uint256) { return totalTrackedSupply; }

    function balanceOf(address account) public view override returns (uint256) {
        return tokenHoldersMap.values[account];
    }

    /**
     * @dev 同步持仓：超过门槛加入分红池，低于门槛移出分红池
     */
    function setBalance(address payable account, uint256 newBalance) external onlyOwner {
        if (excludedFromDividends[account]) {
            if (tokenHoldersMap.inserted[account]) {
                _remove(account);
            }
            return;
        }
        if (newBalance >= minimumTokenBalanceForDividends) {
            _set(account, newBalance);
        } else {
            _remove(account);
        }
    }

    function _set(address account, uint256 newBalance) internal {
        int256 oldCorrection = magnifiedDividendCorrections[account];
        uint256 oldBalance = tokenHoldersMap.inserted[account]
            ? tokenHoldersMap.values[account]
            : 0;

        if (tokenHoldersMap.inserted[account]) {
            totalTrackedSupply = totalTrackedSupply - tokenHoldersMap.values[account];
            tokenHoldersMap.values[account] = newBalance;
            totalTrackedSupply = totalTrackedSupply + newBalance;
        } else {
            tokenHoldersMap.set(account, newBalance);
            totalTrackedSupply = totalTrackedSupply + newBalance;
        }

        // 保留历史 correction，避免重置已有分红份额
        magnifiedDividendCorrections[account] =
            oldCorrection
            + int256((magnifiedDividendPerShare * oldBalance) / MAGNITUDE)
            - int256((magnifiedDividendPerShare * newBalance) / MAGNITUDE);
    }

    function _remove(address account) internal {
        if (!tokenHoldersMap.inserted[account]) return;
        uint256 oldBalance = tokenHoldersMap.values[account];
        totalTrackedSupply = totalTrackedSupply - oldBalance;
        magnifiedDividendCorrections[account] =
            magnifiedDividendCorrections[account]
            + int256((magnifiedDividendPerShare * oldBalance) / MAGNITUDE);
        tokenHoldersMap.remove(account);
    }

    function setMinimumTokenBalanceForDividends(uint256 amount) external onlyOwner {
        minimumTokenBalanceForDividends = amount;
    }

    function setClaimWait(uint256 newClaimWait) external onlyOwner {
        claimWait = newClaimWait;
        emit ClaimWaitUpdated(newClaimWait);
    }

    function excludeFromDividends(address account, bool excluded) external onlyOwner {
        excludedFromDividends[account] = excluded;
        if (excluded) _remove(account);
        emit ExcludedFromDividends(account, excluded);
    }

    /**
     * @dev 批量自动处理分红（由主合约每次转账后调用）
     */
    function process(uint256 gas) external onlyOwner returns (uint256 iterations, uint256 claims, uint256 lastIndex) {
        uint256 numberOfHolders = tokenHoldersMap.size();
        if (numberOfHolders == 0) return (0, 0, lastProcessedIndex);

        uint256 _lastProcessedIndex = lastProcessedIndex;
        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();
        iterations = 0;
        claims = 0;

        while (gasUsed < gas && iterations < numberOfHolders) {
            _lastProcessedIndex = _lastProcessedIndex + 1;
            if (_lastProcessedIndex >= tokenHoldersMap.size()) {
                _lastProcessedIndex = 0;
            }
            address account = tokenHoldersMap.keys[_lastProcessedIndex];
            if (_canAutoClaim(lastClaimTimes[account])) {
                if (_withdrawDividendOfUser(payable(account))) {
                    lastClaimTimes[account] = block.timestamp;
                    emit Claim(account, withdrawableDividendOf(account), true);
                    claims++;
                }
            }
            iterations++;
            uint256 newGasLeft = gasleft();
            if (gasLeft > newGasLeft) gasUsed = gasUsed + (gasLeft - newGasLeft);
            gasLeft = newGasLeft;
        }

        lastProcessedIndex = _lastProcessedIndex;
        lastIndex = lastProcessedIndex;
    }

    function _canAutoClaim(uint256 lastClaimTime) internal view returns (bool) {
        if (lastClaimTime > block.timestamp) return false;
        return block.timestamp - lastClaimTime >= claimWait;
    }

    /**
     * @dev 用户主动领取自己的分红
     */
    function processAccount(address payable account, bool automatic) external onlyOwner returns (bool) {
        bool success = _withdrawDividendOfUser(account);
        if (success) {
            lastClaimTimes[account] = block.timestamp;
            emit Claim(account, 0, automatic);
        }
        return success;
    }

    function emergencyWithdrawBNB() external onlyOwner {
        uint256 bal = address(this).balance;
        if (bal > 0) payable(owner()).transfer(bal);
    }

    function emergencyWithdrawToken(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).transfer(owner(), _amount);
    }

    function getNumberOfTokenHolders() external view returns (uint256) {
        return tokenHoldersMap.size();
    }

    function getAccount(address _account) external view returns (
        address account,
        int256 index,
        int256 iterationsUntilProcessed,
        uint256 withdrawableDividends,
        uint256 totalDividends,
        uint256 lastClaimTime,
        uint256 nextClaimTime,
        uint256 secondsUntilAutoClaimAvailable
    ) {
        account = _account;
        index = tokenHoldersMap.getIndexOfKey(_account);
        if (index >= 0) {
            uint256 lpi = lastProcessedIndex;
            uint256 si  = uint256(index);
            uint256 total = tokenHoldersMap.size();
            iterationsUntilProcessed = int256(si >= lpi
                ? si - lpi
                : total - lpi + si);
        } else {
            iterationsUntilProcessed = -1;
        }
        withdrawableDividends = withdrawableDividendOf(_account);
        totalDividends = accumulativeDividendOf(_account);
        lastClaimTime = lastClaimTimes[_account];
        nextClaimTime = lastClaimTime > 0 ? lastClaimTime + claimWait : 0;
        secondsUntilAutoClaimAvailable = nextClaimTime > block.timestamp
            ? nextClaimTime - block.timestamp
            : 0;
    }
}

// ═══════════════════════════════════════════
//  ModaMintToken — 主合约
//
//  对应 launch.html 完整配置：
//  • 代币基础信息（名称/符号/总量）
//  • Mint 公平发射（单价 / 硬顶 / 预售占比 / LP 比例）
//  • 买卖税（bps）
//  • 税收四项分配（营销 / 销毁 / 回流底池 / 分红）
//  • 白名单模式
//  • 开盘模式（autoOpenTrading: true=自动 / false=手动）
//  • 分红门槛
//  • 靓号地址（通过 CREATE2 工厂部署，合约内无需处理）
// ═══════════════════════════════════════════

contract ModaMintToken is IERC20, Ownable {
    using SafeMath for uint256;

    // ── ERC20 基础 ──
    string  private _name;
    string  private _symbol;
    uint8   private constant _decimals = 18;
    uint256 private _totalSupply;
    uint256 private constant MAX_TAX = 2500;   // 25%，对应 launch.html 最大 25

    mapping(address => uint256)                     private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ── 税费参数（bps，10000 = 100%）──
    uint256 public buyTaxBps;       // 买入税
    uint256 public sellTaxBps;      // 卖出税
    uint256 public marketingBps;    // 税收分配：营销
    uint256 public burnBps;         // 税收分配：销毁
    uint256 public liquidityBps;    // 税收分配：回流底池
    uint256 public dividendBps;     // 税收分配：分红
    address public marketingWallet; // 营销收款地址

    // ── DEX ──
    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;
    bool public tradingActive;
    mapping(address => bool) public isExcludedFromTax;

    // ── Mint 预售 ──
    uint256 public mintCostBNB;         // 单次 Mint 价格（wei）
    uint256 public tokensPerMint;       // 每次 Mint 获得的代币数量（含 18 位精度）
    uint256 public tokensPerLP;         // 每次 Mint 额外添加到 LP 的代币数量
    uint256 public lpTokenPct;          // LP 代币占 tokensPerMint 的百分比（0-100）
    uint256 public fillAmountBNB;       // 满额硬顶（wei）
    uint256 public totalBNBCollected;   // 已收集 BNB
    uint256 public presaleTokenPct;     // 预售代币占总供应量百分比（1-99）
    bool    public presaleActive;       // 预售进行中
    mapping(address => uint256) public mintedAmount;    // 每地址 Mint 量

    // ── 白名单（对应 launch.html 的 whitelistOnly 复选框）──
    bool    public whitelistMintOnly;
    mapping(address => bool) public whitelist;
    mapping(address => bool) public whitelistMinted;

    // ── 开盘模式（对应 launch.html 的 t_autoOpen 下拉框）──
    //    true  = 自动开盘：预售满额后自动 tradingActive = true
    //    false = 手动开盘：满额后需 owner 调用 enableTrading() 手动开启
    bool public autoOpenTrading;

    // ── 分红合约 ──
    ModaDividendTracker public dividendTracker;

    // ── 税费分配合约（发射后由 launch.html 调用 setTaxDistributor 设置）──
    address public taxDistributor;

    // ── 重入保护 ──
    bool private inSwap;
    bool private _inLiquidityAdd;

    modifier lockTheSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }

    // ── Events ──
    event TradingEnabled();
    event PresaleEnded();
    event ManualOpenRequired();             // 手动开盘模式下，预售满额时触发，提醒 owner 手动开盘
    event Mint(address indexed user, uint256 bnbCost, uint256 tokenAmount);
    event InitialLiquidityAdded(uint256 tokens, uint256 bnb);
    event AddLiquidityFailed(uint256 bnbAmount, string reason);
    event DividendTrackerUpdated(address indexed oldTracker, address indexed newTracker);
    event TaxDistributorUpdated(address indexed oldDistributor, address indexed newDistributor);
    event DividendClaimed(address indexed holder, uint256 amount);

    // ═══════════════════════════════════════════
    //  Constructor — 对应 launch.html 所有配置项
    //
    //  参数顺序与 launch.html deployToken() 完全一致：
    //   1. name_              — 代币名称
    //   2. symbol_            — 代币符号
    //   3. totalSupply_       — 总供应量（个，合约内 × 1e18）
    //   4. mintCostBNB_       — 单次 Mint 价格（wei）
    //   5. fillBNB_           — 满额硬顶（wei）
    //   6. buyTax_            — 买入税（bps：100 = 1%）
    //   7. sellTax_           — 卖出税（bps）
    //   8. marketingPct_      — 营销分配（bps，总和 ≤ 10000）
    //   9. burnPct_           — 销毁分配（bps）
    //  10. dividendPct_       — 分红分配（bps）
    //  11. liquidityPct_      — 底池回流分配（bps）
    //  12. marketingWallet_   — 营销钱包地址
    //  13. minHoldForDividend_— 最低持币分红门槛（wei，0=无门槛）
    //  14. presaleTokenPct_   — 预售占比（1-99）
    //  15. whitelistMintOnly_ — 白名单模式（true=仅白名单可 Mint）
    //  16. lpTokenPct_        — LP 代币比例（0-100）
    //  17. autoOpenTrading_   — 开盘模式（true=自动，false=手动）
    // ═══════════════════════════════════════════
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        uint256 mintCostBNB_,
        uint256 fillBNB_,
        uint256 buyTax_,
        uint256 sellTax_,
        uint256 marketingPct_,
        uint256 burnPct_,
        uint256 dividendPct_,
        uint256 liquidityPct_,
        address marketingWallet_,
        uint256 minHoldForDividend_,
        uint256 presaleTokenPct_,
        bool    whitelistMintOnly_,
        uint256 lpTokenPct_,
        bool    autoOpenTrading_
    ) Ownable(address(0)) {
        // ── 参数校验（对应 launch.html 前端验证逻辑）──
        require(buyTax_  <= MAX_TAX, "Buy tax too high");          // 对应 buyTaxSlider max=25
        require(sellTax_ <= MAX_TAX, "Sell tax too high");         // 对应 sellTaxSlider max=25
        require(
            marketingPct_ + burnPct_ + dividendPct_ + liquidityPct_ <= 10000,
            "Tax alloc > 100%"
        );                                                          // 对应前端 allocSum !== 100
        require(fillBNB_ > 0,           "Fill must > 0");
        require(mintCostBNB_ > 0,       "Mint cost > 0");          // 对应 t_mintCostBNB min=0
        require(fillBNB_ >= mintCostBNB_, "Fill < mint cost");
        require(marketingWallet_ != address(0), "Wallet zero");
        require(presaleTokenPct_ >= 1 && presaleTokenPct_ <= 99, "Presale pct 1-99");
        require(lpTokenPct_ <= 100, "LP pct > 100");               // 对应 t_lpPct max=100

        // ── 计算 tokensPerMint 时必须 > 0（对应前端 tokensPerMint = 0 的警告）──
        uint256 mintCount = fillBNB_ / mintCostBNB_;
        require(mintCount > 0, "Mint count zero");
        uint256 totalSupplyWei = totalSupply_ * 1e18;
        uint256 _tokensPerMint = (totalSupplyWei * presaleTokenPct_) / (100 * mintCount);
        require(_tokensPerMint > 0, "tokensPerMint=0: increase supply or reduce fillBNB");

        // ── 初始化代币 ──
        _name = name_;
        _symbol = symbol_;
        _totalSupply = totalSupplyWei;
        _balances[address(this)] = _totalSupply;

        // ── 初始化税费参数 ──
        buyTaxBps    = buyTax_;
        sellTaxBps   = sellTax_;
        marketingBps = marketingPct_;
        burnBps      = burnPct_;
        dividendBps  = dividendPct_;
        liquidityBps = liquidityPct_;
        marketingWallet = marketingWallet_;

        // ── 初始化 DEX（PancakeSwap V2）──
        IUniswapV2Router02 _router = IUniswapV2Router02(
            0x10ED43C718714eb63d5aA57B78B54704E256024E  // PancakeSwap V2 Router
        );
        uniswapV2Router = _router;
        uniswapV2Pair   = IUniswapV2Factory(_router.factory())
            .createPair(address(this), _router.WETH());

        // ── 免税地址 ──
        isExcludedFromTax[address(this)]    = true;
        isExcludedFromTax[owner()]          = true;
        isExcludedFromTax[marketingWallet_] = true;
        isExcludedFromTax[address(_router)] = true;

        // ── 部署分红追踪合约 ──
        dividendTracker = new ModaDividendTracker(minHoldForDividend_, address(this));
        dividendTracker.excludeFromDividends(address(this),  true);
        dividendTracker.excludeFromDividends(address(0),     true);
        dividendTracker.excludeFromDividends(uniswapV2Pair,  true);
        dividendTracker.excludeFromDividends(owner(),        true);

        // ── Mint 预售参数 ──
        mintCostBNB    = mintCostBNB_;
        fillAmountBNB  = fillBNB_;
        lpTokenPct     = lpTokenPct_;
        tokensPerMint  = _tokensPerMint;
        tokensPerLP    = (_tokensPerMint * lpTokenPct_) / 100;
        presaleTokenPct = presaleTokenPct_;

        // ── 白名单 & 开盘模式 ──
        whitelistMintOnly = whitelistMintOnly_;
        autoOpenTrading   = autoOpenTrading_;

        // ── 状态 ──
        presaleActive  = true;
        tradingActive  = false;

        emit Transfer(address(0), address(this), _totalSupply);
    }

    // ═══════════════════════════════════════════
    //  ERC20 标准接口
    // ═══════════════════════════════════════════

    function name()     public view returns (string memory) { return _name;     }
    function symbol()   public view returns (string memory) { return _symbol;   }
    function decimals() public pure returns (uint8)         { return _decimals; }
    function totalSupply() public view override returns (uint256) { return _totalSupply; }
    function balanceOf(address a) public view override returns (uint256) { return _balances[a]; }
    function allowance(address a, address spender) public view override returns (uint256) {
        return _allowances[a][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: exceed allowance");
        unchecked { _approve(from, msg.sender, currentAllowance - amount); }
        _transfer(from, to, amount);
        return true;
    }

    function _approve(address _from, address spender, uint256 amount) internal {
        require(_from != address(0) && spender != address(0), "ERC20: zero address");
        _allowances[_from][spender] = amount;
        emit Approval(_from, spender, amount);
    }

    // ── receive：Mint 入口（发送精确 mintCostBNB 触发 Mint）──
    receive() external payable {
        if (presaleActive && msg.value == mintCostBNB) {
            mint();
        }
        // 其他 BNB（如 rescueBNB、手动加池等）直接接收
    }

    // ═══════════════════════════════════════════
    //  _transfer — 核心转账逻辑
    // ═══════════════════════════════════════════

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "ERC20: zero address");
        require(amount > 0, "ERC20: amount zero");
        require(_balances[from] >= amount, "ERC20: insufficient balance");

        // ── 交易开关检查 ──
        bool isDexTransfer = (from == uniswapV2Pair || to == uniswapV2Pair);
        // 允许 TaxDistributor / DividendTracker 在交易未激活时处理内部 swap
        bool isTaxContract = (
            from == taxDistributor || to == taxDistributor ||
            from == address(dividendTracker) || to == address(dividendTracker)
        );
        if (isDexTransfer && !tradingActive && !isTaxContract) {
            require(
                isExcludedFromTax[from] || isExcludedFromTax[to],
                "Trading not active"
            );
        }

        // ── 计算税费 ──
        bool isBuy  = (from == uniswapV2Pair && to != address(uniswapV2Router)) && !_inLiquidityAdd;
        bool isSell = (to == uniswapV2Pair && from != address(uniswapV2Router)) && !_inLiquidityAdd;
        uint256 taxAmount = 0;

        if (!isExcludedFromTax[from] && !isExcludedFromTax[to]) {
            if (isBuy)  taxAmount = (amount * buyTaxBps)  / 10000;
            if (isSell) taxAmount = (amount * sellTaxBps) / 10000;
        }

        uint256 sendAmt = amount - taxAmount;
        _balances[from] -= amount;
        _balances[to]   += sendAmt;

        if (taxAmount > 0) {
            _balances[address(this)] += taxAmount;
            _handleTax(from, taxAmount);
        }

        _updateTrackerBalance(from);
        _updateTrackerBalance(to);

        if (!inSwap) {
            // 触发分红发放
            try dividendTracker.process(100000) {} catch {}
            // 触发税费处理：swap 成 BNB → 营销钱包 / 分红 / LP 回流
            if (taxDistributor != address(0)) {
                try ITaxDistributor(taxDistributor).tryProcess() {} catch {}
            }
        }

        emit Transfer(from, to, sendAmt);
    }

    /**
     * @dev 税费处理：
     *  1. burnBps 部分直接销毁到 0xdead
     *  2. 剩余（营销 + LP + 分红）转发给 TaxDistributor 异步处理
     *  3. 若 TaxDistributor 未设置，税费暂留合约内（可被 forwardTaxTokens 手动转发）
     *
     *  注意：主合约不进行任何 swap，避免在 PancakeSwap Pair LOCKED 时重入
     */
    function _handleTax(address from, uint256 taxAmt) internal {
        uint256 burn = (taxAmt * burnBps) / 10000;
        uint256 fwd  = taxAmt - burn;

        if (burn > 0) {
            address dead = 0x000000000000000000000000000000000000dEaD;
            _balances[address(this)] -= burn;
            _totalSupply -= burn;   // 销毁后总供应量减少
            emit Transfer(address(this), dead, burn);
        }

        if (fwd > 0 && taxDistributor != address(0)) {
            _balances[address(this)] -= fwd;
            _balances[taxDistributor] += fwd;
            emit Transfer(address(this), taxDistributor, fwd);
        } else if (fwd > 0) {
            // taxDistributor 未设置，暂留合约内
            emit Transfer(from, address(this), fwd);
        }
    }

    function _updateTrackerBalance(address account) internal {
        try dividendTracker.setBalance(payable(account), _balances[account]) {} catch {}
    }

    // ═══════════════════════════════════════════
    //  Mint 预售公平发射
    //  对应 launch.html "Mint 配置" 卡片
    // ═══════════════════════════════════════════

    /**
     * @notice 用户参与 Mint，发送精确 mintCostBNB 数量 BNB
     *  - 普通模式：任意地址可参与，每地址不限次数
     *  - 白名单模式（whitelistMintOnly=true）：仅白名单地址，且每地址只能 Mint 一次
     *  - 每次 Mint：用户获得 tokensPerMint，同时自动添加 tokensPerLP + BNB 进底池
     *  - 满额后：
     *    • autoOpenTrading=true  → 自动开启交易（自动开盘）
     *    • autoOpenTrading=false → 发出 ManualOpenRequired 事件，需 owner 手动调用 enableTrading()
     */
    function mint() public payable {
        require(presaleActive,               "Presale not active");
        require(msg.value == mintCostBNB,    "Invalid BNB amount");
        require(totalBNBCollected + msg.value <= fillAmountBNB, "Presale full");

        if (whitelistMintOnly) {
            require(whitelist[msg.sender],       "Not whitelisted");
            require(!whitelistMinted[msg.sender], "Already minted");
        }

        totalBNBCollected += msg.value;

        uint256 tokenAmt = tokensPerMint;
        uint256 lpAmt    = tokensPerLP;
        require(
            _balances[address(this)] >= tokenAmt + lpAmt,
            "Insufficient contract balance"
        );

        // 转代币给用户
        _balances[msg.sender]    += tokenAmt;
        _balances[address(this)] -= tokenAmt;
        mintedAmount[msg.sender] += tokenAmt;

        if (whitelistMintOnly) whitelistMinted[msg.sender] = true;

        emit Mint(msg.sender, msg.value, tokenAmt);
        emit Transfer(address(this), msg.sender, tokenAmt);
        _updateTrackerBalance(msg.sender);

        // 添加初始流动性（每次 Mint 均添加）
        if (lpAmt > 0) {
            _addMintLiquidity(msg.value, lpAmt);
        }

        // ── 判断是否满额，决定开盘方式 ──
        if (totalBNBCollected >= fillAmountBNB) {
            presaleActive = false;
            emit PresaleEnded();

            if (autoOpenTrading) {
                // 自动开盘模式
                tradingActive = true;
                emit TradingEnabled();
            } else {
                // 手动开盘模式：发出事件提醒，需 owner 手动调用 enableTrading()
                emit ManualOpenRequired();
            }
        }
    }

    /**
     * @dev 每次 Mint 时自动添加流动性（使用 lpAmt 代币 + bnbAmount BNB）
     */
    function _addMintLiquidity(uint256 bnbAmount, uint256 lpAmt) internal {
        _inLiquidityAdd = true;
        _approve(address(this), address(uniswapV2Router), lpAmt);
        try uniswapV2Router.addLiquidityETH{value: bnbAmount}(
            address(this),
            lpAmt,
            0,
            0,
            owner(),
            block.timestamp + 300
        ) returns (uint256 tokenUsed, uint256 bnbUsed, uint256) {
            // 未使用完的 LP 代币归还合约余额（addLiquidityETH 会自动归还）
            emit InitialLiquidityAdded(tokenUsed, bnbUsed);
        } catch Error(string memory reason) {
            emit AddLiquidityFailed(bnbAmount, reason);
        } catch {
            emit AddLiquidityFailed(bnbAmount, "unknown");
        }
        _inLiquidityAdd = false;
    }

    // ═══════════════════════════════════════════
    //  TaxDistributor 管理
    //  发射流程：deploy主合约 → deploy TaxDistributor → 调用此函数设置关联
    // ═══════════════════════════════════════════

    /**
     * @notice 设置税费分配合约（发射时由 launch.html 第三步自动调用）
     */
    function setTaxDistributor(address _dist) external onlyOwner {
        require(_dist != address(0), "Zero address");
        emit TaxDistributorUpdated(taxDistributor, _dist);
        taxDistributor = _dist;
        isExcludedFromTax[_dist] = true;
        dividendTracker.excludeFromDividends(_dist, true);
    }

    /**
     * @notice 手动将合约内暂留的税费代币转发给 TaxDistributor
     *         用于 taxDistributor 后设时，转发之前累积的税费
     */
    function forwardTaxTokens() external onlyOwner {
        require(taxDistributor != address(0), "TaxDistributor not set");
        uint256 bal = _balances[address(this)];
        if (bal > 0) {
            _balances[address(this)] = 0;
            _balances[taxDistributor] += bal;
            emit Transfer(address(this), taxDistributor, bal);
        }
    }

    // ═══════════════════════════════════════════
    //  开盘管理
    //  对应 launch.html 开盘模式配置
    // ═══════════════════════════════════════════

    /**
     * @notice 手动开盘 — 手动开盘模式（autoOpenTrading=false）下，
     *         预售满额后 owner 调用此函数开启交易
     *         对应管理员界面的"手动开启交易"按钮
     */
    function enableTrading() external onlyOwner {
        require(!tradingActive, "Trading already active");
        tradingActive = true;
        emit TradingEnabled();
    }

    /**
     * @notice 修改开盘模式（部署后仍可调整策略）
     */
    function setAutoOpenTrading(bool _v) external onlyOwner {
        autoOpenTrading = _v;
    }

    // ═══════════════════════════════════════════
    //  白名单管理
    //  对应 launch.html 白名单配置
    // ═══════════════════════════════════════════

    /**
     * @notice 批量添加白名单地址（对应管理员界面添加白名单）
     */
    function addWhitelist(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            whitelist[users[i]] = true;
        }
    }

    /**
     * @notice 批量移除白名单地址
     */
    function removeWhitelist(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            whitelist[users[i]] = false;
            whitelistMinted[users[i]] = false;
        }
    }

    /**
     * @notice 切换白名单模式
     */
    function setWhitelistMintOnly(bool v) external onlyOwner {
        whitelistMintOnly = v;
    }

    /**
     * @notice 重置白名单已 Mint 状态（允许重复参与）
     */
    function resetWhitelistMinted(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            whitelistMinted[users[i]] = false;
        }
    }

    // ═══════════════════════════════════════════
    //  Mint 参数管理
    // ═══════════════════════════════════════════

    /**
     * @notice 更新 Mint 价格和硬顶（仅预售进行中可调整）
     *         自动重新计算 tokensPerMint 和 tokensPerLP
     */
    function setMintPrice(uint256 costBNB_, uint256 fillBNB_) external onlyOwner {
        require(presaleActive, "Presale ended");
        require(costBNB_ > 0 && fillBNB_ >= costBNB_, "Invalid params");
        uint256 mintCount = fillBNB_ / costBNB_;
        uint256 newTokensPerMint = (_totalSupply * presaleTokenPct) / (100 * mintCount);
        require(newTokensPerMint > 0, "tokensPerMint=0");
        mintCostBNB   = costBNB_;
        fillAmountBNB = fillBNB_;
        tokensPerMint = newTokensPerMint;
        tokensPerLP   = (newTokensPerMint * lpTokenPct) / 100;
    }

    // ═══════════════════════════════════════════
    //  税费管理
    //  对应 launch.html 税费 & 分配配置
    // ═══════════════════════════════════════════

    function setBuyTax(uint256 bps) external onlyOwner {
        require(bps <= MAX_TAX, "Exceeds max tax");
        buyTaxBps = bps;
    }

    function setSellTax(uint256 bps) external onlyOwner {
        require(bps <= MAX_TAX, "Exceeds max tax");
        sellTaxBps = bps;
    }

    function setMarketingWallet(address w) external onlyOwner {
        require(w != address(0), "Zero address");
        isExcludedFromTax[w] = true;
        marketingWallet = w;
    }

    function excludeFromTax(address a, bool ex) external onlyOwner {
        isExcludedFromTax[a] = ex;
    }

    /**
     * @notice 更新营销分配比例（bps）
     */
    function setMarketingBps(uint256 bps) external onlyOwner {
        require(bps + burnBps + dividendBps + liquidityBps <= 10000, "Total > 100%");
        marketingBps = bps;
    }

    function setBurnBps(uint256 bps) external onlyOwner {
        require(marketingBps + bps + dividendBps + liquidityBps <= 10000, "Total > 100%");
        burnBps = bps;
    }

    function setDividendBps(uint256 bps) external onlyOwner {
        require(marketingBps + burnBps + bps + liquidityBps <= 10000, "Total > 100%");
        dividendBps = bps;
    }

    function setLiquidityBps(uint256 bps) external onlyOwner {
        require(marketingBps + burnBps + dividendBps + bps <= 10000, "Total > 100%");
        liquidityBps = bps;
    }

    // ═══════════════════════════════════════════
    //  分红管理
    //  对应 launch.html 分红设置
    // ═══════════════════════════════════════════

    /**
     * @notice 调整最低持币分红门槛（对应 t_minDividend）
     */
    function setMinHoldForDividend(uint256 amt) external onlyOwner {
        dividendTracker.setMinimumTokenBalanceForDividends(amt);
    }

    /**
     * @notice 用户主动领取自己的分红
     */
    function claimDividend() external {
        dividendTracker.processAccount(payable(msg.sender), false);
    }

    function setDividendClaimWait(uint256 wait_) external onlyOwner {
        dividendTracker.setClaimWait(wait_);
    }

    function excludeFromDividend(address account, bool excluded) external onlyOwner {
        dividendTracker.excludeFromDividends(account, excluded);
    }

    function triggerDividendProcess(uint256 gas) external onlyOwner {
        dividendTracker.process(gas);
    }

    function setDividendTracker(ModaDividendTracker newTracker) external onlyOwner {
        emit DividendTrackerUpdated(address(dividendTracker), address(newTracker));
        dividendTracker = newTracker;
    }

    function dividendTrackerEmergencyWithdrawBNB() external onlyOwner {
        dividendTracker.emergencyWithdrawBNB();
    }

    function dividendTrackerEmergencyWithdrawToken(address _token, uint256 _amount) external onlyOwner {
        dividendTracker.emergencyWithdrawToken(_token, _amount);
    }

    // ═══════════════════════════════════════════
    //  流动性管理
    // ═══════════════════════════════════════════

    /**
     * @notice Owner 手动添加流动性：tokenAmount 代币 + 附带 BNB
     */
    function addLiquidityWithBNB(uint256 tokenAmount) external payable onlyOwner {
        require(msg.value > 0,    "Send BNB");
        require(tokenAmount > 0,  "Token amount > 0");
        require(_balances[address(this)] >= tokenAmount, "Insufficient tokens");
        _inLiquidityAdd = true;
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        try uniswapV2Router.addLiquidityETH{value: msg.value}(
            address(this), tokenAmount, 0, 0, owner(), block.timestamp + 300
        ) returns (uint256, uint256, uint256) {
            // success
        } catch Error(string memory reason) {
            _inLiquidityAdd = false;
            revert(string(abi.encodePacked("AddLiquidity failed: ", reason)));
        } catch {
            _inLiquidityAdd = false;
            revert("AddLiquidity failed");
        }
        _inLiquidityAdd = false;
    }

    /**
     * @notice 撤底池：销毁 lpAmount LP，取回代币 + BNB
     */
    function removeLiquidity(uint256 lpAmount) external onlyOwner {
        if (uniswapV2Pair == address(0)) {
            uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
                .getPair(address(this), uniswapV2Router.WETH());
        }
        require(uniswapV2Pair != address(0), "Pair not created yet");
        uint256 balance = IERC20(uniswapV2Pair).balanceOf(address(this));
        if (lpAmount == 0) lpAmount = balance;
        require(lpAmount > 0 && balance >= lpAmount, "Insufficient LP balance");
        IERC20(uniswapV2Pair).approve(address(uniswapV2Router), lpAmount);
        uniswapV2Router.removeLiquidityETH(
            address(this), lpAmount, 0, 0, owner(), block.timestamp
        );
    }

    /**
     * @notice 仅提取 LP 代币到 owner 钱包（不撤池）
     */
    function withdrawLP(uint256 amount) external onlyOwner {
        if (uniswapV2Pair == address(0)) {
            uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
                .getPair(address(this), uniswapV2Router.WETH());
        }
        require(uniswapV2Pair != address(0), "Pair not created yet");
        uint256 balance = IERC20(uniswapV2Pair).balanceOf(address(this));
        if (amount == 0) amount = balance;
        require(amount > 0 && balance >= amount, "Insufficient LP balance");
        IERC20(uniswapV2Pair).transfer(owner(), amount);
    }

    // ═══════════════════════════════════════════
    //  紧急救援 / 工具函数
    // ═══════════════════════════════════════════

    /**
     * @notice 提取合约内 BNB 到 owner 钱包
     */
    function withdrawBNB() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    /**
     * @notice 提取误转入的任意 ERC20 代币（防止锁死）
     */
    function emergencyWithdrawToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    // ═══════════════════════════════════════════
    //  前端兼容别名（mint.html / admin.html）
    // ═══════════════════════════════════════════

    function mintPrice()      external view returns (uint256) { return mintCostBNB;       }
    function hardCap()        external view returns (uint256) { return fillAmountBNB;     }
    function totalMinted()    external view returns (uint256) { return totalBNBCollected; }
    function tradingEnabled() external view returns (bool)    { return tradingActive;     }
    function openMode()       external view returns (bool)    { return autoOpenTrading;   }
    function whitelistOnly()  external view returns (bool)    { return whitelistMintOnly; }
    function hasMinted(address user) external view returns (bool) { return whitelistMinted[user]; }
    function mintBatchSize()  external view returns (uint256) { return mintCostBNB;       }

    // ═══════════════════════════════════════════
    //  查询接口
    // ═══════════════════════════════════════════

    /**
     * @notice 返回用户可领取的分红数量（BNB wei）
     */
    function withdrawableDividendOf(address user) external view returns (uint256) {
        return dividendTracker.withdrawableDividendOf(user);
    }

    /**
     * @notice 返回用户累计分红总量
     */
    function accumulativeDividendOf(address user) external view returns (uint256) {
        return dividendTracker.accumulativeDividendOf(user);
    }

    /**
     * @notice 返回持仓分红信息
     */
    function getAccountDividendsInfo(address user) external view returns (
        address account,
        int256 index,
        int256 iterationsUntilProcessed,
        uint256 withdrawableDividends,
        uint256 totalDividends,
        uint256 lastClaimTime,
        uint256 nextClaimTime,
        uint256 secondsUntilAutoClaimAvailable
    ) {
        return dividendTracker.getAccount(user);
    }

    /**
     * @notice 返回预售信息概要
     */
    function getPresaleInfo() external view returns (
        bool   active,
        uint256 costBNB,
        uint256 collected,
        uint256 hardCapBNB,
        uint256 perMint,
        uint256 perLP,
        bool   wlOnly,
        bool   autoOpen,
        bool   trading
    ) {
        return (
            presaleActive,
            mintCostBNB,
            totalBNBCollected,
            fillAmountBNB,
            tokensPerMint,
            tokensPerLP,
            whitelistMintOnly,
            autoOpenTrading,
            tradingActive
        );
    }

    /**
     * @notice 返回税费配置信息
     */
    function getTaxInfo() external view returns (
        uint256 buyTax,
        uint256 sellTax,
        uint256 mktBps,
        uint256 burnBpsVal,
        uint256 divBps,
        uint256 lpBps,
        address mktWallet,
        address taxDist
    ) {
        return (
            buyTaxBps,
            sellTaxBps,
            marketingBps,
            burnBps,
            dividendBps,
            liquidityBps,
            marketingWallet,
            taxDistributor
        );
    }
}
