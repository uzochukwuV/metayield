// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMinterAster {
    function smartMint(uint256 _amountIn, uint256 _mintRatio, uint256 _minOut) external returns (uint256);
    function withdraw(uint256 amount) external;
    function convertToAssTokens(uint256 tokens) external view returns (uint256);
    function convertToTokens(uint256 assTokens) external view returns (uint256);
    function estimateTotalOut(uint256 _amountIn, uint256 _mintRatio) external view returns (uint256);
    function totalTokens() external view returns (uint256);
    function maxSwapRatio() external view returns (uint256);
    function minSwapRatio() external view returns (uint256);
}

interface ISimpleEarn {
    function deposit(uint256 amountIn) external;
    function requestWithdraw(uint256 amount) external;
    function claimWithdraw(uint256[] calldata requestWithdrawNos) external;
    function exchangePrice() external view returns (uint256);
}

/**
 * @title AsterDEXEarnAdapter
 * @notice Standalone adapter for AsterDEX Earn yield products
 *
 * Products:
 *   USDF   (USDT → USDF)   - ISimpleEarn.deposit()
 *   asBNB  (slisBNB → asBNB) - IMinterAster.smartMint()
 *   asUSDF (USDF → asUSDF) - ISimpleEarn.deposit()
 */
contract AsterDEXEarnAdapter {
    using SafeERC20 for IERC20;

    uint256 public constant DENOMINATOR = 10_000;

    address public constant USDF        = 0x5A110fC00474038f6c02E89C707D638602EA44B5;
    address public constant USDF_MINTER = 0xC271fc70dD9E678ac1AB632f797894fe4BE2C345;
    address public constant USDT        = 0x55d398326f99059fF775485246999027B3197955;

    address public constant ASBNB        = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6;
    address public constant ASBNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8;
    address public constant SLISBNB      = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;

    address public constant ASUSDF        = 0x917AF46B3C3c6e1Bb7286B9F59637Fb7C65851Fb;
    address public constant ASUSDF_MINTER = 0xdB57a53C428a9faFcbFefFB6dd80d0f427543695;

    enum Asset { USDF, ASBNB, ASUSDF }
    enum ActionType { DEPOSIT, WITHDRAW, REQUEST_WITHDRAW, CLAIM_WITHDRAW }

    struct EarnParams {
        ActionType actionType;
        Asset      asset;
        uint256    amount;
        uint256    mintRatio;
        uint256    minReceived;
        uint256    requestId;
        address    recipient;
    }

    struct EarnResult {
        uint256 amountIn;
        uint256 amountOut;
        uint256 exchangeRate;
        uint256 requestId;
    }

    event Deposited(Asset indexed asset, uint256 amountIn, uint256 yieldOut, address indexed recipient);
    event Withdrawn(Asset indexed asset, uint256 yieldIn, uint256 underlyingOut, address indexed recipient);
    event WithdrawRequested(Asset indexed asset, uint256 yieldIn, address indexed requester);
    event WithdrawClaimed(Asset indexed asset, uint256 requestId, uint256 underlyingOut, address indexed recipient);

    function execute(address /* vault */, bytes calldata params)
        external
        returns (bool success, bytes memory result)
    {
        EarnParams memory p = abi.decode(params, (EarnParams));
        _validateParams(p);

        EarnResult memory res;

        if (p.actionType == ActionType.DEPOSIT) {
            res = _deposit(p);
        } else if (p.actionType == ActionType.WITHDRAW) {
            res = _withdraw(p);
        } else if (p.actionType == ActionType.REQUEST_WITHDRAW) {
            res = _requestWithdraw(p);
        } else {
            res = _claimWithdraw(p);
        }

        return (true, abi.encode(res));
    }

    function _validateParams(EarnParams memory p) internal pure {
        require(uint8(p.asset) <= 2, "Invalid asset");
        require(p.recipient != address(0), "Invalid recipient");
        if (p.actionType != ActionType.CLAIM_WITHDRAW) {
            require(p.amount > 0, "Amount must be > 0");
        }
    }

    function _deposit(EarnParams memory p) internal returns (EarnResult memory result) {
        if (p.asset == Asset.ASBNB) {
            return _depositSmartMint(p);
        } else {
            return _depositSimple(p);
        }
    }

    function _depositSmartMint(EarnParams memory p) internal returns (EarnResult memory result) {
        uint256 mintRatio  = _resolveMintRatio(ASBNB_MINTER, p.mintRatio);
        uint256 estimated  = IMinterAster(ASBNB_MINTER).estimateTotalOut(p.amount, mintRatio);
        uint256 minOut     = p.minReceived > 0 ? p.minReceived : (estimated * 99) / 100;

        IERC20(SLISBNB).forceApprove(ASBNB_MINTER, p.amount);
        uint256 received = IMinterAster(ASBNB_MINTER).smartMint(p.amount, mintRatio, minOut);
        IERC20(SLISBNB).forceApprove(ASBNB_MINTER, 0);

        IERC20(ASBNB).safeTransfer(p.recipient, received);

        result.amountIn    = p.amount;
        result.amountOut   = received;
        result.exchangeRate = _getExchangeRate(Asset.ASBNB);

        emit Deposited(Asset.ASBNB, p.amount, received, p.recipient);
    }

    function _depositSimple(EarnParams memory p) internal returns (EarnResult memory result) {
        address minter     = _getMinter(p.asset);
        address underlying = _getUnderlying(p.asset);
        address yieldToken = _getYieldToken(p.asset);

        uint256 yieldBefore = IERC20(yieldToken).balanceOf(address(this));
        IERC20(underlying).forceApprove(minter, p.amount);
        ISimpleEarn(minter).deposit(p.amount);
        IERC20(underlying).forceApprove(minter, 0);

        uint256 yieldAfter = IERC20(yieldToken).balanceOf(address(this));
        uint256 received   = yieldAfter - yieldBefore;

        if (p.minReceived > 0) {
            require(received >= p.minReceived, "Slippage: received less than minimum");
        }

        IERC20(yieldToken).safeTransfer(p.recipient, received);

        result.amountIn    = p.amount;
        result.amountOut   = received;
        result.exchangeRate = _getExchangeRate(p.asset);

        emit Deposited(p.asset, p.amount, received, p.recipient);
    }

    function _withdraw(EarnParams memory p) internal returns (EarnResult memory result) {
        require(p.asset == Asset.ASBNB, "WITHDRAW only for asBNB");

        IERC20(ASBNB).forceApprove(ASBNB_MINTER, p.amount);
        uint256 slisbnbBefore = IERC20(SLISBNB).balanceOf(address(this));
        IMinterAster(ASBNB_MINTER).withdraw(p.amount);
        uint256 received = IERC20(SLISBNB).balanceOf(address(this)) - slisbnbBefore;
        IERC20(ASBNB).forceApprove(ASBNB_MINTER, 0);

        if (p.minReceived > 0) {
            require(received >= p.minReceived, "Slippage: received less than minimum");
        }

        IERC20(SLISBNB).safeTransfer(p.recipient, received);

        result.amountIn    = p.amount;
        result.amountOut   = received;
        result.exchangeRate = _getExchangeRate(Asset.ASBNB);

        emit Withdrawn(Asset.ASBNB, p.amount, received, p.recipient);
    }

    function _requestWithdraw(EarnParams memory p) internal returns (EarnResult memory result) {
        address minter    = _getMinter(p.asset);
        address yieldToken = _getYieldToken(p.asset);

        IERC20(yieldToken).forceApprove(minter, p.amount);
        ISimpleEarn(minter).requestWithdraw(p.amount);
        IERC20(yieldToken).forceApprove(minter, 0);

        result.amountIn    = p.amount;
        result.exchangeRate = _getExchangeRate(p.asset);

        emit WithdrawRequested(p.asset, p.amount, p.recipient);
    }

    function _claimWithdraw(EarnParams memory p) internal returns (EarnResult memory result) {
        address minter     = _getMinter(p.asset);
        address underlying = _getUnderlying(p.asset);

        uint256 underlyingBefore = IERC20(underlying).balanceOf(address(this));

        uint256[] memory ids = new uint256[](1);
        ids[0] = p.requestId;
        ISimpleEarn(minter).claimWithdraw(ids);

        uint256 received = IERC20(underlying).balanceOf(address(this)) - underlyingBefore;

        if (p.minReceived > 0) {
            require(received >= p.minReceived, "Slippage: received less than minimum");
        }

        if (received > 0) {
            IERC20(underlying).safeTransfer(p.recipient, received);
        }

        result.amountOut   = received;
        result.requestId   = p.requestId;
        result.exchangeRate = _getExchangeRate(p.asset);

        emit WithdrawClaimed(p.asset, p.requestId, received, p.recipient);
    }

    function _getExchangeRate(Asset asset) internal view returns (uint256) {
        address minter = _getMinter(asset);

        if (asset == Asset.ASBNB) {
            try IMinterAster(minter).convertToTokens(1e18) returns (uint256 rate) {
                return rate;
            } catch {
                return 1e18;
            }
        } else {
            try ISimpleEarn(minter).exchangePrice() returns (uint256 price) {
                return price;
            } catch {
                return 1e18;
            }
        }
    }

    function _resolveMintRatio(address minter, uint256 mintRatio) internal view returns (uint256) {
        if (mintRatio != 0) return mintRatio;

        try IMinterAster(minter).maxSwapRatio() returns (uint256 maxSwap) {
            uint256 minSwap = IMinterAster(minter).minSwapRatio();
            uint256 minMint = DENOMINATOR - maxSwap;
            uint256 maxMint = DENOMINATOR - minSwap;
            return (minMint + maxMint) / 2;
        } catch {
            return DENOMINATOR;
        }
    }

    function _getMinter(Asset asset) internal pure returns (address) {
        if (asset == Asset.USDF)  return USDF_MINTER;
        if (asset == Asset.ASBNB) return ASBNB_MINTER;
        return ASUSDF_MINTER;
    }

    function _getYieldToken(Asset asset) internal pure returns (address) {
        if (asset == Asset.USDF)  return USDF;
        if (asset == Asset.ASBNB) return ASBNB;
        return ASUSDF;
    }

    function _getUnderlying(Asset asset) internal pure returns (address) {
        if (asset == Asset.USDF)  return USDT;
        if (asset == Asset.ASBNB) return SLISBNB;
        return USDF;
    }

    function getExchangeRate(Asset asset) external view returns (uint256) {
        return _getExchangeRate(asset);
    }
}
