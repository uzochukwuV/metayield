// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAsterPerp
 * @notice Interface for Aster DEX Perpetuals — TradingPortalFacet (Diamond proxy)
 * @dev Contract: 0x5553f3b5e2fad83eda4031a3894ee59e25ee90bf (BSC mainnet)
 *
 * Type conventions:
 *   qty   : 1e10  — so 1 BNB = 10_000_000_000
 *   price : 1e8   — so BNB at 300 USD = 30_000_000_000
 *   amountIn/margin: tokenIn decimals (USDT = 18 dec on BSC)
 */
interface IAsterPerp {

    struct OpenDataInput {
        address pairBase;
        bool    isLong;
        address tokenIn;
        uint96  amountIn;
        uint80  qty;
        uint64  price;
        uint64  stopLoss;
        uint64  takeProfit;
        uint24  broker;
    }

    function openMarketTrade(OpenDataInput memory data)
        external returns (bytes32 tradeHash);

    function openMarketTradeBNB(OpenDataInput memory data)
        external payable returns (bytes32 tradeHash);

    function closeTrade(bytes32 tradeHash) external;

    function batchCloseTrade(bytes32[] calldata tradeHashes) external;

    function updateTradeTp(bytes32 tradeHash, uint64 takeProfit) external;

    function updateTradeSl(bytes32 tradeHash, uint64 stopLoss) external;

    function updateTradeTpAndSl(
        bytes32 tradeHash,
        uint64  takeProfit,
        uint64  stopLoss
    ) external;

    function addMargin(bytes32 tradeHash, uint96 amount) external payable;
}
