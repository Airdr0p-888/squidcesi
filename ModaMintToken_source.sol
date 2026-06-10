// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) { return a + b; }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) { return a - b; }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) { return a * b; }
    function div(uint256 a, uint256 b) internal pure returns (uint256) { require(b > 0); return a / b; }
    function mod(uint256 a, uint256 b) internal pure returns (uint256) { require(b > 0); return a % b; }
    function sub(uint256 a, uint256 b, string memory err) internal pure returns (uint256) {
        require(b <= a, err); return a - b;
    }
    function add(uint256 a, uint256 b, string memory err) internal pure returns (uint256) {
        uint256 c = a + b; require(c >= a, err); return c;
    }
}

library SafeMathInt {
    int256 private constant MIN_INT256 = int256(0x8000000000000000);
    int256 private constant MAX_INT256 = int256(0x7fffffffffffffff);
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
    function get(Map storage map, address key) internal view returns (uint256) { return map.values[key]; }
    function getIndexOfKey(Map storage map, address key) internal view returns (int256) {
        if (!map.inserted[key]) return -1;
        return int256(map.indexOf[key]);
    }
    function size(Map storage map) internal view returns (uint256) { return map.keys.length; }
    function set(Map storage map, address key, uint256 val) internal {
        if (map.inserted[key]) { map.values[key] = val; return; }
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

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external returns (uint[] memory amounts);
    function addLiquidityETH(
        address token, uint amountTokenDesired, uint amountTokenMin, uint amountETHMin,
        address to, uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidityETH(
        address token, uint liquidity, uint amountTokenMin, uint amountETHMin,
        address to, uint deadline
    ) external returns (uint amountToken, uint amountETH);
}

// ── Ownable ──
abstract contract Ownable {
    address internal _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor(address owner_) {
        address _initOwner = owner_ == address(0) ? msg.sender : owner_;
        _owner = _initOwner;
        emit OwnershipTransferred(address(0), _initOwner);
    }
    function owner() public view virtual returns (address) { return _owner; }
    modifier onlyOwner() { require(owner() == msg.sender, "Ownable: caller is not owner"); _; }
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

// ── Dividend Interfaces ──
abstract contract DividendPayingTokenInterface {
    event DividendsDistributed(address indexed from, uint256 weiAmount);
    event DividendWithdrawn(address indexed to, uint256 weiAmount);
    function distributeBNBDividends(uint256 amount) external virtual;
    function withdrawDividend() public virtual;
    function withdrawnDividendOf(address) public view virtual returns (uint256);
    function accumulativeDividendOf(address) public view virtual returns (uint256);
}

abstract contract DividendPayingTokenOptionalInterface {
    function withdrawableDividendOf(address _owner) public view virtual returns (uint256);
    function dividendTokenBalanceOf(address _owner) public view virtual returns (uint256);
}

// ── DividendPayingToken (abstract) ──
abstract contract DividendPayingToken is Ownable, DividendPayingTokenInterface, DividendPayingTokenOptionalInterface {
    using SafeMathUint for uint256;
    using SafeMathInt for int256;

    uint256 internal constant MAGNITUDE = 2 ** 128;
    uint256 internal magnifiedDividendPerShare;
    mapping(address => int256) internal magnifiedDividendCorrections;
    mapping(address => uint256) internal withdrawnDividends;
    uint256 public totalDividendsDistributed;

    receive() external payable {
        // 直接更新分红，不经过 onlyOwner 保护的 distributeBNBDividends
        // 因为 TaxDistributor 发送 BNB 时 msg.sender 不是 owner
        uint256 supply = totalSupply();
        if (supply > 0 && msg.value > 0) {
            magnifiedDividendPerShare = SafeMath.add(
                magnifiedDividendPerShare,
                SafeMath.mul(msg.value, MAGNITUDE) / supply
            );
            emit DividendsDistributed(msg.sender, msg.value);
            totalDividendsDistributed = SafeMath.add(totalDividendsDistributed, msg.value);
        }
    }

    function distributeBNBDividends(uint256 amount) public virtual override onlyOwner {
        uint256 supply = totalSupply();
        require(supply > 0, "DividendPayingToken: supply=0");
        if (amount > 0) {
            magnifiedDividendPerShare = SafeMath.add(
                magnifiedDividendPerShare,
                SafeMath.mul(amount, MAGNITUDE) / supply
            );
            emit DividendsDistributed(msg.sender, amount);
            totalDividendsDistributed = SafeMath.add(totalDividendsDistributed, amount);
        }
    }

    function _withdrawDividendOfUser(address payable user) internal returns (bool) {
        uint256 withdrawable = withdrawableDividendOf(user);
        if (withdrawable > 0) {
            withdrawnDividends[user] = SafeMath.add(withdrawnDividends[user], withdrawable);
            emit DividendWithdrawn(user, withdrawable);
            (bool success, ) = user.call{value: withdrawable}("");
            if (!success) {
                withdrawnDividends[user] = SafeMath.sub(withdrawnDividends[user], withdrawable, "Withdraw failed");
                return false;
            }
            return true;
        }
        return false;
    }

    function withdrawableDividendOf(address _owner) public view override returns (uint256) {
        return SafeMath.sub(accumulativeDividendOf(_owner), withdrawnDividends[_owner]);
    }

    function withdrawnDividendOf(address _owner) public view override returns (uint256) {
        return withdrawnDividends[_owner];
    }

    function accumulativeDividendOf(address _owner) public view virtual override returns (uint256) {
        uint256 bal = balanceOf(_owner);
        int256 correction = magnifiedDividendCorrections[_owner];
        int256 raw = int256(SafeMath.mul(magnifiedDividendPerShare, bal) / MAGNITUDE);
        int256 corrected = raw + correction;
        if (corrected < 0) return 0;
        return uint256(corrected);
    }

    function withdrawDividend() public virtual override {
    }
    function dividendTokenBalanceOf(address) public view virtual override returns (uint256) { return 0; }
    function totalSupply() public view virtual returns (uint256) { return 0; }
    function balanceOf(address) public view virtual returns (uint256) { return 0; }
}

// ── ModaDividendTracker ──
contract ModaDividendTracker is DividendPayingToken {
    using IterableMapping for IterableMapping.Map;

    IterableMapping.Map private tokenHoldersMap;
    uint256 public lastProcessedIndex;
    mapping(address => bool) public excludedFromDividends;
    mapping(address => uint256) public lastClaimTimes;
    uint256 public claimWait = 300;
    uint256 public minimumTokenBalanceForDividends;
    uint256 private totalTrackedSupply;   // 参与分红的总余额

    event ExcludedFromDividends(address indexed account, bool excluded);
    event ClaimWaitUpdated(uint256 newClaimWait);
    event Claim(address indexed account, uint256 amount, bool autoClaim);

    constructor(uint256 minBalance_, address owner_) Ownable(owner_) {
        minimumTokenBalanceForDividends = minBalance_;
    }

    function _transfer(address, address, uint256) internal pure {
        require(false, "DividendTracker: no transfer");
    }

    function totalSupply() public view override returns (uint256) { return totalTrackedSupply; }

    function balanceOf(address account) public view override returns (uint256) {
        return tokenHoldersMap.values[account];
    }

    function setBalance(address payable account, uint256 newBalance) external onlyOwner {
        if (excludedFromDividends[account]) {
            if (tokenHoldersMap.inserted[account]) {
                tokenHoldersMap.remove(account);
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
        uint256 oldBalance = tokenHoldersMap.inserted[account] ? tokenHoldersMap.values[account] : 0;

        if (tokenHoldersMap.inserted[account]) {
            totalTrackedSupply = SafeMath.sub(totalTrackedSupply, tokenHoldersMap.values[account]);
            tokenHoldersMap.values[account] = newBalance;
            totalTrackedSupply = SafeMath.add(totalTrackedSupply, newBalance);
        } else {
            tokenHoldersMap.set(account, newBalance);
            totalTrackedSupply = SafeMath.add(totalTrackedSupply, newBalance);
        }

        // 修正：保留历史 correction，而非直接覆盖
        magnifiedDividendCorrections[account] =
            oldCorrection
            + int256(SafeMath.mul(magnifiedDividendPerShare, oldBalance) / MAGNITUDE)
            - int256(SafeMath.mul(magnifiedDividendPerShare, newBalance) / MAGNITUDE);
    }

    function _remove(address account) internal {
        if (!tokenHoldersMap.inserted[account]) return;
        _withdrawDividendOfUser(payable(account));
        totalTrackedSupply = SafeMath.sub(totalTrackedSupply, tokenHoldersMap.values[account]);
        tokenHoldersMap.remove(account);
        delete magnifiedDividendCorrections[account];
        delete withdrawnDividends[account];
    }

    function getNumberOfTokenHolders() external view returns (uint256) {
        return tokenHoldersMap.keys.length;
    }

    function getTokenHolders(uint256 start, uint256 count_) external view
        returns (address[] memory, uint256[] memory)
    {
        uint256 end = SafeMath.add(start, count_);
        if (end > tokenHoldersMap.keys.length) end = tokenHoldersMap.keys.length;
        if (start >= end) return (new address[](0), new uint256[](0));
        address[] memory addrs = new address[](SafeMath.sub(end, start));
        uint256[] memory balances = new uint256[](SafeMath.sub(end, start));
        for (uint256 i = start; i < end; i = SafeMath.add(i, 1)) {
            addrs[i - start] = tokenHoldersMap.keys[i];
            balances[i - start] = tokenHoldersMap.values[tokenHoldersMap.keys[i]];
        }
        return (addrs, balances);
    }

    function process(uint256 gas) public returns (uint256, uint256, uint256) {
        uint256 numberOfHolders = tokenHoldersMap.keys.length;
        if (numberOfHolders == 0) return (0, 0, lastProcessedIndex);
        uint256 _lastProcessedIndex = lastProcessedIndex;
        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();
        uint256 iterations = 0;
        uint256 claims = 0;

        while (gasUsed < gas && iterations < numberOfHolders) {
            _lastProcessedIndex = SafeMath.add(_lastProcessedIndex, 1);
            if (_lastProcessedIndex >= tokenHoldersMap.keys.length) _lastProcessedIndex = 0;
            address account = tokenHoldersMap.keys[_lastProcessedIndex];
            bool claimed = _withdrawDividendOfUser(payable(account));
            if (claimed) {
                claims = SafeMath.add(claims, 1);
                lastClaimTimes[account] = block.timestamp;
            }
            iterations = SafeMath.add(iterations, 1);
            uint256 newGasLeft = gasleft();
            if (gasLeft > newGasLeft) gasUsed = SafeMath.add(gasUsed, gasLeft - newGasLeft);
            gasLeft = newGasLeft;
        }
        lastProcessedIndex = _lastProcessedIndex;
        return (iterations, claims, lastProcessedIndex);
    }

    function claim() external {
        require(SafeMath.add(lastClaimTimes[msg.sender], claimWait) <= block.timestamp, "Claim wait not met");
        uint256 amount = withdrawableDividendOf(msg.sender);
        _withdrawDividendOfUser(payable(msg.sender));
        lastClaimTimes[msg.sender] = block.timestamp;
        emit Claim(msg.sender, amount, false);
    }

    function processAccount(address payable account, bool autoClaim) public onlyOwner returns (bool) {
        if (!autoClaim) {
            require(SafeMath.add(lastClaimTimes[account], claimWait) <= block.timestamp, "Claim wait not met");
        }
        uint256 amount = withdrawableDividendOf(account);
        bool claimed = _withdrawDividendOfUser(account);
        if (claimed) {
            lastClaimTimes[account] = block.timestamp;
            emit Claim(account, amount, autoClaim);
        }
        return claimed;
    }

    function setMinimumTokenBalanceForDividends(uint256 minBalance) external onlyOwner {
        minimumTokenBalanceForDividends = minBalance;
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

    function emergencyWithdrawBNB() external onlyOwner {
        uint256 bal = address(this).balance;
        if (bal > 0) {
            payable(owner()).transfer(bal);
        }
    }

    /**
     * @dev 提取误转入分红合约的任意 ERC20 代币
     */
    function emergencyWithdrawToken(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).transfer(owner(), _amount);
    }
}

// ═══════════════════════════════════════════
//  ModaMintToken — 主合约
//
//  新架构：主合约不处理 swap，税费 token 全部
//  转发给独立的 TaxDistributor 合约异步处理。
//  用户交易永远不因 swap 失败而 revert。
// ═══════════════════════════════════════════
contract ModaMintToken is IERC20, Ownable {
    using SafeMath for uint256;

    string private _name;
    string private _symbol;
    uint8  private constant _decimals = 18;
    uint256 private _totalSupply;
    uint256 private constant MAX_TAX = 2500;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // Tax
    uint256 public buyTaxBps;
    uint256 public sellTaxBps;
    uint256 public marketingBps;
    uint256 public burnBps;
    uint256 public liquidityBps;
    uint256 public dividendBps;
    address public marketingWallet;

    // DEX
    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;
    bool public tradingActive;

    mapping(address => bool) public isExcludedFromTax;

    // Mint presale
    uint256 public mintCostBNB;
    uint256 public tokensPerMint;
    uint256 public tokensPerLP;
    uint256 public lpTokenPct;
    uint256 public fillAmountBNB;
    uint256 public totalBNBCollected;
    mapping(address => uint256) public mintedAmount;
    bool public presaleActive;
    bool public whitelistMintOnly;
    bool public autoOpenTrading;
    mapping(address => bool) public whitelist;
    mapping(address => bool) public whitelistMinted;
    uint256 public presaleTokenPct;

    // Dividend tracker
    ModaDividendTracker public dividendTracker;

    // ═════════ 新架构：税费转发 ═════════
    address public taxDistributor;           // 独立的税费处理合约
    bool    private inSwap;
    bool    private _inLiquidityAdd;
    modifier lockTheSwap() { inSwap = true; _; inSwap = false; }

    // Events
    event TradingEnabled();
    event PresaleEnded();
    event DividendProcessed(uint256 tokensSwapped, uint256 dividendReceived);
    event DividendClaimed(address indexed holder, uint256 amount);
    event Mint(address indexed user, uint256 bnbCost, uint256 tokenAmount);
    event InitialLiquidityAdded(uint256 tokens, uint256 bnb);
    event DividendTrackerUpdated(address indexed oldTracker, address indexed newTracker);
    event TaxDistributorUpdated(address indexed oldDistributor, address indexed newDistributor);

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
        require(buyTax_ <= MAX_TAX, "Buy tax too high");
        require(sellTax_ <= MAX_TAX, "Sell tax too high");
        require(marketingPct_ + burnPct_ + dividendPct_ + liquidityPct_ <= 10000, "Tax alloc > 100%");
        require(fillBNB_ > 0, "Fill must > 0");
        require(mintCostBNB_ > 0, "Mint cost > 0");
        require(fillBNB_ >= mintCostBNB_, "Fill < mint cost");
        require(marketingWallet_ != address(0), "Wallet zero");
        require(presaleTokenPct_ >= 1 && presaleTokenPct_ <= 99, "Presale pct 1-99");
        require(lpTokenPct_ <= 100, "LP pct > 100");

        _name = name_;
        _symbol = symbol_;
        _totalSupply = SafeMath.mul(totalSupply_, 1e18);
        _balances[address(this)] = _totalSupply;

        dividendTracker = new ModaDividendTracker(minHoldForDividend_, address(this));

        buyTaxBps = buyTax_;
        sellTaxBps = sellTax_;
        marketingBps = marketingPct_;
        burnBps = burnPct_;
        dividendBps = dividendPct_;
        liquidityBps = liquidityPct_;
        marketingWallet = marketingWallet_;

        IUniswapV2Router02 _router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        uniswapV2Router = _router;
        uniswapV2Pair = IUniswapV2Factory(_router.factory()).createPair(address(this), _router.WETH());

        isExcludedFromTax[address(this)] = true;
        isExcludedFromTax[owner()] = true;
        isExcludedFromTax[marketingWallet_] = true;
        isExcludedFromTax[address(_router)] = true;

        dividendTracker.excludeFromDividends(address(this), true);
        dividendTracker.excludeFromDividends(address(0), true);
        dividendTracker.excludeFromDividends(uniswapV2Pair, true);
        dividendTracker.excludeFromDividends(owner(), true);

        whitelistMintOnly = whitelistMintOnly_;
        presaleActive = true;
        tradingActive = false;
        autoOpenTrading = autoOpenTrading_;

        mintCostBNB = mintCostBNB_;
        fillAmountBNB = fillBNB_;
        lpTokenPct = lpTokenPct_;
        uint256 mintCount = SafeMath.div(fillBNB_, mintCostBNB_);
        tokensPerMint = SafeMath.div(SafeMath.mul(_totalSupply, presaleTokenPct_), SafeMath.mul(100, mintCount));
        tokensPerLP = SafeMath.div(SafeMath.mul(tokensPerMint, lpTokenPct_), 100);
        presaleTokenPct = presaleTokenPct_;
    }

    // ── ERC20 ──
    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public pure returns (uint8) { return _decimals; }
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

    function _approve(address _owner, address spender, uint256 amount) internal {
        require(_owner != address(0) && spender != address(0));
        _allowances[_owner][spender] = amount;
        emit Approval(_owner, spender, amount);
    }

    receive() external payable {
        if (presaleActive && msg.value == mintCostBNB) {
            mint();
        }
        // 其他 BNB（如 rescue 等）正常接收
    }

    // ── _transfer ──
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "Zero address");
        require(amount > 0, "Amount zero");
        require(_balances[from] >= amount, "Insufficient balance");

    bool isDexTransfer = (from == uniswapV2Pair || to == uniswapV2Pair);
    // 允许 TaxDistributor 和 DividendTracker 在交易未激活时进行 swap
    bool isTaxContract = (from == taxDistributor || to == taxDistributor ||
                          from == address(dividendTracker) || to == address(dividendTracker));
    if (isDexTransfer && !tradingActive && !isTaxContract) {
        require(isExcludedFromTax[from] || isExcludedFromTax[to], "Trading not active");
    }

        bool isBuy  = (from == uniswapV2Pair && to != address(uniswapV2Router)) && !_inLiquidityAdd;
        bool isSell = (to == uniswapV2Pair && from != address(uniswapV2Router)) && !_inLiquidityAdd;
        uint256 taxAmount = 0;

        if (!isExcludedFromTax[from] && !isExcludedFromTax[to]) {
            if (isBuy)  taxAmount = SafeMath.mul(amount, buyTaxBps) / 10000;
            if (isSell) taxAmount = SafeMath.mul(amount, sellTaxBps) / 10000;
        }

        uint256 sendAmt = SafeMath.sub(amount, taxAmount);

        _balances[from] = SafeMath.sub(_balances[from], amount);
        _balances[to]   = SafeMath.add(_balances[to], sendAmt);

        if (taxAmount > 0) {
            _balances[address(this)] = SafeMath.add(_balances[address(this)], taxAmount);
            _handleTax(from, taxAmount);
        }

        _updateTrackerBalance(from);
        _updateTrackerBalance(to);

        if (!inSwap) _tryProcessDividendTracker();

        emit Transfer(from, to, sendAmt);
    }

    /**
     * @dev 税费处理：直接转发给 TaxDistributor，主合约不碰 swap
     *      如果 taxDistributor 未设置，税费暂留合约内（可被 rescueToken 提取）。
     *      burn 部分直接销毁，不转发。
     */
    function _handleTax(address from, uint256 taxAmt) internal {
        uint256 burn = SafeMath.mul(taxAmt, burnBps) / 10000;
        // liq + div + marketing 全部打包转发给 TaxDistributor
        uint256 fwd = taxAmt - burn;

        if (burn > 0) {
            address dead = 0x000000000000000000000000000000000000dEaD;
            _balances[address(this)] = SafeMath.sub(_balances[address(this)], burn);
            emit Transfer(address(this), dead, burn);
        }

        if (fwd > 0 && taxDistributor != address(0)) {
            // 代币从合约转出，合约余额减少，税费合约余额增加
            _balances[address(this)] = SafeMath.sub(_balances[address(this)], fwd);
            _balances[taxDistributor] = SafeMath.add(_balances[taxDistributor], fwd);
            emit Transfer(address(this), taxDistributor, fwd);
            // 注意：不在此处自动触发 tryProcess()
            // 因为当 _handleTax 被 pair.swap 内部的 token 转账触发时，
            // PancakeSwap Pair 仍处于 LOCKED 状态，此时调用 tryProcess
            // 会形成重入链 → Pancake: LOCKED
            // 税费处理改为通过 admin.html 的 forceProcess 手动执行
        } else if (fwd > 0) {
            // taxDistributor 未设置，税费暂留合约内
            // _balances[address(this)] 已在 _transfer 中增加，此处无需重复
            // 仅补发事件，代币实际已在合约余额中
            emit Transfer(from, address(this), fwd);
        }
    }

    function _tryProcessDividendTracker() internal {
        try dividendTracker.process(100000) {} catch {}
    }

    // ── 分红余额同步 ──
    function _updateTrackerBalance(address account) internal {
        dividendTracker.setBalance(payable(account), _balances[account]);
    }

    // ═══════════════════════════════════════════
    //  TaxDistributor 管理
    // ═══════════════════════════════════════════

    /**
     * @dev 设置税费分配合约地址（发射时由 launch.html 自动调用）
     */
    function setTaxDistributor(address _dist) external onlyOwner {
        require(_dist != address(0), "Zero address");
        emit TaxDistributorUpdated(taxDistributor, _dist);
        taxDistributor = _dist;
        isExcludedFromTax[_dist] = true;
    }

    /**
     * @dev Owner 手动把合约内暂留的代币转发到 TaxDistributor
     *      （仅当 taxDistributor 后设时使用）
     */
    function forwardTaxTokens() external onlyOwner {
        require(taxDistributor != address(0), "TaxDistributor not set");
        uint256 bal = _balances[address(this)];
        if (bal > 0) {
            _balances[address(this)] = 0;
            _balances[taxDistributor] = SafeMath.add(_balances[taxDistributor], bal);
            emit Transfer(address(this), taxDistributor, bal);
        }
    }

    // ═══════════════════════════════════════════
    //  Mint（预售公平发射）
    // ═══════════════════════════════════════════

    // ── 前端兼容别名（mint.html 使用的旧函数名）──
    function mintPrice()      external view returns (uint256) { return mintCostBNB; }
    function hardCap()        external view returns (uint256) { return fillAmountBNB; }
    function totalMinted()    external view returns (uint256) { return totalBNBCollected; }
    function tradingEnabled() external view returns (bool)   { return tradingActive; }
    function openMode()       external pure returns (uint8)   { return 0; }
    function whitelistOnly()  external view returns (bool)   { return whitelistMintOnly; }
    function hasMinted(address user) external view returns (bool) { return whitelistMinted[user]; }
    function mintBatchSize()  external view returns (uint256) { return mintCostBNB; }

    function setMintPrice(uint256 costBNB_, uint256 fillBNB_) external onlyOwner {
        require(costBNB_ > 0 && fillBNB_ >= costBNB_, "Invalid params");
        mintCostBNB = costBNB_;
        fillAmountBNB = fillBNB_;
        tokensPerMint = SafeMath.div(
            SafeMath.mul(_totalSupply, presaleTokenPct),
            SafeMath.mul(100, SafeMath.div(fillBNB_, costBNB_))
        );
    }

    function addWhitelist(address[] calldata users) external onlyOwner {
        for (uint i = 0; i < users.length; i = SafeMath.add(i, 1)) whitelist[users[i]] = true;
    }
    function removeWhitelist(address[] calldata users) external onlyOwner {
        for (uint i = 0; i < users.length; i = SafeMath.add(i, 1)) {
            whitelist[users[i]] = false;
            whitelistMinted[users[i]] = false;
        }
    }
    function setWhitelistMintOnly(bool v) external onlyOwner { whitelistMintOnly = v; }
    function resetWhitelistMinted(address[] calldata users) external onlyOwner {
        for (uint i = 0; i < users.length; i = SafeMath.add(i, 1)) whitelistMinted[users[i]] = false;
    }

    function mint() public payable {
        require(presaleActive, "Presale not active");
        require(msg.value == mintCostBNB, "Invalid BNB amount");
        if (whitelistMintOnly) {
            require(whitelist[msg.sender], "Not whitelisted");
            require(!whitelistMinted[msg.sender], "Already minted");
        }
        require(totalBNBCollected + msg.value <= fillAmountBNB, "Presale full");
        totalBNBCollected = SafeMath.add(totalBNBCollected, msg.value);
        uint256 tokenAmt = tokensPerMint;
        require(_balances[address(this)] >= SafeMath.add(tokenAmt, tokensPerLP), "Insufficient contract balance");
        _balances[msg.sender] = SafeMath.add(_balances[msg.sender], tokenAmt);
        _balances[address(this)] = SafeMath.sub(_balances[address(this)], tokenAmt);
        mintedAmount[msg.sender] = SafeMath.add(mintedAmount[msg.sender], tokenAmt);
        if (whitelistMintOnly) whitelistMinted[msg.sender] = true;
        emit Mint(msg.sender, msg.value, tokenAmt);
        emit Transfer(address(this), msg.sender, tokenAmt);
        _updateTrackerBalance(msg.sender);
        if (tokensPerLP > 0) {
            _addMintLiquidity(msg.value);
        }
        if (totalBNBCollected >= fillAmountBNB) {
            presaleActive = false;
            emit PresaleEnded();
            if (autoOpenTrading) {
                tradingActive = true;
                emit TradingEnabled();
            }
        }
    }

    event AddLiquidityFailed(uint256 bnbAmount, string reason);

    function _addMintLiquidity(uint256 bnbAmount) internal {
        _inLiquidityAdd = true;
        uint256 tokenForLP = tokensPerLP;
        _approve(address(this), address(uniswapV2Router), tokenForLP);
        try uniswapV2Router.addLiquidityETH{value: bnbAmount}(
            address(this), tokenForLP, 0, 0, owner(), block.timestamp + 300
        ) returns (uint256 tokenUsed, uint256 bnbUsed, uint256 liquidity) {
            emit InitialLiquidityAdded(tokenUsed, bnbUsed);
        } catch Error(string memory reason) {
            emit AddLiquidityFailed(bnbAmount, reason);
            // 加池失败不影响 mint 成功，owner 可稍后手动加池
        } catch {
            emit AddLiquidityFailed(bnbAmount, "AddLiquidityFailed");
        }
        _inLiquidityAdd = false;
    }

    // ═══════════════════════════════════════════
    //  Admin 管理
    // ═══════════════════════════════════════════

    function setBuyTax(uint256 bps) external onlyOwner { require(bps <= MAX_TAX); buyTaxBps = bps; }
    function setSellTax(uint256 bps) external onlyOwner { require(bps <= MAX_TAX); sellTaxBps = bps; }
    function setMarketingWallet(address w) external onlyOwner { require(w != address(0)); marketingWallet = w; }
    function excludeFromTax(address a, bool ex) external onlyOwner { isExcludedFromTax[a] = ex; }

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

    function setMinHoldForDividend(uint256 amt) external onlyOwner {
        dividendTracker.setMinimumTokenBalanceForDividends(amt);
    }

    function enableTrading() external onlyOwner {
        require(!tradingActive, "Already active");
        tradingActive = true;
        emit TradingEnabled();
    }

    function setAutoOpenTrading(bool _v) external onlyOwner {
        autoOpenTrading = _v;
    }

    // ── 手动管理 LP ──

    /**
     * @dev Owner 存入 BNB，配对合约内代币加底池。LP 发给 owner。
     */
    function addLiquidityWithBNB(uint256 tokenAmount) external payable onlyOwner {
        require(msg.value > 0, "Send BNB");
        require(tokenAmount > 0, "Token amount > 0");
        require(_balances[address(this)] >= tokenAmount, "Insufficient tokens");
        _inLiquidityAdd = true;
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        try uniswapV2Router.addLiquidityETH{value: msg.value}(
            address(this), tokenAmount, 0, 0, owner(), block.timestamp + 300
        ) returns (uint256 tokenUsed, uint256 bnbUsed, uint256 liquidity) {
            // 成功
        } catch Error(string memory reason) {
            _inLiquidityAdd = false;
            revert(string(abi.encodePacked("Add liquidity failed: ", reason)));
        } catch {
            _inLiquidityAdd = false;
            revert("Add liquidity failed");
        }
        _inLiquidityAdd = false;
    }

    /**
     * @dev 撤除底池：销毁 LP，取回代币 + BNB，返回给 owner
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
     * @dev 提取合约中的 LP 代币（不撤池）
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

    function withdrawBNB() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    /**
     * @dev 提取任意 ERC20 代币（防止误转入后无法取出）
     */
    function emergencyWithdrawToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    // ═══════════════════════════════════════════
    //  Dividend 管理
    // ═══════════════════════════════════════════

    function setDividendTracker(ModaDividendTracker newTracker) external onlyOwner {
        emit DividendTrackerUpdated(address(dividendTracker), address(newTracker));
        dividendTracker = newTracker;
    }

    function triggerDividendProcess(uint256 gas) external onlyOwner {
        dividendTracker.process(gas);
    }

    function claimDividend() external {
        dividendTracker.processAccount(payable(msg.sender), false);
    }

    function setDividendClaimWait(uint256 wait_) external onlyOwner {
        dividendTracker.setClaimWait(wait_);
    }

    function excludeFromDividend(address account, bool excluded) external onlyOwner {
        dividendTracker.excludeFromDividends(account, excluded);
    }

    function dividendTrackerEmergencyWithdrawBNB() external onlyOwner {
        dividendTracker.emergencyWithdrawBNB();
    }

    function dividendTrackerEmergencyWithdrawToken(address _token, uint256 _amount) external onlyOwner {
        dividendTracker.emergencyWithdrawToken(_token, _amount);
    }
}
