// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ── Interfaces (inline, no external deps) ──
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
     * @dev 标准 swap（不含 FOT 支持），用于无转账税的代币。
     *      内部使用 _swap()，直接基于 reserves 计算，不调用 pair.balanceOf().sub(reserve)
     *      因此避免了 ds-math-sub-underflow 等边界情况。
     */
    function swapExactTokensForETH(
        uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external returns (uint[] memory amounts);
    /**
     * @dev FOT 安全 swap（内部用 _swapSupportingFeeOnTransferTokens ，
     *      会调用 pair.balanceOf().sub(reserve) 来计算实际接收量）。
     *      仅当 TaxDistributor 有转账税时需要，否则用 swapExactTokensForETH 更稳定。
     */
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external returns (uint[] memory amounts);
    function addLiquidityETH(
        address token, uint amountTokenDesired, uint amountTokenMin, uint amountETHMin,
        address to, uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

// ── Ownable ──
abstract contract Ownable {
    address internal _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor(address owner_) {
        address initOwner = owner_ == address(0) ? msg.sender : owner_;
        _owner = initOwner;
        emit OwnershipTransferred(address(0), initOwner);
    }
    function owner() public view virtual returns (address) { return _owner; }
    modifier onlyOwner() { require(owner() == msg.sender, "Ownable: not owner"); _; }
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

// ── SafeERC20 (minimal) ──
library SafeERC20 {
    bytes4 private constant SIG_TRANSFER   = bytes4(keccak256("transfer(address,uint256)"));
    bytes4 private constant SIG_APPROVE    = bytes4(keccak256("approve(address,uint256)"));
    bytes4 private constant SIG_ALLOWANCE  = bytes4(keccak256("allowance(address,address)"));

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
     * @dev 安全设置授权额度，兼容 USDT 等"必须先置0再设新值"的代币。
     *      策略：1) 先检查当前授权是否足够；2) 尝试直接设新值；3) 若失败，先置0再设新值。
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 newAllowance) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current >= newAllowance) return;

        (bool ok, bytes memory d) = address(token).call(
            abi.encodeWithSelector(SIG_APPROVE, spender, newAllowance)
        );
        if (ok && (d.length == 0 || abi.decode(d, (bool)))) return;

        (ok, d) = address(token).call(
            abi.encodeWithSelector(SIG_APPROVE, spender, 0)
        );
        require(ok && (d.length == 0 || abi.decode(d, (bool))), "SafeERC20: approve reset failed");

        (ok, d) = address(token).call(
            abi.encodeWithSelector(SIG_APPROVE, spender, newAllowance)
        );
        require(ok && (d.length == 0 || abi.decode(d, (bool))), "SafeERC20: approve failed");
    }
}

/**
 * @title TaxDistributor
 * @dev 独立税费处理合约，负责：
 *   - 接收主合约转来的税费代币
 *   - swap 代币 → BNB
 *   - 分配 BNB 给营销钱包 / 分红合约
 *   - 可选：用部分代币+BNB 加流动性（LP 发给 owner）
 *
 * 主合约只负责交易和收税，把税费代币 transfer 给本合约，
 * 本合约异步处理，用户的交易永远不会因 swap 失败而 revert。
 */
contract TaxDistributor is Ownable {
    using SafeERC20 for IERC20;

    // ── 配置 ──────────────────────────────────────
    address public token;           // 主代币合约
    address public marketingWallet;
    address public dividendTracker;
    IUniswapV2Router02 public router;
    bool    public autoProcess = true;   // 是否允许任何人触发 processFees

    // ── 阈值 ──────────────────────────────────────
    uint256 public minProcessAmount = 1 * 1e18;  // 至少累积多少代币才处理

    // ── 分配比例（basis points, 10000 = 100%） ─
    uint256 public marketingBps = 5000;  // 50% → 营销
    uint256 public dividendBps  = 5000;  // 50% → 分红
    uint256 public lpBps         = 0;     // 0%  → 不加 LP（可按需开启）
    uint256 public constant MAX_BPS = 10000;

    // ── 调试 ──────────────────────────────
    string  public lastFailureReason;
    uint256 public lastProcessTime;

    // ── 防重入 ────────────────────────────────────
    bool private inProcessing;
    modifier lockProcessing() { inProcessing = true; _; inProcessing = false; }

    // ── 事件 ──────────────────────────────────────
    event FeesProcessed(uint256 tokenAmt, uint256 bnbToMarketing, uint256 bnbToDividend);
    event ProcessFailed(uint256 tokenAmt, string reason);
    event ConfigUpdated(string key, uint256 value);
    event RescueToken(address token, uint256 amount);
    event Debug(string step, uint256 val1, uint256 val2);

    constructor(
        address token_,
        address marketingWallet_,
        address dividendTracker_,
        address router_,
        uint256 _marketingBps,
        uint256 _dividendBps,
        uint256 _lpBps
    ) payable Ownable(address(0)) {
        require(_marketingBps + _dividendBps + _lpBps <= MAX_BPS, "TaxDist: BPS overflow");
        token           = token_;
        marketingWallet = marketingWallet_;
        dividendTracker = dividendTracker_;
        router          = IUniswapV2Router02(router_);
        marketingBps = _marketingBps;
        dividendBps  = _dividendBps;
        lpBps        = _lpBps;
    }

    // ── 接收 BNB（来自 swap） ───────────────────
    receive() external payable {}

    // ═══════════════════════════════════════════
    // 核心：处理税费
    // ═══════════════════════════════════════════

    /**
     * @dev 任何人都可以调用（如果 autoProcess = true），
     *      或仅 owner 调用。
     *      把合约内累积的代币 swap 成 BNB 并分配。
     */
    function processFees() external {
        if (inProcessing) return;
        if (!autoProcess && msg.sender != owner()) revert("Not authorized");
        doProcess();
    }

    /**
     * @dev owner 强制处理（忽略 autoProcess 开关）
     */
    function forceProcess() external onlyOwner {
        doProcess();
    }

    /**
     * @dev 安全触发 —— 永不 revert。
     *      供主合约 _handleTax 自动调用，也供任何人手动触发。
     *      如果 swap 失败，错误被静默吞掉，不会影响用户交易。
     *
     *      使用外部 self-call 来实现 try/catch（Solidity 不支持内部 try/catch）。
     *      因为 doProcess() 现在是扁平的，外部调用开销可控。
     */
    function tryProcess() external {
        if (inProcessing) return;
        // 使用底层 call 代替 try/catch，减少编译器生成的重入哨兵开销
        inProcessing = true;
        (bool ok, ) = address(this).call(abi.encodeWithSignature("doProcess()"));
        ok; // 静默吞掉失败
        inProcessing = false;
    }

    /**
     * @dev 核心处理逻辑 —— 扁平化设计，避免嵌套 try/catch 导致 viaIR 重入哨兵 gas 爆炸。
     *
     *      流程：
     *      1. 检查余额是否超过阈值
     *      2. 计算 swap 和 LP 配比
     *      3. 授权 router
     *      4. swap → BNB（内部函数，带 try/catch）
     *      5. 按比例分配 BNB（纯数学，无外部调用风险）
     *      6. 可选：加 LP
     */
    function doProcess() public lockProcessing {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < minProcessAmount) {
            lastFailureReason = "Balance < minProcessAmount";
            return;
        }

        lastFailureReason = "";

        // ── 计算各部分数量 ────────────────────────
        uint256 lpTokenAmt   = (balance * lpBps) / MAX_BPS;
        uint256 shareTokenAmt = balance - lpTokenAmt;

        uint256 lpKeepToken = lpTokenAmt / 2;
        uint256 lpSwapAmt   = lpTokenAmt - lpKeepToken;

        uint256 swapTotal = shareTokenAmt + lpSwapAmt;

        if (swapTotal == 0) {
            lastFailureReason = "LP amount too small to add liquidity";
            return;
        }

        // ── Approve router ──────────────────────
        IERC20(token).safeIncreaseAllowance(address(router), swapTotal);

        // ── Swap → BNB（单独函数） ─────────────────
        uint256 bnbReceived = _swapTokensForBNB(swapTotal);
        if (bnbReceived == 0) {
            // _swapTokensForBNB 内部已经设置了 lastFailureReason
            emit ProcessFailed(balance, lastFailureReason);
            return;
        }

        lastProcessTime = block.timestamp;

        // ══════════════════════════════════════
        // 分配 BNB（纯计算 + 简单转账，不易出错）
        // ══════════════════════════════════════

        // 按 swap 比例拆分 BNB
        uint256 bnbFromLpSwap = (bnbReceived * lpSwapAmt) / swapTotal;
        uint256 bnbFromShare   = bnbReceived - bnbFromLpSwap;

        // 分配营销+分红 BNB
        uint256 nonLpBps = MAX_BPS - lpBps;
        uint256 bnbForMarketing = 0;
        uint256 bnbForDividend  = 0;

        if (nonLpBps > 0) {
            bnbForMarketing = (bnbFromShare * marketingBps) / nonLpBps;
            bnbForDividend  = bnbFromShare - bnbForMarketing;
        }

        // 转账（发送失败不 revert）
        if (bnbForMarketing > 0 && marketingWallet != address(0)) {
            (bool ok, ) = payable(marketingWallet).call{value: bnbForMarketing}("");
            ok;
        }
        if (bnbForDividend > 0 && dividendTracker != address(0)) {
            (bool ok, ) = payable(dividendTracker).call{value: bnbForDividend}("");
            ok;
        }

        // ── 加 LP ──────────────────────────
        if (lpKeepToken > 0 && bnbFromLpSwap > 0) {
            _addLiquiditySafe(lpKeepToken, bnbFromLpSwap);
        }

        emit FeesProcessed(balance, bnbForMarketing, bnbForDividend);
    }

    /**
     * @dev 执行 token → BNB swap，内部处理失败（不 throw）。
     *
     *      双通道兜底策略：
     *      ┌──────────────────────────────────────────┐
     *      │ 1. 先试 swapExactTokensForETHSupporting-  │
     *      │    FeeOnTransferTokens (FOT 版)          │
     *      │    → PancakeSwap BSC 核心函数，兼容性最佳  │
     *      │                                          │
     *      │ 2. 如果 FOT 版失败，fallback 到           │
     *      │    swapExactTokensForETH (标准版)         │
     *      │    → 回避 .sub(reserve) underflow 问题    │
     *      │                                          │
     *      │ 两个都失败 → lastFailureReason 记录原因    │
     *      └──────────────────────────────────────────┘
     *
     * @param tokenAmount 要 swap 的代币数量
     * @return bnbAmount swap 得到的 BNB 数量，失败返回 0
     */
    function _swapTokensForBNB(uint256 tokenAmount) internal returns (uint256 bnbAmount) {
        uint256 bnbBefore = address(this).balance;

        // ═══ 通道 1：FOT 版（首选，PancakeSwap BSC 原生支持）═══
        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            1,               // amountOutMin = 1 wei
            _getPath(),
            address(this),
            block.timestamp + 300
        ) {
            bnbAmount = address(this).balance - bnbBefore;
            if (bnbAmount > 0) return bnbAmount;
            // bnbAmount == 0，不记录失败，让标准版有机会
            emit Debug("FOT swap=0,trying std", tokenAmount, 0);
        } catch Error(string memory /*reason*/) {
            // FOT 版失败（如 ds-math-sub-underflow），
            // 不记录为最终失败，尝试标准版兜底
            emit Debug("FOT failed,trying std", tokenAmount, 0);
        } catch {
            emit Debug("FOT unknown,trying std", tokenAmount, 0);
        }

        // ═══ 通道 2：标准版（兜底）═══
        try router.swapExactTokensForETH(
            tokenAmount,
            1,
            _getPath(),
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
        } catch {
            lastFailureReason = "Both swaps failed";
        }
    }

    /**
     * @dev 安全加 LP（内部 try/catch，失败不 throw）
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
            emit Debug("lpAddSuccess", tokenAmt, bnbAmt);
        } catch Error(string memory err) {
            lastFailureReason = string(abi.encodePacked("LP: ", err));
            emit Debug("lpAddFail", tokenAmt, bnbAmt);
        } catch {
            lastFailureReason = "LP add failed (unknown)";
            emit Debug("lpAddFail", tokenAmt, bnbAmt);
        }
    }

    function _getPath() internal view returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = router.WETH();
        return path;
    }

    // ═══════════════════════════════════════════
    // Owner 配置
    // ═══════════════════════════════════════════

    function setMarketingWallet(address _wallet) external onlyOwner {
        marketingWallet = _wallet;
        emit ConfigUpdated("marketingWallet", 0);
    }

    function setDividendTracker(address _tracker) external onlyOwner {
        dividendTracker = _tracker;
        emit ConfigUpdated("dividendTracker", 0);
    }

    function setRouter(address _router) external onlyOwner {
        router = IUniswapV2Router02(_router);
        emit ConfigUpdated("router", 0);
    }

    function setToken(address _token) external onlyOwner {
        token = _token;
        emit ConfigUpdated("token", 0);
    }

    function setBps(uint256 _marketingBps, uint256 _dividendBps, uint256 _lpBps) external onlyOwner {
        require(_marketingBps + _dividendBps + _lpBps <= MAX_BPS, "BPS overflow");
        marketingBps = _marketingBps;
        dividendBps  = _dividendBps;
        lpBps         = _lpBps;
    }

    function setMinProcessAmount(uint256 _amt) external onlyOwner {
        minProcessAmount = _amt;
    }

    function setAutoProcess(bool _on) external onlyOwner {
        autoProcess = _on;
    }

    // ═══════════════════════════════════════════
    // 救援函数（防止代币卡死）
    // ═══════════════════════════════════════════

    /**
     * @dev 提取任意 ERC20 代币到指定钱包（包括本币、LP 等）
     *      防止代币意外转入后无法取出。
     * @param _token  代币地址
     * @param _to     接收地址
     * @param _amount 提取数量
     */
    function rescueToken(address _token, address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Zero address");
        if (_token == token) {
            uint256 needed = minProcessAmount;
            uint256 bal = IERC20(_token).balanceOf(address(this));
            require(_amount <= bal - needed, "Cannot rescue pending fees");
        }
        IERC20(_token).safeTransfer(_to, _amount);
        emit RescueToken(_token, _amount);
    }

    /**
     * @dev 提取合约内任意数量 BNB 到指定钱包
     * @param _to     接收地址
     * @param _amount 提取数量
     */
    function rescueBNB(address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Zero address");
        require(_amount > 0 && _amount <= address(this).balance, "Invalid amount");
        (bool ok, ) = payable(_to).call{value: _amount}("");
        require(ok, "BNB transfer failed");
    }

    /**
     * @dev 提取 LP 代币到指定钱包
     * @param _pair   LP Token 地址
     * @param _to     接收地址
     * @param _amount 提取数量
     */
    function rescueLP(address _pair, address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Zero address");
        IERC20(_pair).safeTransfer(_to, _amount);
    }

    /**
     * @dev 强制撤除 LP
     */
    function emergencyRemoveLP(address _pair, uint256 _amount) external onlyOwner {
        IERC20(_pair).safeApprove(router.factory(), _amount);
        (bool ok, ) = address(router).call(
            abi.encodeWithSignature(
                "removeLiquidityETHSupportingFeeOnTransferTokens(address,uint256,uint256,uint256,address,uint256)",
                token, _amount, 0, 0, owner(), block.timestamp
            )
        );
        require(ok, "Remove LP failed");
    }

    /**
     * @dev 查看合约当前状态（调试用）
     */
    function getStatus() external view returns (
        address token_,
        uint256 balance_,
        uint256 minProcessAmount_,
        uint256 marketingBps_,
        uint256 dividendBps_,
        uint256 lpBps_,
        string memory lastFailure_,
        uint256 lastProcessTime_,
        bool autoProcess_
    ) {
        return (
            token,
            IERC20(token).balanceOf(address(this)),
            minProcessAmount,
            marketingBps,
            dividendBps,
            lpBps,
            lastFailureReason,
            lastProcessTime,
            autoProcess
        );
    }
}
