// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IAsBnbMinter
/// @notice Interface for AsterDEX asBNB minter (from source at 0x7F52773065Fd350b5a935CE2B293FdB16551A6FC)
interface IAsBnbMinter {
    function mintAsBnb(uint256 amount) external returns (uint256);
    function mintAsBnb() external payable returns (uint256);
    function burnAsBnb(uint256 amountToBurn) external returns (uint256);
    function convertToTokens(uint256 asBNBAmount) external view returns (uint256);
    function convertToAsBnb(uint256 tokenAmount) external view returns (uint256);
    function compoundRewards(uint256 _amountIn) external;
    function totalTokens() external view returns (uint256);
    function minMintAmount() external view returns (uint256);
    function canDeposit() external view returns (bool);
    function canWithdraw() external view returns (bool);
}

/// @title IYieldProxy
/// @notice Interface for AsterDEX YieldProxy (from source at 0x66C66DBB51cbccE0fbb2738326e11Da6FE9e584C)
interface IYieldProxy {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function activitiesOnGoing() external view returns (bool);
    function stakeManager() external view returns (address);
    function token() external view returns (IERC20);
    function asBnb() external view returns (address);
}

/// @title IListaStakeManager
/// @notice Interface for Lista BNB staking
interface IListaStakeManager {
    function deposit() external payable;
    function convertBnbToSnBnb(uint256 amount) external view returns (uint256);
    function convertSnBnbToBnb(uint256 amount) external view returns (uint256);
}

/// @title IPancakeRouter
/// @notice Interface for PancakeSwap Router V2
interface IPancakeRouter {
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}

/// @title AsterHedgeAdapter
/// @notice Adapter for hedging using AsterDEX asBNB + yield chasing across stables
/// @dev Provides BNB exposure as a hedge against USD weakness
///      When USD stablecoins depeg downward, BNB typically rises
///      This creates a natural hedge while still earning yield from LaunchPools
///
/// Strategy (volatility-triggered):
///   NORMAL mode   → 70% asUSDF + 20% asBNB + 10% buffer
///   VOLATILE mode → 40% asUSDF + 40% asBNB + 20% buffer
///   DRAWDOWN mode → 20% asUSDF + 50% asBNB + 30% buffer
contract AsterHedgeAdapter {
    using SafeERC20 for IERC20;

    // ─── Constants ───────────────────────────────────────────────────────────

    // AsterDEX asBNB contracts (BSC Mainnet - verified addresses)
    address public constant ASBNB = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6;
    address public constant ASBNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8; // Proxy address
    address public constant YIELD_PROXY = 0x66C66DBB51cbccE0fbb2738326e11Da6FE9e584C;

    // Lista Protocol (for BNB → slisBNB)
    address public constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;

    // Stablecoins
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    // PancakeSwap Router
    address public constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    uint256 public constant DENOMINATOR = 10_000;

    // ─── Enums ───────────────────────────────────────────────────────────────

    enum ActionType {
        OPEN_HEDGE,      // Convert USDT → BNB → asBNB
        CLOSE_HEDGE,     // Convert asBNB → slisBNB → BNB → USDT
        REBALANCE,       // Adjust hedge ratio
        COMPOUND         // Compound LaunchPool rewards
    }

    // ─── Structs ─────────────────────────────────────────────────────────────

    struct HedgeParams {
        ActionType actionType;
        uint256 amount;           // Amount in (USDT for open, asBNB for close)
        uint256 minReceived;      // Minimum output (slippage protection)
        uint256 targetHedgeBps;   // Target hedge ratio (e.g., 2000 = 20%)
        address recipient;
    }

    struct HedgeResult {
        uint256 amountIn;
        uint256 amountOut;
        uint256 hedgeValue;       // Current hedge position value in USDT
        uint256 hedgeRatioBps;    // Current hedge ratio
    }

    // ─── Events ──────────────────────────────────────────────────────────────

    event HedgeOpened(uint256 usdtIn, uint256 asBnbOut, address indexed recipient);
    event HedgeClosed(uint256 asBnbIn, uint256 usdtOut, address indexed recipient);
    event HedgeRebalanced(uint256 oldRatio, uint256 newRatio);

    // ─── Core Functions ──────────────────────────────────────────────────────

    /// @notice Execute a hedge operation
    function execute(address vault, bytes calldata params)
        external
        returns (bool success, bytes memory result)
    {
        HedgeParams memory p = abi.decode(params, (HedgeParams));
        HedgeResult memory res;

        if (p.actionType == ActionType.OPEN_HEDGE) {
            res = _openHedge(p);
        } else if (p.actionType == ActionType.CLOSE_HEDGE) {
            res = _closeHedge(p);
        } else if (p.actionType == ActionType.REBALANCE) {
            res = _rebalance(p, vault);
        }

        return (true, abi.encode(res));
    }

    // ─── Internal: Open Hedge ────────────────────────────────────────────────

    /// @notice Convert USDT → BNB → asBNB (using native BNB mint)
    function _openHedge(HedgeParams memory p) internal returns (HedgeResult memory res) {
        require(p.amount > 0, "Amount must be > 0");
        require(p.recipient != address(0), "Invalid recipient");

        // Step 1: Swap USDT → BNB via PancakeSwap
        uint256 bnbReceived = _swapUsdtToBnb(p.amount, 0);

        // Step 2: Mint asBNB directly with BNB (payable function)
        uint256 asBnbReceived = IAsBnbMinter(ASBNB_MINTER).mintAsBnb{value: bnbReceived}();

        // Transfer asBNB to recipient
        if (asBnbReceived > 0) {
            IERC20(ASBNB).safeTransfer(p.recipient, asBnbReceived);
        }

        res.amountIn = p.amount;
        res.amountOut = asBnbReceived;
        res.hedgeValue = _getHedgeValueInUsdt(asBnbReceived);

        emit HedgeOpened(p.amount, asBnbReceived, p.recipient);
    }

    // ─── Internal: Close Hedge ───────────────────────────────────────────────

    /// @notice Convert asBNB → slisBNB → BNB → USDT
    function _closeHedge(HedgeParams memory p) internal returns (HedgeResult memory res) {
        require(p.amount > 0, "Amount must be > 0");
        require(p.recipient != address(0), "Invalid recipient");

        // Step 1: Burn asBNB → slisBNB
        // Note: burnAsBnb transfers slisBNB directly to this contract and returns asBNB amount burned
        uint256 slisBnbBefore = IERC20(SLISBNB).balanceOf(address(this));
        IERC20(ASBNB).forceApprove(ASBNB_MINTER, p.amount);
        IAsBnbMinter(ASBNB_MINTER).burnAsBnb(p.amount);
        uint256 slisBnbAfter = IERC20(SLISBNB).balanceOf(address(this));
        uint256 slisBnbReceived = slisBnbAfter - slisBnbBefore;

        // Step 2: Swap slisBNB → BNB via PancakeSwap
        uint256 bnbReceived = _swapSlisBnbToBnb(slisBnbReceived);

        // Step 3: Swap BNB → USDT
        uint256 usdtReceived = _swapBnbToUsdt(bnbReceived, p.minReceived);

        // Transfer USDT to recipient
        IERC20(USDT).safeTransfer(p.recipient, usdtReceived);

        res.amountIn = p.amount;
        res.amountOut = usdtReceived;

        emit HedgeClosed(p.amount, usdtReceived, p.recipient);
    }

    // ─── Internal: Rebalance ─────────────────────────────────────────────────

    /// @notice Rebalance hedge to target ratio
    function _rebalance(HedgeParams memory p, address vault) internal returns (HedgeResult memory res) {
        uint256 currentHedge = IERC20(ASBNB).balanceOf(vault);
        uint256 currentHedgeValue = _getHedgeValueInUsdt(currentHedge);

        uint256 totalValue = p.amount; // Total portfolio value passed in
        uint256 currentRatioBps = totalValue > 0 ? (currentHedgeValue * DENOMINATOR) / totalValue : 0;

        uint256 targetValue = (totalValue * p.targetHedgeBps) / DENOMINATOR;

        if (targetValue > currentHedgeValue + 100e18) { // Only rebalance if difference > $100
            // Need more hedge - open additional
            uint256 needed = targetValue - currentHedgeValue;
            HedgeParams memory openParams = HedgeParams({
                actionType: ActionType.OPEN_HEDGE,
                amount: needed,
                minReceived: 0,
                targetHedgeBps: p.targetHedgeBps,
                recipient: vault
            });
            res = _openHedge(openParams);
        } else if (currentHedgeValue > targetValue + 100e18) {
            // Too much hedge - close some
            uint256 excess = currentHedgeValue - targetValue;
            uint256 asBnbToClose = (currentHedge * excess) / currentHedgeValue;
            HedgeParams memory closeParams = HedgeParams({
                actionType: ActionType.CLOSE_HEDGE,
                amount: asBnbToClose,
                minReceived: 0,
                targetHedgeBps: p.targetHedgeBps,
                recipient: vault
            });
            res = _closeHedge(closeParams);
        }

        res.hedgeRatioBps = p.targetHedgeBps;
        emit HedgeRebalanced(currentRatioBps, p.targetHedgeBps);
    }

    // ─── Internal Helpers ────────────────────────────────────────────────────

    function _swapUsdtToBnb(uint256 usdtAmount, uint256 minBnb) internal returns (uint256) {
        // Direct swap: USDT → WBNB (most liquid pair on BSC)
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = WBNB;

        IERC20(USDT).forceApprove(PANCAKE_ROUTER, usdtAmount);

        uint256[] memory amounts = IPancakeRouter(PANCAKE_ROUTER).swapExactTokensForETH(
            usdtAmount,
            minBnb,
            path,
            address(this),
            block.timestamp + 300
        );

        return amounts[amounts.length - 1];
    }

    function _swapBnbToUsdt(uint256 bnbAmount, uint256 minUsdt) internal returns (uint256) {
        // Direct swap: WBNB → USDT (most liquid pair on BSC)
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = USDT;

        uint256[] memory amounts = IPancakeRouter(PANCAKE_ROUTER).swapExactETHForTokens{value: bnbAmount}(
            minUsdt,
            path,
            address(this),
            block.timestamp + 300
        );

        return amounts[amounts.length - 1];
    }

    function _swapSlisBnbToBnb(uint256 slisBnbAmount) internal returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = SLISBNB;
        path[1] = WBNB;

        IERC20(SLISBNB).forceApprove(PANCAKE_ROUTER, slisBnbAmount);

        uint256[] memory amounts = IPancakeRouter(PANCAKE_ROUTER).swapExactTokensForETH(
            slisBnbAmount,
            0, // minBnb (accept any amount for now)
            path,
            address(this),
            block.timestamp + 300
        );

        return amounts[amounts.length - 1];
    }

    // ─── View Functions ──────────────────────────────────────────────────────

    /// @notice Get current hedge value in USDT
    function _getHedgeValueInUsdt(uint256 asBnbAmount) internal view returns (uint256) {
        if (asBnbAmount == 0) return 0;

        // asBNB → slisBNB value
        uint256 slisBnbValue;
        try IAsBnbMinter(ASBNB_MINTER).convertToTokens(asBnbAmount) returns (uint256 val) {
            slisBnbValue = val;
        } catch {
            slisBnbValue = asBnbAmount; // 1:1 fallback
        }

        // slisBNB → USDT value via router quote
        return _getSlisBnbValueInUsdt(slisBnbValue);
    }

    function _getSlisBnbValueInUsdt(uint256 slisBnbAmount) internal view returns (uint256) {
        if (slisBnbAmount == 0) return 0;

        // Direct path: slisBNB → WBNB → USDT using best liquidity
        // slisBNB is approximately 1:1 with BNB, so we can estimate via BNB → USDT
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = USDT;

        // Assume slisBNB ≈ WBNB (Lista liquid staking maintains ~1:1 peg)
        // Get WBNB → USDT price and apply to slisBNB amount
        try IPancakeRouter(PANCAKE_ROUTER).getAmountsOut(slisBnbAmount, path) returns (uint256[] memory amounts) {
            return amounts[amounts.length - 1];
        } catch {
            return 0;
        }
    }

    /// @notice Get hedge position value for a wallet
    function getHedgeValue(address wallet) external view returns (uint256) {
        uint256 asBnbBalance = IERC20(ASBNB).balanceOf(wallet);
        return _getHedgeValueInUsdt(asBnbBalance);
    }

    /// @notice Get asBNB exchange rate (asBNB → slisBNB)
    function getAsBnbRate() external view returns (uint256) {
        return IAsBnbMinter(ASBNB_MINTER).convertToTokens(1e18);
    }

    /// @notice Check if LaunchPool activities are ongoing
    function hasActiveActivities() external view returns (bool) {
        return IYieldProxy(YIELD_PROXY).activitiesOnGoing();
    }

    /// @notice Check if deposits are enabled
    function canDeposit() external view returns (bool) {
        return IAsBnbMinter(ASBNB_MINTER).canDeposit();
    }

    /// @notice Check if withdrawals are enabled
    function canWithdraw() external view returns (bool) {
        return IAsBnbMinter(ASBNB_MINTER).canWithdraw();
    }

    /// @notice Get target hedge BPS based on volatility mode
    function getTargetHedgeBps(uint8 mode) external pure returns (uint256) {
        if (mode == 0) return 2000;  // NORMAL: 20% hedge
        if (mode == 1) return 4000;  // VOLATILE: 40% hedge
        if (mode == 2) return 5000;  // DRAWDOWN: 50% hedge
        return 2000;
    }

    // Allow receiving BNB
    receive() external payable {}
}
