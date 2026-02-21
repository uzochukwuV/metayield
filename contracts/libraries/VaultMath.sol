// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title VaultMath
/// @notice Math helpers for vault calculations
library VaultMath {
    uint256 public constant MAX_BPS = 10_000;

    /// @notice Calculate allocation split between Earn and LP
    /// @param totalAmount Total amount to allocate
    /// @param earnBps Earn allocation in basis points
    /// @return earnAmount Amount to allocate to Earn
    /// @return lpAmount Amount to allocate to LP
    function calcAllocation(
        uint256 totalAmount,
        uint256 earnBps
    ) internal pure returns (uint256 earnAmount, uint256 lpAmount) {
        earnAmount = (totalAmount * earnBps) / MAX_BPS;
        lpAmount = totalAmount - earnAmount;
    }

    /// @notice Apply slippage tolerance to an amount
    /// @param amount Original amount
    /// @param slippageBps Slippage in basis points
    /// @return minAmount Minimum acceptable amount after slippage
    function applySlippage(
        uint256 amount,
        uint256 slippageBps
    ) internal pure returns (uint256 minAmount) {
        minAmount = (amount * (MAX_BPS - slippageBps)) / MAX_BPS;
    }

    /// @notice Calculate share price (assets per share)
    /// @param totalAssets Total assets in vault
    /// @param totalShares Total shares outstanding
    /// @return price Share price scaled by 1e18
    function sharePrice(
        uint256 totalAssets,
        uint256 totalShares
    ) internal pure returns (uint256 price) {
        if (totalShares == 0) return 1e18;
        return (totalAssets * 1e18) / totalShares;
    }

    /// @notice Calculate performance fee shares to mint
    /// @param profit Profit earned since last harvest
    /// @param feeBps Performance fee in basis points
    /// @param totalAssets Total assets before profit
    /// @param totalShares Total shares before fee
    /// @return feeShares Shares to mint as performance fee
    function calcPerformanceFeeShares(
        uint256 profit,
        uint256 feeBps,
        uint256 totalAssets,
        uint256 totalShares
    ) internal pure returns (uint256 feeShares) {
        if (profit == 0 || totalShares == 0) return 0;

        uint256 feeAmount = (profit * feeBps) / MAX_BPS;
        // feeShares = (feeAmount * totalShares) / totalAssets
        feeShares = (feeAmount * totalShares) / totalAssets;
    }

    /// @notice Compute annualized APY in basis points
    /// @param profit Profit earned
    /// @param totalAssets Total assets at start of period
    /// @param periodSeconds Time period in seconds
    /// @return apyBps APY in basis points
    function computeAPY(
        uint256 profit,
        uint256 totalAssets,
        uint256 periodSeconds
    ) internal pure returns (uint256 apyBps) {
        if (totalAssets == 0 || periodSeconds == 0) return 0;

        // APY = (profit / totalAssets) * (365 days / period) * 10000
        uint256 secondsPerYear = 365 days;
        apyBps = (profit * MAX_BPS * secondsPerYear) / (totalAssets * periodSeconds);
    }

    /// @notice Calculate amount out from AMM with 0.25% fee
    /// @param amountIn Input amount
    /// @param reserveIn Input reserve
    /// @param reserveOut Output reserve
    /// @return amountOut Output amount
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "VaultMath: zero input");
        require(reserveIn > 0 && reserveOut > 0, "VaultMath: zero reserves");

        uint256 amountInWithFee = amountIn * 9975; // 0.25% fee
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 10000) + amountInWithFee;
        amountOut = numerator / denominator;
    }
}
