// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../libraries/VolatilityLib.sol";

/// @title EngineCore
/// @notice The autonomous orchestrator of the MetaYield protocol.
/// @dev executeCycle() is callable by ANYONE. No privileged role. No owner.
///      No onlyOwner. No Pausable. No upgradeable proxy.
///      Automation is purely state-based and timestamp-driven.
///
///      Callers receive a bounty (CALLER_BOUNTY_BPS of yield harvested)
///      as economic incentive to trigger cycles. This makes the protocol
///      self-sustaining without any off-chain keeper infrastructure.
///
///      Built for the BNB Chain Good Vibes Only Hackathon.
///
///      Cycle logic:
///        1. Check cooldown (min interval between cycles)
///        2. Detect volatility via VolatilityLib (EMA-smoothed)
///        3. Trigger StrategyRouter.rebalance() if needed
///        4. Deploy any pending capital in vault
///        5. Record harvest in MetaVault for fee accounting
///        6. Pay bounty to caller
contract EngineCore is ReentrancyGuard {
    using VolatilityLib for uint256;
    using SafeERC20 for IERC20;

    // ─── Immutables ──────────────────────────────────────────────────────────
    address public immutable vault;
    address public immutable strategyRouter;

    // ─── Constants ───────────────────────────────────────────────────────────
    /// @notice Minimum time between cycle executions (1 hour)
    uint256 public constant CYCLE_INTERVAL = 1 hours;

    /// @notice BUSD/USDT PancakeSwap V2 pair for volatility detection
    address public constant USDF_USDT_PAIR = 0x7EFaEf62fDdCCa950418312c6C91Aef321375A00;

    /// @notice USDT on BSC mainnet
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    /// @notice Bounty paid to cycle caller in bps of yield harvested (0.5%)
    /// @dev This incentivizes permissionless keepers to call executeCycle()
    uint256 public constant CALLER_BOUNTY_BPS = 50;

    /// @notice EMA smoothing factor (alpha = 20%, stored as 2000/10000)
    uint256 public constant EMA_ALPHA = 2000;

    // ─── State ───────────────────────────────────────────────────────────────
    uint256 public lastCycleTime;
    uint256 public totalCyclesExecuted;
    uint256 public lastPriceSnapshot;
    VolatilityLib.MarketMode public lastMode;

    /// @notice EMA of price deviation (smoothed volatility signal)
    uint256 public emaDeviationBps;

    /// @notice Total bounties paid out lifetime (tracking)
    uint256 public totalBountiesPaid;

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
    event CallerBountyPaid(address indexed caller, uint256 amount);

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
    ///      Caller receives a bounty as economic incentive.
    function executeCycle() external nonReentrant {
        // ── 1. Cooldown check ────────────────────────────────────────────────
        uint256 nextCycle = lastCycleTime + CYCLE_INTERVAL;
        if (block.timestamp < nextCycle) {
            emit CycleCooldown(nextCycle);
            revert("EC: cooldown active");
        }

        // ── 2. Snapshot total assets BEFORE operations ───────────────────────
        uint256 assetsBefore = _queryTotalAssets();

        // ── 3. Compute on-chain volatility (EMA-smoothed) ────────────────────
        uint256 currentPrice = VolatilityLib.getSpotPrice(USDF_USDT_PAIR);
        uint256 rawDeviationBps = VolatilityLib.priceDeviation(currentPrice, lastPriceSnapshot);

        // EMA smoothing: ema = alpha * raw + (1 - alpha) * prevEma
        emaDeviationBps = (EMA_ALPHA * rawDeviationBps + (10_000 - EMA_ALPHA) * emaDeviationBps) / 10_000;

        // Use EMA for mode determination (more stable than raw spot)
        VolatilityLib.MarketMode mode = VolatilityLib.getMarketMode(emaDeviationBps);
        uint256 risk = VolatilityLib.riskScore(emaDeviationBps);

        // ── 4. Rebalance if mode changed or drift exceeded ───────────────────
        bool shouldRebalance = (mode != lastMode) ||
            VolatilityLib.isRebalanceNeeded(
                _getEarnBps(lastMode),
                VolatilityLib.getEarnAllocation(mode),
                200 // 2% drift threshold
            );

        if (shouldRebalance) {
            (bool ok, ) = strategyRouter.call(abi.encodeWithSignature("rebalance()"));
            require(ok, "EC: rebalance failed");
            emit RebalanceTriggered(mode, emaDeviationBps);
        }

        // ── 5. Deploy pending capital ────────────────────────────────────────
        (bool deployOk, ) = strategyRouter.call(abi.encodeWithSignature("deployCapital()"));
        require(deployOk, "EC: deploy failed");
        emit CapitalDeployed(block.timestamp);

        // ── 6. Record harvest in vault for fee accounting ────────────────────
        uint256 newTotalAssets = _queryTotalAssets();
        (bool harvestOk, ) = vault.call(
            abi.encodeWithSignature("recordHarvest(uint256)", newTotalAssets)
        );
        require(harvestOk, "EC: harvest record failed");

        // ── 7. Pay bounty to caller ──────────────────────────────────────────
        _payCallerBounty(msg.sender, assetsBefore, newTotalAssets);

        // ── 8. Update state ──────────────────────────────────────────────────
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

    /// @notice Current on-chain market mode (using EMA-smoothed deviation)
    function currentMarketMode() external view returns (VolatilityLib.MarketMode) {
        uint256 currentPrice = VolatilityLib.getSpotPrice(USDF_USDT_PAIR);
        uint256 rawDev = VolatilityLib.priceDeviation(currentPrice, lastPriceSnapshot);
        uint256 smoothedDev = (EMA_ALPHA * rawDev + (10_000 - EMA_ALPHA) * emaDeviationBps) / 10_000;
        return VolatilityLib.getMarketMode(smoothedDev);
    }

    /// @notice Current on-chain risk score (0-100)
    function currentRiskScore() external view returns (uint256) {
        uint256 currentPrice = VolatilityLib.getSpotPrice(USDF_USDT_PAIR);
        uint256 rawDev = VolatilityLib.priceDeviation(currentPrice, lastPriceSnapshot);
        uint256 smoothedDev = (EMA_ALPHA * rawDev + (10_000 - EMA_ALPHA) * emaDeviationBps) / 10_000;
        return VolatilityLib.riskScore(smoothedDev);
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

    /// @notice Pay bounty to cycle caller from yield generated
    /// @dev Only pays if yield was positive. Bounty comes from the StrategyRouter buffer.
    function _payCallerBounty(address caller, uint256 assetsBefore, uint256 assetsAfter) internal {
        if (assetsAfter <= assetsBefore) return; // No yield, no bounty

        uint256 yield = assetsAfter - assetsBefore;
        uint256 bounty = (yield * CALLER_BOUNTY_BPS) / 10_000;
        if (bounty == 0) return;

        // Request bounty from StrategyRouter's buffer
        (bool ok, ) = strategyRouter.call(
            abi.encodeWithSignature("withdrawAssets(uint256,address)", bounty, caller)
        );
        if (ok) {
            totalBountiesPaid += bounty;
            emit CallerBountyPaid(caller, bounty);
        }
        // If withdrawal fails (insufficient buffer), skip bounty silently
    }
}
