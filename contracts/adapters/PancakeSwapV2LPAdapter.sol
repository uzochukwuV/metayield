// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPancakeRouter02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IPancakePair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
}

/**
 * @title PancakeSwapV2LPAdapter
 * @notice Standalone adapter for PancakeSwap V2 liquidity operations
 */
contract PancakeSwapV2LPAdapter {
    using SafeERC20 for IERC20;

    address public immutable router;
    address public immutable factory;
    address public immutable WBNB;

    uint256 public constant MAX_SLIPPAGE_BPS = 1000;
    uint256 public constant DEFAULT_DEADLINE = 300;

    enum ActionType { ADD_LIQUIDITY, ADD_LIQUIDITY_ETH, REMOVE_LIQUIDITY, REMOVE_LIQUIDITY_ETH }

    struct LiquidityParams {
        ActionType actionType;
        address tokenA;
        address tokenB;
        uint256 amountADesired;
        uint256 amountBDesired;
        uint256 amountAMin;
        uint256 amountBMin;
        uint256 liquidity;
        uint256 slippageBps;
        address recipient;
    }

    struct LiquidityResult {
        uint256 amountA;
        uint256 amountB;
        uint256 liquidity;
    }

    event LiquidityAdded(address indexed tokenA, address indexed tokenB, uint256 amountA, uint256 amountB, uint256 liquidity, address indexed recipient);
    event LiquidityRemoved(address indexed tokenA, address indexed tokenB, uint256 amountA, uint256 amountB, uint256 liquidity, address indexed recipient);

    constructor(address _router) {
        require(_router != address(0), "Invalid router");
        router = _router;
        factory = IPancakeRouter02(_router).factory();
        WBNB = IPancakeRouter02(_router).WETH();
    }

    function execute(address vault, bytes calldata params)
        external
        returns (bool success, bytes memory result)
    {
        LiquidityParams memory p = abi.decode(params, (LiquidityParams));
        _validateParams(p);

        LiquidityResult memory res;

        if (p.actionType == ActionType.ADD_LIQUIDITY) {
            res = _addLiquidity(vault, p);
        } else if (p.actionType == ActionType.REMOVE_LIQUIDITY) {
            res = _removeLiquidity(vault, p);
        } else {
            revert("Invalid action type");
        }

        return (true, abi.encode(res));
    }

    function _validateParams(LiquidityParams memory p) internal pure {
        require(p.tokenA != address(0), "Invalid tokenA");
        require(p.slippageBps <= MAX_SLIPPAGE_BPS, "Slippage too high");
        require(p.recipient != address(0), "Invalid recipient");
    }

    function _addLiquidity(address /* vault */, LiquidityParams memory p)
        internal
        returns (LiquidityResult memory result)
    {
        IERC20(p.tokenA).forceApprove(router, p.amountADesired);
        IERC20(p.tokenB).forceApprove(router, p.amountBDesired);

        uint256 amountAMin = p.amountAMin > 0 ? p.amountAMin : _applySlippage(p.amountADesired, p.slippageBps);
        uint256 amountBMin = p.amountBMin > 0 ? p.amountBMin : _applySlippage(p.amountBDesired, p.slippageBps);

        (result.amountA, result.amountB, result.liquidity) = IPancakeRouter02(router).addLiquidity(
            p.tokenA,
            p.tokenB,
            p.amountADesired,
            p.amountBDesired,
            amountAMin,
            amountBMin,
            p.recipient,
            block.timestamp + DEFAULT_DEADLINE
        );

        IERC20(p.tokenA).forceApprove(router, 0);
        IERC20(p.tokenB).forceApprove(router, 0);

        emit LiquidityAdded(p.tokenA, p.tokenB, result.amountA, result.amountB, result.liquidity, p.recipient);
    }

    function _removeLiquidity(address /* vault */, LiquidityParams memory p)
        internal
        returns (LiquidityResult memory result)
    {
        address pair = IPancakeFactory(factory).getPair(p.tokenA, p.tokenB);
        require(pair != address(0), "Pair does not exist");

        IERC20(pair).forceApprove(router, p.liquidity);

        (uint256 amountAExpected, uint256 amountBExpected) = _getExpectedAmounts(pair, p.liquidity, p.tokenA);
        uint256 amountAMin = p.amountAMin > 0 ? p.amountAMin : _applySlippage(amountAExpected, p.slippageBps);
        uint256 amountBMin = p.amountBMin > 0 ? p.amountBMin : _applySlippage(amountBExpected, p.slippageBps);

        (result.amountA, result.amountB) = IPancakeRouter02(router).removeLiquidity(
            p.tokenA,
            p.tokenB,
            p.liquidity,
            amountAMin,
            amountBMin,
            p.recipient,
            block.timestamp + DEFAULT_DEADLINE
        );

        result.liquidity = p.liquidity;

        emit LiquidityRemoved(p.tokenA, p.tokenB, result.amountA, result.amountB, result.liquidity, p.recipient);
    }

    function _applySlippage(uint256 amount, uint256 slippageBps) internal pure returns (uint256) {
        return (amount * (10000 - slippageBps)) / 10000;
    }

    function _getExpectedAmounts(address pair, uint256 liquidity, address tokenA)
        internal
        view
        returns (uint256 amountA, uint256 amountB)
    {
        uint256 totalSupply = IPancakePair(pair).totalSupply();
        if (totalSupply == 0) return (0, 0);

        (uint112 reserve0, uint112 reserve1,) = IPancakePair(pair).getReserves();
        address token0 = IPancakePair(pair).token0();

        uint256 amount0 = (uint256(reserve0) * liquidity) / totalSupply;
        uint256 amount1 = (uint256(reserve1) * liquidity) / totalSupply;

        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
    }

    function getPairAddress(address tokenA, address tokenB) external view returns (address) {
        return IPancakeFactory(factory).getPair(tokenA, tokenB);
    }

    receive() external payable {}
}
