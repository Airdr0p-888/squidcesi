// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title TaxDistributor — BSC 税费分配合约（v4（TokenDistributor 中转 + 多奖励代币）
 *
 *  核心改进（借鉴 UniverseLaunch 设计）：
 *  1. TokenDistributor 中转模式
 *     - swap 时 BNB 先打到 TokenDistributor，再 claim 回来
 *     - 隔离风险：swap 过程中 BNB 不在本合约，不会意外触发 receive()
 *  2. 支持多奖励代币配置
 *     - rewardToken = address(0)  → 直接分发 BNB 到 dividendTracker
 *     - rewardToken = WBNB       → wrap BNB 成 WBNB 再分发
 *     - rewardToken = 其他 ERC20 → 用 BNB 买奖励代币再分发
 *
 *  部署参数（对应 launch.html）：
 *   1. token_           — 主代币合约地址
 *   2. marketingWallet_ — 营销收款地址
 *   3. dividendTracker_ — 分红合约地址
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

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
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

    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        (bool ok, bytes memory d) = address(token).call(
            abi.encodeWithSelector(SIG_APPROVE, spender, value)
        );
        require(ok && (d.length == 0 || abi.decode(d, (bool))), "SafeERC20: approve failed");
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
//  TokenDistributor（中转合约，隔离 swap 风险）
// ═══════════════════════════════════════════════════
//
//  设计来源：UniverseLaunch 的 TokenDistributor 模式
//  - swap 时 BNB 先打到本合约，不直接进 TaxDistributor
//  - 避免 BNB 在 TaxDistributor 触发 receive() 意外逻辑
//  - owner 是部署者（即 TaxDistributor 合约地址）
// ═══════════════════════════════════════════════════

contract TokenDistributor is Ownable {

    constructor() Ownable(address(0)) {
        // msg.sender = TaxDistributor 合约地址，设为 owner
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /**
     * @notice owner（TaxDistributor 合约）提取 BNB 到指定地址
     */
    function claim(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "TD: zero address");
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "TD: transfer failed");
    }

    /**
     * @notice 提取 TokenDistributor 内全部 BNB 到指定地址
     */
    function claimAll(address to) external onlyOwner {
        require(to != address(0), "TD: zero address");
        uint256 bal = address(this).balance;
        require(bal > 0, "TD: no BNB");
        (bool ok, ) = payable(to).call{value: bal}("");
        require(ok, "TD: transfer failed");
    }

    /**
     * @notice 救援误转入的 ERC20 代币
     */
    function rescueToken(address token_, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "TD: zero address");
        IERC20(token_).transfer(to, amount);
    }

    receive() external payable {}
}

// ═══════════════════════════════════════════════════
//  TaxDistributor（主合约）
// ═══════════════════════════════════════════════════

contract TaxDistributor is Ownable {
    using SafeERC20 for IERC20;

    // ── 核心配置 ──
    address public token;             // 主代币合约地址
    address public marketingWallet;   // 营销收款地址
    address public dividendTracker;   // 分红合约地址
    address public rewardToken;       // 奖励代币（address(0) = BNB，其他 = ERC20）
    IUniswapV2Router02 public router;

    // WBNB 地址（BSC 主网）
    address public constant WBNB = 0xbb4CDB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    // ── 分配比例（bps，10000 = 100%）──
    uint256 public marketingBps;
    uint256 public dividendBps;
    uint256 public lpBps;
    uint256 public constant MAX_BPS = 10000;

    // ── 处理阈值 ──
    uint256 public minProcessAmount = 1 * 1e18;

    // ── 权限控制 ──
    bool public autoProcess = true;

    // ── TokenDistributor 中转合约 ──
    TokenDistributor public tokenDistributor;

    // ── 状态记录 ──
    string  public lastFailureReason;
    uint256 public lastProcessTime;
    uint256 public totalFeesProcessed;

    // ── 防重入 ──
    bool private inProcessing;

    modifier lockProcessing() {
        require(!inProcessing, "TaxDist: reentrant");
        inProcessing = true;
        _;
        inProcessing = false;
    }

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
     * @param dividendTracker_ 分红合约地址
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

        // 部署中转合约，owner = 本合约地址
        tokenDistributor = new TokenDistributor();
    }

    receive() external payable {
        // BNB 进入时不做任何操作，避免 swap 过程中意外触发
    }

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
            lastFailureReason = "Already processing, please retry later";
            return;
        }
        if (!autoProcess && msg.sender != owner()) {
            lastFailureReason = "Not authorized (autoProcess=false)";
            return;
        }
        _doProcess();
    }

    /**
     * @notice owner 强制处理（忽略 autoProcess 开关）
     */
    function forceProcess() external onlyOwner {
        _doProcess();
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
        _tryProcessSafe();
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
    //  核心处理逻辑
    // ═══════════════════════════════════════════════════

    /**
     * @dev 带防重入的核心处理函数（供 processFees / forceProcess 调用）
     *
     * 处理流程（借鉴 UniverseLaunch）：
     * 1. 检查余额 ≥ minProcessAmount
     * 2. 按 bps 拆分 LP 份额和 swap 份额
     * 3. swap 代币 → BNB，BNB 直接打到 tokenDistributor（中转）
     * 4. 从 tokenDistributor claim BNB 回本合约
     * 5. 按 bps 分配 BNB：
     *    - 营销 → 直接转 BNB 到 marketingWallet
     *    - 分红 → 根据 rewardToken 类型处理，再转给 dividendTracker
     *    - LP   → 和代币一起 addLiquidityETH
     */
    function _doProcess() public lockProcessing {
        _processCore();
    }

    /**
     * @dev 不带 lockProcessing 的安全版本（供 tryProcess 调用）
     *      失败时只写 lastFailureReason，不 revert
     */
    function _tryProcessSafe() internal {
        _processCore();
    }

    /**
     * @dev 实际处理实现（两个入口共用）
     */
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

        // ── 拆分 LP 份额和 swap 份额 ──────────────────────
        // LP 部分：一半代币留着加底池，一半代币 swap 成 BNB 作底池的 BNB 端
        uint256 lpTokenTotal  = (balance * lpBps)       / totalBps;
        uint256 shareToken    = balance - lpTokenTotal;       // 营销 + 分红部分
        uint256 lpTokenKeep   = lpTokenTotal / 2;            // 直接用于加底池
        uint256 lpTokenToSwap = lpTokenTotal - lpTokenKeep;   // swap → BNB 作底池配对
        uint256 swapTotal     = shareToken + lpTokenToSwap;

        if (swapTotal == 0) {
            lastFailureReason = "swapTotal = 0";
            return;
        }

        // ── 授权 Router ──────────────────────────────────
        IERC20(token).safeIncreaseAllowance(address(router), swapTotal);

        // ── Step 1: swap 代币 → BNB，BNB 打到 tokenDistributor ──
        uint256 bnbBeforeSwap = address(tokenDistributor).balance;
        _swapTokensForBNB(swapTotal);
        uint256 bnbReceived = address(tokenDistributor).balance - bnbBeforeSwap;

        if (bnbReceived == 0) {
            // lastFailureReason 已在 _swapTokensForBNB 内设置
            emit ProcessFailed(balance, lastFailureReason);
            return;
        }

        // ── Step 2: 从中转合约 claim BNB 回本合约 ──────
        tokenDistributor.claim(address(this), bnbReceived);

        lastProcessTime   = block.timestamp;
        totalFeesProcessed += balance;

        // ── Step 3: 按来源比例拆分 BNB ───────────────────
        uint256 bnbForLP;
        uint256 bnbForShare;

        if (lpTokenToSwap > 0 && swapTotal > 0) {
            bnbForLP    = (bnbReceived * lpTokenToSwap) / swapTotal;
            bnbForShare = bnbReceived - bnbForLP;
        } else {
            bnbForLP    = 0;
            bnbForShare = bnbReceived;
        }

        // ── Step 4: 在 shareToken 对应的 BNB 中再分营销/分红 ──
        uint256 nonLpBps     = marketingBps + dividendBps;
        uint256 bnbForMarketing = 0;
        uint256 bnbForDividend = 0;

        if (nonLpBps > 0) {
            bnbForMarketing  = (bnbForShare * marketingBps) / nonLpBps;
            bnbForDividend   = bnbForShare - bnbForMarketing;
        }

        // ── Step 5: 发送营销 BNB ─────────────────────────
        if (bnbForMarketing > 0 && marketingWallet != address(0)) {
            (bool ok, ) = payable(marketingWallet).call{value: bnbForMarketing}("");
            if (!ok) {
                lastFailureReason = "Marketing BNB transfer failed";
                emit SwapDebug("marketing Xfer failed", bnbForMarketing);
            }
        }

        // ── Step 6: 处理分红（根据 rewardToken 类型） ───
        if (bnbForDividend > 0 && dividendTracker != address(0)) {
            _distributeDividend(bnbForDividend);
        }

        // ── Step 7: 加底池（LP 回流） ────────────────────
        if (lpTokenKeep > 0 && bnbForLP > 0) {
            _addLiquiditySafe(lpTokenKeep, bnbForLP);
        }

        emit FeesProcessed(balance, bnbForMarketing, bnbForDividend, bnbForLP);
    }

    // ═══════════════════════════════════════════════════
    //  分红分发（支持多奖励代币类型）
    // ═══════════════════════════════════════════════════

    /**
     * @dev 根据 rewardToken 类型分发分红
     *
     *  rewardToken == address(0)  → 直接发 BNB 到 dividendTracker
     *  rewardToken == WBNB         → wrap 成 WBNB 再发
     *  rewardToken == 其他 ERC20   → 用 BNB 买代币再发
     */
    function _distributeDividend(uint256 bnbAmount) internal {
        if (rewardToken == address(0)) {
            // 模式 1：直接分发 BNB（dividendTracker 需有 receive()）
            (bool ok, ) = payable(dividendTracker).call{value: bnbAmount}("");
            if (!ok) {
                lastFailureReason = "Dividend BNB transfer failed";
                emit SwapDebug("dividend BNB Xfer failed", bnbAmount);
            }
        } else if (rewardToken == WBNB) {
            // 模式 2：奖励代币是 WBNB → wrap 后转账
            try IWBNB(WBNB).deposit{value: bnbAmount}() {
                IERC20(WBNB).safeTransfer(dividendTracker, bnbAmount);
            } catch {
                lastFailureReason = "WBNB wrap/send failed";
                emit SwapDebug("WBNB wrap failed", bnbAmount);
            }
        } else {
            // 模式 3：奖励代币是其他 ERC20 → 用 BNB 买，再转给 tracker
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
                // 买入成功，dividendTracker 已直接收到奖励代币
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
     * @dev swap 代币 → BNB，BNB 打到 tokenDistributor（中转）
     *      双通道兜底策略：
     *        通道 1：FOT 版（有转账税的代币，PancakeSwap BSC 首选）
     *        通道 2：标准版（兜底）
     *      两个通道均失败时设置 lastFailureReason
     *      成功时不做任何判断，直接返回
     *      （调用方用 balance 差值判断实际收到多少）
     */
    function _swapTokensForBNB(uint256 tokenAmount) internal {
        address[] memory path = _getPath();

        // 通道 1：FOT 安全版（首选）
        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            1,
            path,
            address(tokenDistributor),
            block.timestamp + 300
        ) {
            // swap 成功，BNB 已打入 tokenDistributor，直接返回
            return;
        } catch {
            emit SwapDebug("FOT swap failed, trying std", tokenAmount);
        }

        // 通道 2：标准版（兜底）
        try router.swapExactTokensForETH(
            tokenAmount,
            1,
            path,
            address(tokenDistributor),
            block.timestamp + 300
        ) {
            // swap 成功，直接返回
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
     *      LP Token 发给 owner
     */
    function _addLiquiditySafe(uint256 tokenAmt, uint256 bnbAmt) internal {
        IERC20(token).safeIncreaseAllowance(address(router), tokenAmt);
        try router.addLiquidityETH{value: bnbAmt}(
            token,
            tokenAmt,
            0, 0,
            owner(),
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

    function _getPath() internal view returns (address[] memory path) {
        path = new address[](2);
        path[0] = token;
        path[1] = router.WETH();   // BSC: WBNB
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

    /**
     * @notice 设置奖励代币地址
     * @param _rewardToken address(0) = BNB 原生分红；其他 = ERC20 地址
     */
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
     * @notice 从中转合约 TokenDistributor 救援 BNB/代币
     */
    function rescueFromDistributor(address _to, uint256 _amount) external onlyOwner {
        tokenDistributor.claim(_to, _amount);
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

    /**
     * @notice 提取中转合约内全部 BNB 到 owner（紧急情况）
     */
    function rescueAllBNBFromDistributor(address _to) external onlyOwner {
        tokenDistributor.claimAll(_to);
    }

    // ═══════════════════════════════════════════════════
    //  查询接口
    // ═══════════════════════════════════════════════════

    function getStatus() external view returns (
        address token_,
        uint256 tokenBalance,
        uint256 bnbBalance,
        uint256 distributorBnbBalance,
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
            address(tokenDistributor).balance,
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
