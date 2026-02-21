// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Minimal interface for PancakeSwap pair
interface IPair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

/// @title VolatilityLib
/// @notice On-chain volatility detection using PancakeSwap USDF/USDT spot price
/// @dev Fully deterministic. No oracles. No admin input.
library VolatilityLib {
    // ─── Market Modes ────────────────────────────────────────────────────────
    enum MarketMode {
        NORMAL,      // Price stable: 60% Earn, 30% LP, 10% Buffer
        VOLATILE,    // Price moving: 80% Earn, 10% LP, 10% Buffer (reduce LP exposure)
        DRAWDOWN     // Price crash: 90% Earn, 0% LP, 10% Buffer (exit LP entirely)
    }

    // ─── Constants ───────────────────────────────────────────────────────────
    uint256 public constant NORMAL_EARN_BPS = 6000;    // 60%
    uint256 public constant VOLATILE_EARN_BPS = 8000;  // 80%
    uint256 public constant DRAWDOWN_EARN_BPS = 9000;  // 90%

    uint256 public constant VOLATILE_THRESHOLD_BPS = 300;  // 3% deviation
    uint256 public constant DRAWDOWN_THRESHOLD_BPS = 500;  // 5% deviation

    // ─── Core Functions ──────────────────────────────────────────────────────

    /// @notice Get current spot price from PancakeSwap USDF/USDT pair
    /// @param pairAddress The PancakeSwap V2 pair address
    /// @return price USDF price in USDT terms (scaled by 1e18)
    function getSpotPrice(address pairAddress) internal view returns (uint256 price) {
        IPair pair = IPair(pairAddress);
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();

        // Assume token0 = USDF, token1 = USDT
        // Price = reserve1 / reserve0 (USDT per USDF)
        if (reserve0 == 0) return 1e18; // default to 1.0 if no liquidity

        price = (uint256(reserve1) * 1e18) / uint256(reserve0);
    }

    /// @notice Calculate price deviation in basis points
    /// @param currentPrice Current spot price
    /// @param referencePrice Reference price (from last snapshot)
    /// @return deviationBps Absolute deviation in basis points
    function priceDeviation(
        uint256 currentPrice,
        uint256 referencePrice
    ) internal pure returns (uint256 deviationBps) {
        if (referencePrice == 0) return 0;

        uint256 diff = currentPrice > referencePrice
            ? currentPrice - referencePrice
            : referencePrice - currentPrice;

        deviationBps = (diff * 10_000) / referencePrice;
    }

    /// @notice Determine market mode based on price deviation
    /// @param deviationBps Price deviation in basis points
    /// @return mode Market mode (NORMAL, VOLATILE, or DRAWDOWN)
    function getMarketMode(uint256 deviationBps) internal pure returns (MarketMode mode) {
        if (deviationBps >= DRAWDOWN_THRESHOLD_BPS) {
            return MarketMode.DRAWDOWN;
        } else if (deviationBps >= VOLATILE_THRESHOLD_BPS) {
            return MarketMode.VOLATILE;
        } else {
            return MarketMode.NORMAL;
        }
    }

    /// @notice Get target Earn allocation for a given market mode
    /// @param mode Market mode
    /// @return earnBps Earn allocation in basis points
    function getEarnAllocation(MarketMode mode) internal pure returns (uint256 earnBps) {
        if (mode == MarketMode.DRAWDOWN) {
            return DRAWDOWN_EARN_BPS;
        } else if (mode == MarketMode.VOLATILE) {
            return VOLATILE_EARN_BPS;
        } else {
            return NORMAL_EARN_BPS;
        }
    }

    /// @notice Check if rebalance is needed based on drift from target
    /// @param currentBps Current allocation in basis points
    /// @param targetBps Target allocation in basis points
    /// @param driftThresholdBps Maximum allowed drift before rebalance
    /// @return needed True if rebalance is needed
    function isRebalanceNeeded(
        uint256 currentBps,
        uint256 targetBps,
        uint256 driftThresholdBps
    ) internal pure returns (bool needed) {
        uint256 diff = currentBps > targetBps
            ? currentBps - targetBps
            : targetBps - currentBps;

        return diff >= driftThresholdBps;
    }

    /// @notice Compute risk score (0-100) based on deviation
    /// @param deviationBps Price deviation in basis points
    /// @return score Risk score (0 = no risk, 100 = max risk)
    function riskScore(uint256 deviationBps) internal pure returns (uint256 score) {
        // Cap at 10% deviation = 100 risk score
        if (deviationBps >= 1000) return 100;
        return (deviationBps * 100) / 1000;
    }
}
