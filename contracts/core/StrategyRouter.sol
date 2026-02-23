// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../libraries/VaultMath.sol";
import "../libraries/VolatilityLib.sol";
import "../adapters/AsterDEXEarnAdapter.sol";
import "../adapters/PancakeSwapV2LPAdapter.sol";
import "../adapters/PancakeSwapFarmAdapter.sol";

/// @title StrategyRouter
/// @notice Routes capital between AsterDEX Earn and PancakeSwap LP based on on-chain volatility
/// @dev No admin keys. Callable only by EngineCore (immutable reference).
///      Allocation is fully deterministic based on USDF/USDT price deviation.
contract StrategyRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using VolatilityLib for uint256;

    // ─── Constants ───────────────────────────────────────────────────────────
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant USDF = 0x5A110fC00474038f6c02E89C707D638602EA44B5;
    address public constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address public constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    // Use BUSD/USDT as proxy for stablecoin volatility detection (both are pegged to USD)
    address public constant USDF_USDT_PAIR = 0x7EFaEf62fDdCCa950418312c6C91Aef321375A00; // BUSD/USDT PancakeSwap V2
    address public constant CAKE_WBNB_PAIR = 0x0eD7e52944161450477ee417DE9Cd3a859b14fD0;
    address public constant MASTERCHEF_V2 = 0xa5f8C5Dbd5F286960b9d90548680aE5ebFf07652;
    address public constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    uint256 public constant BUFFER_BPS = 1000; // Always keep 10% buffer
    uint256 public constant DRIFT_THRESHOLD_BPS = 200; // 2% drift triggers rebalance

    // ─── Immutables ──────────────────────────────────────────────────────────
    address public immutable engineCore;
    AsterDEXEarnAdapter public immutable earnAdapter;
    PancakeSwapV2LPAdapter public immutable lpAdapter;
    PancakeSwapFarmAdapter public immutable farmAdapter;

    // ─── State ───────────────────────────────────────────────────────────────
    uint256 public lastPriceSnapshot;
    uint256 public lastSnapshotTime;
    VolatilityLib.MarketMode public currentMode;
    uint256 public earnAllocationBps;
    uint256 public lpAllocationBps;

    // ─── Events ──────────────────────────────────────────────────────────────
    event Rebalanced(
        VolatilityLib.MarketMode mode,
        uint256 earnBps,
        uint256 lpBps,
        uint256 deviationBps,
        uint256 timestamp
    );
    event CapitalDeployed(uint256 earnAmount, uint256 lpAmount);
    event Withdrawn(uint256 amount, address recipient);

    // ─── Constructor ─────────────────────────────────────────────────────────
    constructor(
        address _engineCore,
        address _earnAdapter,
        address _lpAdapter,
        address _farmAdapter
    ) {
        require(_engineCore != address(0), "SR: zero engine");
        require(_earnAdapter != address(0), "SR: zero earn");
        require(_lpAdapter != address(0), "SR: zero lp");
        require(_farmAdapter != address(0), "SR: zero farm");

        engineCore = _engineCore;
        earnAdapter = AsterDEXEarnAdapter(payable(_earnAdapter));
        lpAdapter = PancakeSwapV2LPAdapter(payable(_lpAdapter));
        farmAdapter = PancakeSwapFarmAdapter(payable(_farmAdapter));

        // Initialize with NORMAL mode
        currentMode = VolatilityLib.MarketMode.NORMAL;
        earnAllocationBps = VolatilityLib.NORMAL_EARN_BPS;
        lpAllocationBps = 10_000 - VolatilityLib.NORMAL_EARN_BPS - BUFFER_BPS;

        // Set initial price snapshot to 1.0 (will update on first rebalance)
        lastPriceSnapshot = 1e18;
        lastSnapshotTime = block.timestamp;
    }

    modifier onlyEngine() {
        require(msg.sender == engineCore, "SR: only engine");
        _;
    }

    // ─── Core Logic ──────────────────────────────────────────────────────────

    /// @notice Evaluate on-chain volatility and rebalance if needed
    /// @dev Called by EngineCore.executeCycle(). Fully deterministic.
    function rebalance() external onlyEngine nonReentrant {
        uint256 currentPrice = VolatilityLib.getSpotPrice(USDF_USDT_PAIR);
        uint256 deviationBps = VolatilityLib.priceDeviation(currentPrice, lastPriceSnapshot);

        VolatilityLib.MarketMode newMode = VolatilityLib.getMarketMode(deviationBps);
        uint256 targetEarnBps = VolatilityLib.getEarnAllocation(newMode);

        bool modeChanged = newMode != currentMode;
        bool driftExceeded = VolatilityLib.isRebalanceNeeded(
            earnAllocationBps,
            targetEarnBps,
            DRIFT_THRESHOLD_BPS
        );

        if (modeChanged || driftExceeded) {
            _executeRebalance(targetEarnBps, newMode);
        }

        // Update price snapshot
        lastPriceSnapshot = currentPrice;
        lastSnapshotTime = block.timestamp;

        emit Rebalanced(newMode, earnAllocationBps, lpAllocationBps, deviationBps, block.timestamp);
    }

    /// @notice Deploy fresh capital according to current allocation
    /// @dev Called by EngineCore after deposits
    function deployCapital() external onlyEngine nonReentrant {
        uint256 totalCapital = IERC20(USDT).balanceOf(address(this));
        if (totalCapital == 0) return;

        // Reserve buffer
        uint256 bufferAmount = (totalCapital * BUFFER_BPS) / 10_000;
        uint256 deployable = totalCapital - bufferAmount;

        (uint256 earnAmount, uint256 lpAmount) = VaultMath.calcAllocation(
            deployable,
            earnAllocationBps
        );

        // Deploy to AsterDEX Earn (two-step: USDT → USDF → asUSDF)
        // Following MetaYieldVault pattern: don't revert on adapter failures
        if (earnAmount > 0) {
            IERC20(USDT).safeTransfer(address(earnAdapter), earnAmount);
            bytes memory usdfParams = abi.encode(
                uint8(0),      // ActionType.DEPOSIT
                uint8(0),      // Asset.USDF (USDT → USDF)
                earnAmount,    // amount
                uint256(0),    // mintRatio
                uint256(0),    // minReceived
                uint256(0),    // requestId
                address(this)  // recipient
            );

            try earnAdapter.execute(address(this), usdfParams) returns (bool step1Ok, bytes memory) {
                if (step1Ok) {
                    // Step 2: USDF → asUSDF
                    uint256 usdfBalance = IERC20(USDF).balanceOf(address(this));
                    if (usdfBalance > 0) {
                        IERC20(USDF).safeTransfer(address(earnAdapter), usdfBalance);
                        bytes memory asUsdfParams = abi.encode(
                            uint8(0),      // ActionType.DEPOSIT
                            uint8(2),      // Asset.ASUSDF (USDF → asUSDF)
                            usdfBalance,   // amount
                            uint256(0),    // mintRatio
                            uint256(0),    // minReceived
                            uint256(0),    // requestId
                            address(this)  // recipient
                        );
                        try earnAdapter.execute(address(this), asUsdfParams) {} catch {}
                    }
                }
            } catch {}
        }

        // Deploy to PancakeSwap LP (only if not in DRAWDOWN mode)
        if (lpAmount > 0 && currentMode != VolatilityLib.MarketMode.DRAWDOWN) {
            _deployToLP(lpAmount);
        }

        emit CapitalDeployed(earnAmount, lpAmount);
    }

    /// @notice Withdraw assets from strategies
    /// @dev Called by MetaVault on user redemptions
    function withdrawAssets(uint256 amount, address recipient) external nonReentrant {
        require(msg.sender == engineCore || _isVault(msg.sender), "SR: unauthorized");

        // Try buffer first
        uint256 bufferBalance = IERC20(USDT).balanceOf(address(this));
        if (bufferBalance >= amount) {
            IERC20(USDT).safeTransfer(recipient, amount);
            emit Withdrawn(amount, recipient);
            return;
        }

        // Withdraw from Earn if needed
        uint256 needed = amount - bufferBalance;
        _withdrawFromEarn(needed);

        IERC20(USDT).safeTransfer(recipient, amount);
        emit Withdrawn(amount, recipient);
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    function _executeRebalance(uint256 targetEarnBps, VolatilityLib.MarketMode newMode) internal {
        // If moving to DRAWDOWN: exit all LP
        if (newMode == VolatilityLib.MarketMode.DRAWDOWN && currentMode != VolatilityLib.MarketMode.DRAWDOWN) {
            _exitAllLP();
        }

        currentMode = newMode;
        earnAllocationBps = targetEarnBps;
        lpAllocationBps = 10_000 - targetEarnBps - BUFFER_BPS;
    }

    function _deployToLP(uint256 amount) internal {
        // Add liquidity via LP adapter
        IERC20(USDT).forceApprove(address(lpAdapter), amount);

        bytes memory lpParams = abi.encode(
            0, // ADD_LIQUIDITY
            USDT,
            address(0), // tokenB (adapter will derive WBNB)
            amount,
            0,
            0,
            0,
            0,
            50, // 0.5% slippage
            address(this)
        );

        lpAdapter.execute(address(this), lpParams);
    }

    function _exitAllLP() internal {
        // Withdraw all LP positions via farm adapter
        bytes memory farmParams = abi.encode(
            3, // EMERGENCY_WITHDRAW
            2, // poolId (CAKE/WBNB)
            0,
            0,
            0,
            0,
            address(this)
        );

        (bool success, ) = address(farmAdapter).call(
            abi.encodeWithSignature("execute(address,bytes)", address(this), farmParams)
        );
        require(success, "SR: LP exit failed");
    }

    function _withdrawFromEarn(uint256 amount) internal {
        bytes memory earnParams = abi.encode(
            uint8(1),      // ActionType.WITHDRAW
            uint8(0),      // Asset.USDF
            amount,        // amount
            uint256(0),    // mintRatio (not used for withdrawal)
            uint256(0),    // minReceived (accept any)
            uint256(0),    // requestId (not used for withdrawal)
            address(this)  // recipient
        );

        earnAdapter.execute(address(this), earnParams);
    }

    function _isVault(address addr) internal view returns (bool) {
        // Check if caller is the MetaVault (query engineCore for vault address)
        (bool success, bytes memory data) = engineCore.staticcall(
            abi.encodeWithSignature("vault()")
        );
        if (!success || data.length == 0) return false;
        address vaultAddr = abi.decode(data, (address));
        return addr == vaultAddr;
    }

    // ─── View Functions ──────────────────────────────────────────────────────

    /// @notice Total assets managed by this router
    function totalManagedAssets() external view returns (uint256) {
        uint256 bufferBalance = IERC20(USDT).balanceOf(address(this));
        uint256 earnValue = _getEarnValue();
        uint256 lpValue = _getLPValue();

        return bufferBalance + earnValue + lpValue;
    }

    /// @notice Get value of Earn position in USDT
    function _getEarnValue() internal view returns (uint256) {
        address ASUSDF = 0x917AF46B3C3c6e1Bb7286B9F59637Fb7C65851Fb;
        address ASUSDF_MINTER = 0xdB57a53C428a9faFcbFefFB6dd80d0f427543695;
        uint256 asUsdfBalance = IERC20(ASUSDF).balanceOf(address(this));
        if (asUsdfBalance == 0) return 0;

        // Query actual asUSDF → USDF exchange rate from AsterEarn
        uint256 usdfValue;
        (bool rateOk, bytes memory rateData) = ASUSDF_MINTER.staticcall(
            abi.encodeWithSignature("exchangePrice()")
        );
        if (rateOk && rateData.length >= 32) {
            uint256 exchangeRate = abi.decode(rateData, (uint256));
            usdfValue = (asUsdfBalance * exchangeRate) / 1e18;
        } else {
            usdfValue = asUsdfBalance; // fallback to 1:1
        }

        // Convert USDF to USDT value using AMM price
        uint256 usdfPrice = VolatilityLib.getSpotPrice(USDF_USDT_PAIR);
        return (usdfValue * usdfPrice) / 1e18;
    }

    /// @notice Get value of LP position in USDT
    function _getLPValue() internal view returns (uint256) {
        uint256 lpBalance = _getTotalLPBalance();
        if (lpBalance == 0) return 0;

        uint256 lpSupply = IERC20(CAKE_WBNB_PAIR).totalSupply();
        if (lpSupply == 0) return 0;

        // Get our share of each token from LP reserves
        (uint256 ourCake, uint256 ourWbnb) = _getLPTokenShares(lpBalance, lpSupply);

        // Convert both sides to USDT
        return _getAmountOutViaRouter(PANCAKE_ROUTER, ourCake, CAKE, USDT)
             + _getAmountOutViaRouter(PANCAKE_ROUTER, ourWbnb, WBNB, USDT);
    }

    /// @notice Get total LP balance (wallet + staked in MasterChef)
    function _getTotalLPBalance() internal view returns (uint256 lpBalance) {
        lpBalance = IERC20(CAKE_WBNB_PAIR).balanceOf(address(this));

        (bool success, bytes memory data) = MASTERCHEF_V2.staticcall(
            abi.encodeWithSignature("userInfo(uint256,address)", uint256(2), address(this))
        );
        if (success && data.length >= 32) {
            lpBalance += abi.decode(data, (uint256));
        }
    }

    /// @notice Compute our share of CAKE and WBNB from LP position
    function _getLPTokenShares(uint256 lpBalance, uint256 lpSupply)
        internal view returns (uint256 ourCake, uint256 ourWbnb)
    {
        (bool resOk, bytes memory resData) = CAKE_WBNB_PAIR.staticcall(
            abi.encodeWithSignature("getReserves()")
        );
        if (!resOk || resData.length < 64) return (0, 0);

        (uint112 reserve0, uint112 reserve1, ) = abi.decode(resData, (uint112, uint112, uint32));

        (bool t0Ok, bytes memory t0Data) = CAKE_WBNB_PAIR.staticcall(
            abi.encodeWithSignature("token0()")
        );
        if (!t0Ok || t0Data.length < 32) return (0, 0);
        address token0 = abi.decode(t0Data, (address));

        if (token0 == CAKE) {
            ourCake = (uint256(reserve0) * lpBalance) / lpSupply;
            ourWbnb = (uint256(reserve1) * lpBalance) / lpSupply;
        } else {
            ourCake = (uint256(reserve1) * lpBalance) / lpSupply;
            ourWbnb = (uint256(reserve0) * lpBalance) / lpSupply;
        }
    }

    /// @notice Get quote from PancakeSwap router
    function _getAmountOutViaRouter(
        address routerAddr,
        uint256 amountIn,
        address fromToken,
        address toToken
    ) internal view returns (uint256) {
        if (amountIn == 0) return 0;

        // Encode the path [fromToken, toToken]
        // We call getAmountsOut(uint256, address[]) view
        address[] memory path = new address[](2);
        path[0] = fromToken;
        path[1] = toToken;

        (bool ok, bytes memory result) = routerAddr.staticcall(
            abi.encodeWithSignature("getAmountsOut(uint256,address[])", amountIn, path)
        );
        if (!ok || result.length < 64) return 0;

        uint256[] memory amounts = abi.decode(result, (uint256[]));
        return amounts[amounts.length - 1];
    }

    /// @notice Current on-chain risk score (0-100)
    function riskScore() external view returns (uint256) {
        uint256 currentPrice = VolatilityLib.getSpotPrice(USDF_USDT_PAIR);
        uint256 deviation = VolatilityLib.priceDeviation(currentPrice, lastPriceSnapshot);
        return VolatilityLib.riskScore(deviation);
    }
}
