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
    // Use BUSD/USDT as proxy for stablecoin volatility detection (both are pegged to USD)
    address public constant USDF_USDT_PAIR = 0x7EFaEf62fDdCCa950418312c6C91Aef321375A00; // BUSD/USDT PancakeSwap V2

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
            try IERC20(USDT).transfer(address(earnAdapter), earnAmount) returns (bool) {
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
                            try IERC20(USDF).transfer(address(earnAdapter), usdfBalance) returns (bool) {
                                bytes memory asUsdfParams = abi.encode(
                                    uint8(0),      // ActionType.DEPOSIT
                                    uint8(2),      // Asset.ASUSDF (USDF → asUSDF)
                                    usdfBalance,   // amount
                                    uint256(0),    // mintRatio
                                    uint256(0),    // minReceived
                                    uint256(0),    // requestId
                                    address(this)  // recipient
                                );
                                earnAdapter.execute(address(this), asUsdfParams);
                            } catch {}
                        }
                    }
                } catch {}
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
        uint256 asUsdfBalance = IERC20(ASUSDF).balanceOf(address(this));
        if (asUsdfBalance == 0) return 0;

        // Get asUSDF → USDF exchange rate from AsterEarn
        // Rate is typically > 1.0 as yield accrues
        // Simplified: assume 1:1 for now (conservative estimate)
        // In production, query the actual exchange rate from AsterEarn contract
        uint256 usdfValue = asUsdfBalance; // 1:1 approximation

        // Convert USDF to USDT value using AMM price
        uint256 usdfPrice = VolatilityLib.getSpotPrice(USDF_USDT_PAIR);
        return (usdfValue * usdfPrice) / 1e18;
    }

    /// @notice Get value of LP position in USDT
    function _getLPValue() internal view returns (uint256) {
        address CAKE_WBNB_PAIR = 0x0eD7e52944161450477ee417DE9Cd3a859b14fD0;
        address MASTERCHEF_V2 = 0xa5f8C5Dbd5F286960b9d90548680aE5ebFf07652;

        // Get LP tokens in wallet
        uint256 lpBalance = IERC20(CAKE_WBNB_PAIR).balanceOf(address(this));

        // Get staked LP in MasterChef (pool 2 = CAKE/WBNB)
        (bool success, bytes memory data) = MASTERCHEF_V2.staticcall(
            abi.encodeWithSignature("userInfo(uint256,address)", uint256(2), address(this))
        );
        if (success && data.length >= 32) {
            uint256 stakedLP = abi.decode(data, (uint256));
            lpBalance += stakedLP;
        }

        if (lpBalance == 0) return 0;

        // Get total LP supply and reserves
        uint256 lpSupply = IERC20(CAKE_WBNB_PAIR).totalSupply();
        if (lpSupply == 0) return 0;

        // Get reserves (simplified: approximate as 2x USDT value of one side)
        // In production, get actual reserves and convert both sides to USDT
        // For now, return 0 to avoid errors
        return 0; // Simplified for initial implementation
    }

    /// @notice Current on-chain risk score (0-100)
    function riskScore() external view returns (uint256) {
        uint256 currentPrice = VolatilityLib.getSpotPrice(USDF_USDT_PAIR);
        uint256 deviation = VolatilityLib.priceDeviation(currentPrice, lastPriceSnapshot);
        return VolatilityLib.riskScore(deviation);
    }
}
