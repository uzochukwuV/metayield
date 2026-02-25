// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title YieldOracle
/// @notice On-chain APY tracking for multiple stablecoin pools
/// @dev Queries AsterDEX exchange rates to compute real-time APYs
///      Enables yield-chasing: automatically routes to highest-yielding stable
library YieldOracle {
    // ─── AsterDEX Addresses ─────────────────────────────────────────────────

    // Stablecoins
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant USDF = 0x5A110fC00474038f6c02E89C707D638602EA44B5;
    address public constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;

    // Yield tokens
    address public constant ASUSDF = 0x917AF46B3C3c6e1Bb7286B9F59637Fb7C65851Fb;

    // Minters (for exchange rate queries)
    address public constant USDF_MINTER = 0xC271fc70dD9E678ac1AB632f797894fe4BE2C345;
    address public constant ASUSDF_MINTER = 0xdB57a53C428a9faFcbFefFB6dd80d0f427543695;

    // PancakeSwap pairs for price queries
    address public constant BUSD_USDT_PAIR = 0x7EFaEf62fDdCCa950418312c6C91Aef321375A00;

    // ─── Structs ────────────────────────────────────────────────────────────

    enum StableAsset { USDT, USDF, BUSD }

    struct YieldInfo {
        StableAsset asset;
        uint256 currentRate;      // Current exchange rate (1e18 = 1.0)
        uint256 estimatedAPY;     // APY in bps (10000 = 100%)
        uint256 tvl;              // Total value locked
        bool isActive;            // Whether this pool is accepting deposits
    }

    struct YieldSnapshot {
        uint256 usdfRate;
        uint256 asUsdfRate;
        uint256 timestamp;
    }

    // ─── Core Functions ─────────────────────────────────────────────────────

    /// @notice Get current exchange rate for asUSDF (primary yield source)
    /// @return rate Exchange rate in 1e18 (e.g., 1.05e18 = 1.05 USDF per asUSDF)
    function getAsUsdfRate() internal view returns (uint256 rate) {
        (bool success, bytes memory data) = ASUSDF_MINTER.staticcall(
            abi.encodeWithSignature("exchangePrice()")
        );
        if (success && data.length >= 32) {
            rate = abi.decode(data, (uint256));
        } else {
            rate = 1e18; // Fallback to 1:1
        }
    }

    /// @notice Get USDF to USDT price from AMM
    /// @return price USDF price in USDT (1e18 scale)
    function getUsdfPrice() internal view returns (uint256 price) {
        // Query BUSD/USDT pair reserves (USDF tracks BUSD closely)
        (bool success, bytes memory data) = BUSD_USDT_PAIR.staticcall(
            abi.encodeWithSignature("getReserves()")
        );
        if (!success || data.length < 64) return 1e18;

        (uint112 reserve0, uint112 reserve1, ) = abi.decode(data, (uint112, uint112, uint32));
        if (reserve0 == 0 || reserve1 == 0) return 1e18;

        // Get token0 to determine order
        (bool t0Ok, bytes memory t0Data) = BUSD_USDT_PAIR.staticcall(
            abi.encodeWithSignature("token0()")
        );
        if (!t0Ok) return 1e18;
        address token0 = abi.decode(t0Data, (address));

        // Calculate price: BUSD/USDT ≈ USDF/USDT (both USD-pegged)
        if (token0 == BUSD) {
            price = (uint256(reserve1) * 1e18) / uint256(reserve0);
        } else {
            price = (uint256(reserve0) * 1e18) / uint256(reserve1);
        }
    }

    /// @notice Compute estimated APY from exchange rate growth
    /// @param currentRate Current exchange rate
    /// @param previousRate Previous exchange rate
    /// @param timeDelta Time elapsed in seconds
    /// @return apyBps Annualized APY in basis points
    function computeAPY(
        uint256 currentRate,
        uint256 previousRate,
        uint256 timeDelta
    ) internal pure returns (uint256 apyBps) {
        if (previousRate == 0 || timeDelta == 0 || currentRate <= previousRate) {
            return 0;
        }

        // Growth = (current - previous) / previous
        uint256 growth = ((currentRate - previousRate) * 1e18) / previousRate;

        // Annualize: APY = growth * (365 days / timeDelta)
        uint256 annualized = (growth * 365 days) / timeDelta;

        // Convert to bps (multiply by 10000, divide by 1e18)
        apyBps = (annualized * 10_000) / 1e18;
    }

    /// @notice Get yield info for all supported stablecoins
    /// @param prevSnapshot Previous yield snapshot for APY calculation
    /// @return infos Array of YieldInfo for each stable
    function getAllYieldInfo(YieldSnapshot memory prevSnapshot)
        internal
        view
        returns (YieldInfo[3] memory infos)
    {
        uint256 currentAsUsdfRate = getAsUsdfRate();
        uint256 usdfPrice = getUsdfPrice();
        uint256 timeDelta = block.timestamp - prevSnapshot.timestamp;

        // USDT → USDF → asUSDF path
        // Effective rate = asUSDF rate * USDF price
        uint256 effectiveUsdtRate = (currentAsUsdfRate * usdfPrice) / 1e18;

        // USDF → asUSDF path (direct)
        uint256 effectiveUsdfRate = currentAsUsdfRate;

        // BUSD → (swap to USDT) → USDF → asUSDF path
        // Similar to USDT but with swap overhead (~0.3% fee)
        uint256 effectiveBusdRate = (effectiveUsdtRate * 9970) / 10000; // 0.3% swap fee

        // Compute APYs
        uint256 usdtAPY = computeAPY(effectiveUsdtRate, prevSnapshot.asUsdfRate, timeDelta);
        uint256 usdfAPY = computeAPY(effectiveUsdfRate, prevSnapshot.asUsdfRate, timeDelta);
        uint256 busdAPY = computeAPY(effectiveBusdRate, prevSnapshot.asUsdfRate, timeDelta);

        // USDF typically has highest APY (no swap fees, direct deposit)
        infos[0] = YieldInfo({
            asset: StableAsset.USDT,
            currentRate: effectiveUsdtRate,
            estimatedAPY: usdtAPY,
            tvl: 0, // Would need to query
            isActive: true
        });

        infos[1] = YieldInfo({
            asset: StableAsset.USDF,
            currentRate: effectiveUsdfRate,
            estimatedAPY: usdfAPY,
            tvl: 0,
            isActive: true
        });

        infos[2] = YieldInfo({
            asset: StableAsset.BUSD,
            currentRate: effectiveBusdRate,
            estimatedAPY: busdAPY,
            tvl: 0,
            isActive: true
        });
    }

    /// @notice Find the highest-yielding stablecoin
    /// @param prevSnapshot Previous snapshot for APY calculation
    /// @return bestAsset The asset with highest APY
    /// @return bestAPY The highest APY in bps
    function findBestYield(YieldSnapshot memory prevSnapshot)
        internal
        view
        returns (StableAsset bestAsset, uint256 bestAPY)
    {
        YieldInfo[3] memory infos = getAllYieldInfo(prevSnapshot);

        bestAsset = StableAsset.USDF; // Default to USDF (usually best)
        bestAPY = 0;

        for (uint256 i = 0; i < 3; i++) {
            if (infos[i].isActive && infos[i].estimatedAPY > bestAPY) {
                bestAPY = infos[i].estimatedAPY;
                bestAsset = infos[i].asset;
            }
        }
    }

    /// @notice Check if yield difference warrants rebalancing
    /// @param currentAsset Current allocation
    /// @param bestAsset Best yielding asset
    /// @param currentAPY Current APY
    /// @param bestAPY Best available APY
    /// @param thresholdBps Minimum difference to trigger rebalance (e.g., 50 = 0.5%)
    /// @return shouldSwitch Whether to switch assets
    function shouldChaseYield(
        StableAsset currentAsset,
        StableAsset bestAsset,
        uint256 currentAPY,
        uint256 bestAPY,
        uint256 thresholdBps
    ) internal pure returns (bool shouldSwitch) {
        if (currentAsset == bestAsset) return false;
        if (bestAPY <= currentAPY) return false;

        // Only switch if difference exceeds threshold (accounts for swap costs)
        uint256 difference = bestAPY - currentAPY;
        return difference >= thresholdBps;
    }

    /// @notice Create a new yield snapshot
    function createSnapshot() internal view returns (YieldSnapshot memory) {
        return YieldSnapshot({
            usdfRate: getUsdfPrice(),
            asUsdfRate: getAsUsdfRate(),
            timestamp: block.timestamp
        });
    }
}
