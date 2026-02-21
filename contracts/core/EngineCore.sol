// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../libraries/VolatilityLib.sol";

/// @title EngineCore
/// @notice The autonomous orchestrator of the MetaYield protocol.
/// @dev executeCycle() is callable by ANYONE. No privileged role. No owner.
///      No onlyOwner. No Pausable. No upgradeable proxy.
///      Automation is purely state-based and timestamp-driven.
///
///      Built for the BNB Chain Good Vibes Only Hackathon.
///
///      Cycle logic:
///        1. Check cooldown (min interval between cycles)
///        2. Detect volatility via VolatilityLib
///        3. Trigger StrategyRouter.rebalance() if needed
///        4. Deploy any pending capital in vault
///        5. Record harvest in MetaVault for fee accounting
contract EngineCore is ReentrancyGuard {
    using VolatilityLib for uint256;

    // ─── Immutables ──────────────────────────────────────────────────────────
    address public immutable vault;
    address public immutable strategyRouter;

    // ─── Constants ───────────────────────────────────────────────────────────
    /// @notice Minimum time between cycle executions (1 hour)
    uint256 public constant CYCLE_INTERVAL = 1 hours;

    /// @notice BUSD/USDT PancakeSwap V2 pair for volatility detection (proxy for stablecoin stress)
    address public constant USDF_USDT_PAIR = 0x7EFaEf62fDdCCa950418312c6C91Aef321375A00;

    // ─── State ───────────────────────────────────────────────────────────────
    uint256 public lastCycleTime;
    uint256 public totalCyclesExecuted;
    uint256 public lastPriceSnapshot;
    VolatilityLib.MarketMode public lastMode;

    // ─── Events ──────────────────────────────────────────────────────────────
    event CycleExecuted(
        address indexed caller,
        VolatilityLib.MarketMode mode,
        uint256 riskScore,
        uint256 cycleNumber,
        uint256 timestamp
    );
    event RebalanceTriggered(VolatilityLib.MarketMode mode, uint256 deviationBps);
    event CapitalDeployed(uint256 timestamp);
    event CycleCooldown(uint256 nextCycleTime);

    // ─── Constructor ─────────────────────────────────────────────────────────
    constructor(
        address _vault,
        address _strategyRouter
    ) {
        require(_vault != address(0), "EC: zero vault");
        require(_strategyRouter != address(0), "EC: zero router");

        vault = _vault;
        strategyRouter = _strategyRouter;

        lastCycleTime = block.timestamp;
        lastPriceSnapshot = 1e18; // Initialize to 1.0, will update on first cycle
        lastMode = VolatilityLib.MarketMode.NORMAL;
    }

    // ─── Core: executeCycle ──────────────────────────────────────────────────

    /// @notice Execute one autonomous protocol cycle.
    /// @dev Callable by ANYONE. No privileged role.
    ///      Enforces cooldown via block.timestamp.
    ///      Deterministic: outcome depends only on on-chain state.
    function executeCycle() external nonReentrant {
        // ── 1. Cooldown check ────────────────────────────────────────────────
        uint256 nextCycle = lastCycleTime + CYCLE_INTERVAL;
        if (block.timestamp < nextCycle) {
            emit CycleCooldown(nextCycle);
            revert("EC: cooldown active");
        }

        // ── 2. Compute on-chain volatility ───────────────────────────────────
        uint256 currentPrice = VolatilityLib.getSpotPrice(USDF_USDT_PAIR);
        uint256 deviationBps = VolatilityLib.priceDeviation(currentPrice, lastPriceSnapshot);
        VolatilityLib.MarketMode mode = VolatilityLib.getMarketMode(deviationBps);
        uint256 risk = VolatilityLib.riskScore(deviationBps);

        // ── 3. Rebalance if mode changed or drift exceeded ───────────────────
        bool shouldRebalance = (mode != lastMode) ||
            VolatilityLib.isRebalanceNeeded(
                _getEarnBps(lastMode),
                VolatilityLib.getEarnAllocation(mode),
                200 // 2% drift threshold
            );

        if (shouldRebalance) {
            (bool ok, ) = strategyRouter.call(abi.encodeWithSignature("rebalance()"));
            require(ok, "EC: rebalance failed");
            emit RebalanceTriggered(mode, deviationBps);
        }

        // ── 4. Deploy pending capital ────────────────────────────────────────
        (bool deployOk, ) = strategyRouter.call(abi.encodeWithSignature("deployCapital()"));
        require(deployOk, "EC: deploy failed");
        emit CapitalDeployed(block.timestamp);

        // ── 5. Record harvest in vault for fee accounting ────────────────────
        uint256 newTotalAssets = _queryTotalAssets();
        (bool harvestOk, ) = vault.call(
            abi.encodeWithSignature("recordHarvest(uint256)", newTotalAssets)
        );
        require(harvestOk, "EC: harvest record failed");

        // ── 6. Update state ──────────────────────────────────────────────────
        lastPriceSnapshot = currentPrice;
        lastMode = mode;
        lastCycleTime = block.timestamp;
        totalCyclesExecuted++;

        emit CycleExecuted(msg.sender, mode, risk, totalCyclesExecuted, block.timestamp);
    }

    // ─── View Functions ──────────────────────────────────────────────────────

    /// @notice Check if a cycle can be executed right now
    function canExecuteCycle() external view returns (bool) {
        return block.timestamp >= lastCycleTime + CYCLE_INTERVAL;
    }

    /// @notice Seconds until next cycle is allowed
    function timeUntilNextCycle() external view returns (uint256) {
        uint256 nextCycle = lastCycleTime + CYCLE_INTERVAL;
        if (block.timestamp >= nextCycle) return 0;
        return nextCycle - block.timestamp;
    }

    /// @notice Current on-chain market mode
    function currentMarketMode() external view returns (VolatilityLib.MarketMode) {
        uint256 currentPrice = VolatilityLib.getSpotPrice(USDF_USDT_PAIR);
        uint256 deviationBps = VolatilityLib.priceDeviation(currentPrice, lastPriceSnapshot);
        return VolatilityLib.getMarketMode(deviationBps);
    }

    /// @notice Current on-chain risk score (0-100)
    function currentRiskScore() external view returns (uint256) {
        uint256 currentPrice = VolatilityLib.getSpotPrice(USDF_USDT_PAIR);
        uint256 deviationBps = VolatilityLib.priceDeviation(currentPrice, lastPriceSnapshot);
        return VolatilityLib.riskScore(deviationBps);
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    function _getEarnBps(VolatilityLib.MarketMode mode) internal pure returns (uint256) {
        return VolatilityLib.getEarnAllocation(mode);
    }

    function _queryTotalAssets() internal view returns (uint256) {
        (bool success, bytes memory data) = strategyRouter.staticcall(
            abi.encodeWithSignature("totalManagedAssets()")
        );
        if (!success || data.length == 0) return 0;
        return abi.decode(data, (uint256));
    }
}
