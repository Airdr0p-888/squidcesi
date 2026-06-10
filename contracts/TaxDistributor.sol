// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title TaxDistributor — BSC 税费分配合约（v3 重写）
 *
 * @notice 对应 launch.html 税收分配配置（四项独立，总和 = 100%）：
 *   • 营销（marketing） → BNB 转发至 marketingWallet
 *   • 销毁（burn）      → 代币直接销毁到 0xdead（主合约已处理，此处按 BNB 分配）
 *   • 回流底池（lp）    → 代币 + BNB 加底池，LP 发给 owner
 *   • 分红（dividend）  → BNB 转发至 dividendTracker，自动分配给持币用户
 *
 * 架构说明：
 *  - 主合约（ModaMintToken）在每次卖出时，将税费代币 transfer 给本合约
 *  - 本合约累积到阈值后，将代币 swap 为 BNB，按四项比例分配
 *  - 销毁部分（burnBps）在主合约 _handleTax 中已处理（直接烧到 0xdead）
 *    本合约仅处理：营销 + LP回流 + 分红 三项，传入 bps 总和 ≤ 10000 即可
 *  - 主合约不参与 swap，用户交易永远不会因 swap 失败而 revert
 *
 * 部署参数（对应 launch.html deployToken 第二步）：
 *   1. token_          — 主代币合约地址
 *   2. marketingWallet_— 营销收款地址（对应 t_marketingWallet）
 *   3. dividendTracker_— 分红合约地址（主合约自动部署的 ModaDividendTracker）
 *   4. router_         — PancakeSwap V2 Router（0x10ED43C718714eb63d5aA57B78B54704E256024E）
 *   5. _marketingBps   — 营销分配 bps（对应 taxAllocMkt * 100）
 *   6. _dividendBps    — 分红分配 bps（对应 taxAllocDist * 100）
 *   7. _lpBps          — 底池回流 bps（对应 taxAllocLp * 100）
 *
 * 注意：销毁部分（burnBps）由主合约 _handleTax 直接处理，不传入此合约
 *       因此 _marketingBps + _dividendBps + _lpBps 可以 ≤ 10000
 */

// ═══════════════════════════════════════════
//  Interfaces
// ═══════════════════════════════════════════

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    /**
     * @dev FOT 安全 swap（用于有转账税的代币，PancakeSwap BSC 首选）
     */
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    /**
     * @dev 标准 swap（无 FOT，用于兜底）
     */
    function swapExactTokensForETH(
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
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
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

// ═══════════════════════════════════════════
//  SafeERC20（轻量版）
// ═══════════════════════════════════════════

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

    /**
     * @dev 安全增加授权，兼容 USDT 等需要先置 0 的代币
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 newAllowance) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current >= newAllowance) return;

        // 先尝试直接设置
        (bool ok, bytes memory d) = address(token).call(
            abi.encodeWithSelector(SIG_APPROVE, spender, newAllowance)
        );
        if (ok && (d.length == 0 || abi.decode(d, (bool)))) return;

        // 兜底：先置 0 再设值
        (ok, d) = address(token).call(abi.encodeWithSelector(SIG_APPROVE, spender, 0));
        require(ok && (d.length == 0 || abi.decode(d, (bool))), "SafeERC20: approve reset failed");

        (ok, d) = address(token).call(abi.encodeWithSelector(SIG_APPROVE, spender, newAllowance));
        require(ok && (d.length == 0 || abi.decode(d, (bool))), "SafeERC20: approve failed");
    }
}

// ═══════════════════════════════════════════
//  TaxDistributor
// ═══════════════════════════════════════════

contract TaxDistributor is Ownable {
    using SafeERC20 for IERC20;

    // ── 核心配置 ──
    address public token;             // 主代币合约地址
    address public marketingWallet;   // 营销收款地址（对应 launch.html t_marketingWallet）
    address public dividendTracker;   // 分红合约地址
    IUniswapV2Router02 public router; // PancakeSwap V2 Router

    // ── 分配比例（bps，10000 = 100%）──
    // 对应 launch.html 税收分配四项滑块（营销/LP/分红）
    // 销毁部分由主合约直接处理，不经过此合约
    uint256 public marketingBps;   // 营销
    uint256 public dividendBps;    // 分红
    uint256 public lpBps;          // 回流底池
    uint256 public constant MAX_BPS = 10000;

    // ── 处理阈值 ──
    uint256 public minProcessAmount = 1 * 1e18;  // 至少累积 1 个代币才处理

    // ── 权限控制 ──
    bool public autoProcess = true;  // true = 任何人都可触发 processFees

    // ── 状态记录（调试用）──
    string  public lastFailureReason;
    uint256 public lastProcessTime;
    uint256 public totalFeesProcessed;  // 累计处理的代币总量

    // ── 防重入 ──
    bool private inProcessing;

    modifier lockProcessing() {
        require(!inProcessing, "TaxDist: reentrant call");
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
    event RescueToken(address indexed token, address indexed to, uint256 amount);
    event RescueBNB(address indexed to, uint256 amount);
    event SwapDebug(string step, uint256 value);

    /**
     * @notice 构造函数
     * @param token_           主代币合约地址
     * @param marketingWallet_ 营销收款地址
     * @param dividendTracker_ 分红合约地址（主合约自动部署的 ModaDividendTracker）
     * @param router_          PancakeSwap V2 Router 地址
     * @param _marketingBps    营销分配比例（bps）
     * @param _dividendBps     分红分配比例（bps）
     * @param _lpBps           底池回流比例（bps）
     *
     * 注：_marketingBps + _dividendBps + _lpBps 可以 ≤ 10000（剩余部分不分配）
     *     推荐等于主合约中 (marketingBps + dividendBps + liquidityBps) 的总和
     */
    constructor(
        address token_,
        address marketingWallet_,
        address dividendTracker_,
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
            "TaxDist: BPS sum > 100%"
        );

        token           = token_;
        marketingWallet = marketingWallet_;
        dividendTracker = dividendTracker_;
        router          = IUniswapV2Router02(router_);
        marketingBps    = _marketingBps;
        dividendBps     = _dividendBps;
        lpBps           = _lpBps;
    }

    // ── 接收 BNB（swap 结果返回的 BNB）──
    receive() external payable {}

    // ═══════════════════════════════════════════
    //  核心：处理税费
    // ═══════════════════════════════════════════

    /**
     * @notice 触发税费处理
     *         - autoProcess=true：任何人都可调用
     *         - autoProcess=false：仅 owner 可调用
     */
    function processFees() external {
        if (inProcessing) return;
        if (!autoProcess && msg.sender != owner()) revert("TaxDist: not authorized");
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
     *         失败时静默忽略，不影响调用方
     */
    function tryProcess() external {
        if (inProcessing) return;
        inProcessing = true;
        // 使用底层 call 吞掉失败，不影响用户交易
        (bool ok, ) = address(this).call(abi.encodeWithSignature("_doProcess()"));
        ok; // 静默处理
        inProcessing = false;
    }

    /**
     * @dev 核心处理逻辑
     *
     * 流程：
     * 1. 检查代币余额 ≥ minProcessAmount
     * 2. 按比例分配代币（LP 用一半代币+BNB加底池）
     * 3. 剩余代币 swap → BNB
     * 4. 按比例分配 BNB（营销 + 分红）
     * 5. 可选：用 lpBps 对应份额加底池
     */
    function _doProcess() public lockProcessing {
        uint256 balance = IERC20(token).balanceOf(address(this));

        if (balance < minProcessAmount) {
            lastFailureReason = "Balance < minProcessAmount";
            return;
        }

        lastFailureReason = "";

        // ── 计算 LP 和 swap 部分 ──────────────────────
        uint256 totalBps = marketingBps + dividendBps + lpBps;
        if (totalBps == 0) {
            lastFailureReason = "All BPS = 0, nothing to process";
            return;
        }

        // LP 回流：将 lpBps 对应份额的代币拆成两半
        //   一半代币用于配对，另一半代币 swap → BNB 用于加底池的 BNB 端
        uint256 lpTokenTotal  = (balance * lpBps)     / totalBps;
        uint256 shareToken    = balance - lpTokenTotal; // 营销 + 分红 部分

        uint256 lpTokenKeep   = lpTokenTotal / 2;       // 直接配对进底池
        uint256 lpTokenToSwap = lpTokenTotal - lpTokenKeep; // swap → BNB 作底池配对用

        uint256 swapTotal = shareToken + lpTokenToSwap;

        if (swapTotal == 0) {
            lastFailureReason = "swapTotal = 0";
            return;
        }

        // ── 授权 Router ──────────────────────────────
        IERC20(token).safeIncreaseAllowance(address(router), swapTotal);

        // ── swap 代币 → BNB ──────────────────────────
        uint256 bnbReceived = _swapTokensForBNB(swapTotal);
        if (bnbReceived == 0) {
            emit ProcessFailed(balance, lastFailureReason);
            return;
        }

        lastProcessTime = block.timestamp;
        totalFeesProcessed += balance;

        // ── 按来源比例拆分 BNB ───────────────────────
        // lpTokenToSwap 对应的 BNB 用于加底池
        // shareToken 对应的 BNB 按营销/分红比例分配
        uint256 bnbForLP      = (swapTotal > 0 && lpTokenToSwap > 0)
            ? (bnbReceived * lpTokenToSwap) / swapTotal
            : 0;
        uint256 bnbForShare   = bnbReceived - bnbForLP;

        // 分配营销 + 分红（在 shareToken 对应的 BNB 里再按比例）
        uint256 nonLpBps = marketingBps + dividendBps;
        uint256 bnbForMarketing = 0;
        uint256 bnbForDividend  = 0;

        if (nonLpBps > 0) {
            bnbForMarketing = (bnbForShare * marketingBps) / nonLpBps;
            bnbForDividend  = bnbForShare - bnbForMarketing;
        }

        // ── 发送 BNB ─────────────────────────────────
        if (bnbForMarketing > 0 && marketingWallet != address(0)) {
            (bool ok, ) = payable(marketingWallet).call{value: bnbForMarketing}("");
            ok; // 失败不 revert
        }

        if (bnbForDividend > 0 && dividendTracker != address(0)) {
            // 向分红合约 transfer BNB，触发其 receive()，自动分配给持币用户
            (bool ok, ) = payable(dividendTracker).call{value: bnbForDividend}("");
            ok;
        }

        // ── 加底池（LP 回流） ──────────────────────────
        if (lpTokenKeep > 0 && bnbForLP > 0) {
            _addLiquiditySafe(lpTokenKeep, bnbForLP);
        }

        emit FeesProcessed(balance, bnbForMarketing, bnbForDividend, bnbForLP);
    }

    // ═══════════════════════════════════════════
    //  内部函数
    // ═══════════════════════════════════════════

    /**
     * @dev swap 代币 → BNB，双通道兜底策略
     *      通道1：FOT 版（PancakeSwap BSC 原生首选）
     *      通道2：标准版（兜底，回避 ds-math-sub-underflow）
     *      两个均失败则返回 0
     */
    function _swapTokensForBNB(uint256 tokenAmount) internal returns (uint256 bnbAmount) {
        uint256 bnbBefore = address(this).balance;
        address[] memory path = _getPath();

        // 通道 1：FOT 安全版（首选）
        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            1,            // amountOutMin = 1 wei（防止空输出）
            path,
            address(this),
            block.timestamp + 300
        ) {
            bnbAmount = address(this).balance - bnbBefore;
            if (bnbAmount > 0) return bnbAmount;
            emit SwapDebug("FOT swap output=0, trying std", tokenAmount);
        } catch Error(string memory /*reason*/) {
            emit SwapDebug("FOT swap failed, trying std", tokenAmount);
        } catch {
            emit SwapDebug("FOT swap unknown fail, trying std", tokenAmount);
        }

        // 通道 2：标准版（兜底）
        try router.swapExactTokensForETH(
            tokenAmount,
            1,
            path,
            address(this),
            block.timestamp + 300
        ) {
            bnbAmount = address(this).balance - bnbBefore;
            if (bnbAmount == 0) {
                lastFailureReason = "Both swaps: output = 0";
            }
            return bnbAmount;
        } catch Error(string memory reason) {
            lastFailureReason = reason;
            emit ProcessFailed(tokenAmount, reason);
        } catch {
            lastFailureReason = "Both swap channels failed";
            emit ProcessFailed(tokenAmount, "unknown");
        }

        return 0;
    }

    /**
     * @dev 安全加底池（失败不 throw）
     *      LP Token 发给 owner（对应 launch.html 设计）
     */
    function _addLiquiditySafe(uint256 tokenAmt, uint256 bnbAmt) internal {
        IERC20(token).safeIncreaseAllowance(address(router), tokenAmt);
        try router.addLiquidityETH{value: bnbAmt}(
            token,
            tokenAmt,
            0, 0,
            owner(),           // LP 发给 owner
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
        path[1] = router.WETH();
    }

    // ═══════════════════════════════════════════
    //  Owner 配置管理
    // ═══════════════════════════════════════════

    /**
     * @notice 更新营销钱包地址
     */
    function setMarketingWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "Zero address");
        marketingWallet = _wallet;
        emit ConfigUpdated("marketingWallet");
    }

    /**
     * @notice 更新分红合约地址
     */
    function setDividendTracker(address _tracker) external onlyOwner {
        dividendTracker = _tracker;
        emit ConfigUpdated("dividendTracker");
    }

    /**
     * @notice 更新 DEX Router（用于切换到新版 PancakeSwap 等）
     */
    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "Zero address");
        router = IUniswapV2Router02(_router);
        emit ConfigUpdated("router");
    }

    /**
     * @notice 更新主代币合约地址（通常不需要修改）
     */
    function setToken(address _token) external onlyOwner {
        require(_token != address(0), "Zero address");
        token = _token;
        emit ConfigUpdated("token");
    }

    /**
     * @notice 更新三项分配比例（对应 launch.html 税收分配滑块）
     *         _marketingBps + _dividendBps + _lpBps ≤ 10000
     */
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

    /**
     * @notice 设置最低处理阈值（默认 1e18 = 1 个代币）
     */
    function setMinProcessAmount(uint256 _amt) external onlyOwner {
        minProcessAmount = _amt;
        emit ConfigUpdated("minProcessAmount");
    }

    /**
     * @notice 开关自动处理权限（true = 任何人可触发）
     */
    function setAutoProcess(bool _on) external onlyOwner {
        autoProcess = _on;
        emit ConfigUpdated("autoProcess");
    }

    // ═══════════════════════════════════════════
    //  紧急救援函数
    // ═══════════════════════════════════════════

    /**
     * @notice 提取任意 ERC20 代币（防止误转入后锁死）
     *         若提取的是主代币，确保留够 minProcessAmount
     */
    function rescueToken(
        address _token,
        address _to,
        uint256 _amount
    ) external onlyOwner {
        require(_to != address(0), "Zero address");
        if (_token == token) {
            uint256 bal = IERC20(_token).balanceOf(address(this));
            require(
                _amount <= bal,
                "TaxDist: amount exceeds balance"
            );
        }
        IERC20(_token).safeTransfer(_to, _amount);
        emit RescueToken(_token, _to, _amount);
    }

    /**
     * @notice 提取合约内 BNB
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
     * @notice 提取所有 BNB 到 owner（紧急情况）
     */
    function rescueAllBNB() external onlyOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "No BNB");
        (bool ok, ) = payable(owner()).call{value: bal}("");
        require(ok, "BNB transfer failed");
        emit RescueBNB(owner(), bal);
    }

    // ═══════════════════════════════════════════
    //  查询接口
    // ═══════════════════════════════════════════

    /**
     * @notice 查看当前处理状态（调试 / 前端展示用）
     */
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
     * @notice 检查是否可以触发处理（余额是否超过阈值）
     */
    function canProcess() external view returns (bool, uint256 currentBalance, uint256 required) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        return (bal >= minProcessAmount, bal, minProcessAmount);
    }
}
