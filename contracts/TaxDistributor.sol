// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title TaxDistributor — BSC 税费分配合约（v5 精简版）
 *
 *  极简流程：税费代币 → swap 成 BNB → 发给营销钱包
 *  没有中转合约，BNB 直接进本合约，不会卡住
 *
 *  仍保留分红和 LP 回流功能（通过 bps 配置开关）：
 *    - marketingBps + dividendBps + lpBps = 税费分配比例
 *    - 全部设为 0 时不会处理
 *    - 只想发营销钱包？设 marketingBps=10000, dividendBps=0, lpBps=0 即可
 *
 *  构造参数：
 *   1. token_           — 主代币合约地址
 *   2. marketingWallet_ — 营销收款地址
 *   3. dividendTracker_ — 分红合约地址（不需要分红填 address(0)）
 *   4. rewardToken_     — 奖励代币地址（address(0) = BNB）
 *   5. router_          — PancakeSwap V2 Router
 *   6. _marketingBps    — 营销 bps
 *   7. _dividendBps     — 分红 bps
 *   8. _lpBps           — LP 回流 bps
 */

// ═══════════════════════════════════════════════════
//  Interfaces
// ═══════════════════════════════════════════════════

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address, uint256) external returns (bool);
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
    ) external;

    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

// ═══════════════════════════════════════════════════
//  Ownable
// ═══════════════════════════════════════════════════

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
        require(owner() == msg.sender, "Ownable: not owner");
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

// ═══════════════════════════════════════════════════
//  SafeERC20（轻量版，兼容 USDT）
// ═══════════════════════════════════════════════════

library SafeERC20 {
    bytes4 private constant SIG_TRANSFER = bytes4(keccak256("transfer(address,uint256)"));
    bytes4 private constant SIG_APPROVE  = bytes4(keccak256("approve(address,uint256)"));

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool ok, bytes memory d) = address(token).call(
            abi.encodeWithSelector(SIG_TRANSFER, to, value)
        );
        require(ok && (d.length == 0 || abi.decode(d, (bool))), "SafeERC20: transfer failed");
    }

    function safeIncreaseAllowance(IERC20 token, address spender, uint256 newAllowance) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current >= newAllowance) return;

        // 先尝试直接设置
        (bool ok, bytes memory d) = address(token).call(
            abi.encodeWithSelector(SIG_APPROVE, spender, newAllowance)
        );
        if (ok && (d.length == 0 || abi.decode(d, (bool)))) return;

        // 兜底：先置 0 再设值（兼容 USDT）
        (ok, d) = address(token).call(abi.encodeWithSelector(SIG_APPROVE, spender, 0));
        require(ok && (d.length == 0 || abi.decode(d, (bool))), "SafeERC20: approve reset failed");

        (ok, d) = address(token).call(abi.encodeWithSelector(SIG_APPROVE, spender, newAllowance));
        require(ok && (d.length == 0 || abi.decode(d, (bool))), "SafeERC20: approve failed");
    }
}

// ═══════════════════════════════════════════════════
//  TaxDistributor（主合约 — 无中转，BNB 直收到本合约）
// ═══════════════════════════════════════════════════

contract TaxDistributor is Ownable {
    using SafeERC20 for IERC20;

    // ── 核心配置 ──
    address public token;             // 主代币合约地址
    address public marketingWallet;   // 营销收款地址
    address public dividendTracker;   // 分红合约地址（address(0) = 不分红）
    address public rewardToken;       // 奖励代币（address(0) = BNB，其他 = ERC20）
    IUniswapV2Router02 public router;

    // WBNB 地址（BSC 主网）
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    // ── 分配比例（bps，10000 = 100%）──
    uint256 public marketingBps;
    uint256 public dividendBps;
    uint256 public lpBps;
    uint256 public constant MAX_BPS = 10000;

    // ── 处理阈值 ──
    uint256 public minProcessAmount = 1 * 1e18;

    // ── 权限控制 ──
    bool public autoProcess = true;

    // ── 状态记录 ──
    string  public lastFailureReason;
    uint256 public lastProcessTime;
    uint256 public totalFeesProcessed;

    // ── 防重入 ──
    bool private inProcessing;

    // ── Events ──
    event FeesProcessed(
        uint256 indexed tokenAmount,
        uint256 bnbToMarketing,
        uint256 bnbToDividend,
        uint256 bnbToLP
    );
    event ProcessFailed(uint256 tokenAmount, string reason);
    event ConfigUpdated(string key);
    event BpsUpdated(uint256 marketingBps, uint256 dividendBps, uint256 lpBps);
    event RewardTokenUpdated(address rewardToken);
    event RescueToken(address indexed tokenAddr, address indexed to, uint256 amount);
    event RescueBNB(address indexed to, uint256 amount);
    event SwapDebug(string step, uint256 value);

    // ═══════════════════════════════════════════════════
    //  构造函数
    // ═══════════════════════════════════════════════════

    /**
     * @param token_           主代币合约地址
     * @param marketingWallet_ 营销收款地址
     * @param dividendTracker_ 分红合约地址（不需要分红填 address(0)）
     * @param rewardToken_     奖励代币地址（address(0) = BNB 原生分红）
     * @param router_          PancakeSwap V2 Router 地址
     * @param _marketingBps   营销分配 bps
     * @param _dividendBps    分红分配 bps
     * @param _lpBps           LP 回流 bps
     */
    constructor(
        address token_,
        address marketingWallet_,
        address dividendTracker_,
        address rewardToken_,
        address router_,
        uint256 _marketingBps,
        uint256 _dividendBps,
        uint256 _lpBps
    ) Ownable(address(0)) {
        require(token_          != address(0), "TaxDist: token zero");
        require(marketingWallet_ != address(0), "TaxDist: wallet zero");
        require(router_         != address(0), "TaxDist: router zero");
        require(
            _marketingBps + _dividendBps + _lpBps <= MAX_BPS,
            "TaxDist: BPS > 100%"
        );

        token            = token_;
        marketingWallet  = marketingWallet_;
        dividendTracker  = dividendTracker_;
        rewardToken      = rewardToken_;
        router           = IUniswapV2Router02(router_);
        marketingBps     = _marketingBps;
        dividendBps      = _dividendBps;
        lpBps            = _lpBps;
    }

    // BNB 直接进入本合约，空 receive 不做任何操作
    receive() external payable {}

    // ═══════════════════════════════════════════════════
    //  外部触发入口
    // ═══════════════════════════════════════════════════

    /**
     * @notice 触发税费处理
     *         autoProcess=true  → 任何人都可调用
     *         autoProcess=false → 仅 owner 可调用
     */
    function processFees() external {
        if (inProcessing) {
            lastFailureReason = "Already processing, retry later";
            return;
        }
        if (!autoProcess && msg.sender != owner()) {
            lastFailureReason = "Not authorized (autoProcess=false)";
            return;
        }
        inProcessing = true;
        _processCore();
        inProcessing = false;
    }

    /**
     * @notice owner 强制处理（忽略 autoProcess 开关）
     */
    function forceProcess() external onlyOwner {
        if (inProcessing) {
            lastFailureReason = "Already processing, retry later";
            return;
        }
        inProcessing = true;
        _processCore();
        inProcessing = false;
    }

    /**
     * @notice 安全触发，永不 revert（供外部合约调用）
     *         失败时只更新 lastFailureReason，不影响调用方
     */
    function tryProcess() external {
        if (inProcessing) {
            lastFailureReason = "Already processing, try later";
            return;
        }
        inProcessing = true;
        _processCore();
        inProcessing = false;
    }

    /**
     * @notice 应急解锁：当 inProcessing 意外为 true 时，
     *         owner 可强制重置，使处理功能恢复正常
     */
    function forceUnlock() external onlyOwner {
        require(inProcessing, "Not locked");
        inProcessing = false;
        lastFailureReason = "Force unlocked by owner";
        emit ConfigUpdated("forceUnlock");
    }

    // ═══════════════════════════════════════════════════
    //  核心处理逻辑（极简版）
    //
    //  流程：
    //  1. 检查代币余额 ≥ minProcessAmount
    //  2. swap 全部代币 → BNB（直接打到本合约）
    //  3. 按 bps 分配 BNB：营销 / 分红 / LP
    // ═══════════════════════════════════════════════════

    function _processCore() internal {
        uint256 balance = IERC20(token).balanceOf(address(this));

        if (balance < minProcessAmount) {
            lastFailureReason = "Balance < minProcessAmount";
            return;
        }

        lastFailureReason = "";

        uint256 totalBps = marketingBps + dividendBps + lpBps;
        if (totalBps == 0) {
            lastFailureReason = "All BPS = 0, nothing to process";
            return;
        }

        // ── 计算 LP 部分需要留多少代币 ──────────────────
        // LP 部分：一半代币留着加底池，一半代币跟着一起 swap 成 BNB
        uint256 lpTokenTotal  = (balance * lpBps)       / totalBps;
        uint256 lpTokenKeep   = lpTokenTotal / 2;            // 直接用于加底池的代币
        uint256 lpTokenToSwap = lpTokenTotal - lpTokenKeep;   // swap → BNB 作底池配对
        uint256 swapTotal     = balance - lpTokenKeep;        // 需要 swap 的总量

        if (swapTotal == 0) {
            lastFailureReason = "swapTotal = 0";
            return;
        }

        // ── 授权 Router ──
        IERC20(token).safeIncreaseAllowance(address(router), swapTotal);

        // ── Step 1: swap 代币 → BNB（BNB 直接进本合约）──
        uint256 bnbBefore = address(this).balance;
        _swapTokensForBNB(swapTotal);
        uint256 bnbReceived = address(this).balance - bnbBefore;

        if (bnbReceived == 0) {
            // lastFailureReason 已在 _swapTokensForBNB 内设置
            emit ProcessFailed(balance, lastFailureReason);
            return;
        }

        lastProcessTime   = block.timestamp;
        totalFeesProcessed += balance;

        // ── Step 2: 按 bps 分配 BNB ──────────────────────
        uint256 bnbForMarketing = (bnbReceived * marketingBps) / totalBps;
        uint256 bnbForDividend  = (bnbReceived * dividendBps)  / totalBps;
        uint256 bnbForLP        = bnbReceived - bnbForMarketing - bnbForDividend;

        // ── Step 3: 发送营销 BNB ─────────────────────────
        if (bnbForMarketing > 0) {
            (bool ok, ) = payable(marketingWallet).call{value: bnbForMarketing}("");
            if (!ok) {
                lastFailureReason = "Marketing BNB transfer failed";
                emit SwapDebug("marketing Xfer failed", bnbForMarketing);
            }
        }

        // ── Step 4: 处理分红 ────────────────────────────
        if (bnbForDividend > 0 && dividendTracker != address(0)) {
            _distributeDividend(bnbForDividend);
        }

        // ── Step 5: 加底池（LP 回流） ────────────────────
        if (lpTokenKeep > 0 && bnbForLP > 0) {
            _addLiquiditySafe(lpTokenKeep, bnbForLP);
        }

        emit FeesProcessed(balance, bnbForMarketing, bnbForDividend, bnbForLP);
    }

    // ═══════════════════════════════════════════════════
    //  分红分发（支持 BNB / WBNB / 其他 ERC20）
    // ═══════════════════════════════════════════════════

    function _distributeDividend(uint256 bnbAmount) internal {
        if (rewardToken == address(0)) {
            // 模式 1：直接发 BNB
            (bool ok, ) = payable(dividendTracker).call{value: bnbAmount}("");
            if (!ok) {
                lastFailureReason = "Dividend BNB transfer failed";
                emit SwapDebug("dividend BNB Xfer failed", bnbAmount);
            }
        } else if (rewardToken == WBNB) {
            // 模式 2：wrap 成 WBNB 再发
            try IWBNB(WBNB).deposit{value: bnbAmount}() {
                IERC20(WBNB).safeTransfer(dividendTracker, bnbAmount);
            } catch {
                lastFailureReason = "WBNB wrap/send failed";
                emit SwapDebug("WBNB wrap failed", bnbAmount);
            }
        } else {
            // 模式 3：用 BNB 买奖励代币，直接打到 dividendTracker
            address[] memory path = new address[](2);
            path[0] = WBNB;
            path[1] = rewardToken;

            uint256 trackerBalBefore = IERC20(rewardToken).balanceOf(dividendTracker);

            try router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: bnbAmount}(
                0,
                path,
                dividendTracker,
                block.timestamp + 300
            ) {
                uint256 trackerBalAfter = IERC20(rewardToken).balanceOf(dividendTracker);
                if (trackerBalAfter <= trackerBalBefore) {
                    lastFailureReason = "Dividend swap: tracker balance unchanged";
                    emit SwapDebug("dividend swap no increase", bnbAmount);
                }
            } catch {
                lastFailureReason = "Dividend swap failed";
                emit SwapDebug("dividend swap failed", bnbAmount);
            }
        }
    }

    // ═══════════════════════════════════════════════════
    //  内部函数：swap / addLiquidity
    // ═══════════════════════════════════════════════════

    /**
     * @dev swap 代币 → BNB，BNB 直接打到本合约 address(this)
     *      双通道兜底：FOT 版（首选）→ 标准版（兜底）
     */
    function _swapTokensForBNB(uint256 tokenAmount) internal {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = router.WETH();   // BSC: WBNB

        // 通道 1：FOT 安全版（首选，支持有转账税的代币）
        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            1,                      // amountOutMin = 1 wei
            path,
            address(this),          // ← BNB 直接进本合约！
            block.timestamp + 300
        ) {
            return;                  // 成功就返回
        } catch {
            emit SwapDebug("FOT swap failed, trying std", tokenAmount);
        }

        // 通道 2：标准版（兜底）
        try router.swapExactTokensForETH(
            tokenAmount,
            1,
            path,
            address(this),          // ← BNB 直接进本合约！
            block.timestamp + 300
        ) {
            return;
        } catch Error(string memory reason) {
            lastFailureReason = reason;
            emit ProcessFailed(tokenAmount, reason);
        } catch {
            lastFailureReason = "Both swap channels failed";
            emit ProcessFailed(tokenAmount, "unknown");
        }
    }

    /**
     * @dev 安全加底池（失败不 revert）
     *      LP Token 发给 0xdead 销毁（锁池）
     */
    function _addLiquiditySafe(uint256 tokenAmt, uint256 bnbAmt) internal {
        IERC20(token).safeIncreaseAllowance(address(router), tokenAmt);
        try router.addLiquidityETH{value: bnbAmt}(
            token,
            tokenAmt,
            0, 0,
            address(0xdead),        // LP 发到黑洞地址，锁池
            block.timestamp + 300
        ) {
            emit SwapDebug("LP add success", tokenAmt);
        } catch Error(string memory err) {
            lastFailureReason = string(abi.encodePacked("LP add failed: ", err));
            emit SwapDebug("LP add failed", tokenAmt);
        } catch {
            lastFailureReason = "LP add failed: unknown";
            emit SwapDebug("LP add failed (unknown)", tokenAmt);
        }
    }

    // ═══════════════════════════════════════════════════
    //  Owner 配置管理
    // ═══════════════════════════════════════════════════

    function setMarketingWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "Zero address");
        marketingWallet = _wallet;
        emit ConfigUpdated("marketingWallet");
    }

    function setDividendTracker(address _tracker) external onlyOwner {
        dividendTracker = _tracker;
        emit ConfigUpdated("dividendTracker");
    }

    function setRewardToken(address _rewardToken) external onlyOwner {
        rewardToken = _rewardToken;
        emit RewardTokenUpdated(_rewardToken);
    }

    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "Zero address");
        router = IUniswapV2Router02(_router);
        emit ConfigUpdated("router");
    }

    function setToken(address _token) external onlyOwner {
        require(_token != address(0), "Zero address");
        token = _token;
        emit ConfigUpdated("token");
    }

    function setBps(
        uint256 _marketingBps,
        uint256 _dividendBps,
        uint256 _lpBps
    ) external onlyOwner {
        require(
            _marketingBps + _dividendBps + _lpBps <= MAX_BPS,
            "TaxDist: BPS sum > 100%"
        );
        marketingBps = _marketingBps;
        dividendBps  = _dividendBps;
        lpBps        = _lpBps;
        emit BpsUpdated(_marketingBps, _dividendBps, _lpBps);
    }

    function setMinProcessAmount(uint256 _amt) external onlyOwner {
        minProcessAmount = _amt;
        emit ConfigUpdated("minProcessAmount");
    }

    function setAutoProcess(bool _on) external onlyOwner {
        autoProcess = _on;
        emit ConfigUpdated("autoProcess");
    }

    // ═══════════════════════════════════════════════════
    //  紧急救援
    // ═══════════════════════════════════════════════════

    /**
     * @notice 从本合约提取误转入的 ERC20 代币
     */
    function rescueToken(address _token, address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Zero address");
        IERC20(_token).safeTransfer(_to, _amount);
        emit RescueToken(_token, _to, _amount);
    }

    /**
     * @notice 提取本合约内 BNB
     */
    function rescueBNB(address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Zero address");
        uint256 bal = address(this).balance;
        require(_amount > 0 && _amount <= bal, "Invalid amount");
        (bool ok, ) = payable(_to).call{value: _amount}("");
        require(ok, "BNB transfer failed");
        emit RescueBNB(_to, _amount);
    }

    // ═══════════════════════════════════════════════════
    //  查询接口
    // ═══════════════════════════════════════════════════

    function getStatus() external view returns (
        address token_,
        uint256 tokenBalance,
        uint256 bnbBalance,
        uint256 minProcessAmt,
        uint256 mktBps,
        uint256 divBps,
        uint256 lpBps_,
        bool    auto_,
        string  memory lastFailure,
        uint256 lastProcess,
        uint256 totalProcessed
    ) {
        return (
            token,
            IERC20(token).balanceOf(address(this)),
            address(this).balance,
            minProcessAmount,
            marketingBps,
            dividendBps,
            lpBps,
            autoProcess,
            lastFailureReason,
            lastProcessTime,
            totalFeesProcessed
        );
    }

    /**
     * @notice 检查是否可以触发处理
     * @return can      true = 余额足够，可以处理
     * @return current  当前合约内代币余额
     * @return required 最低处理阈值
     */
    function canProcess() external view returns (bool can, uint256 current, uint256 required) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        return (bal >= minProcessAmount, bal, minProcessAmount);
    }
}
