// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../libraries/VaultMath.sol";

/// @title MetaVault
/// @notice Autonomous ERC4626 yield vault for BSC. Issues MYV (MetaYield Vault) shares.
/// @dev No owner. No admin keys. No pause. Fully immutable.
///      Performance fees use a high watermark to prevent charging fees on
///      recovery after drawdowns — only genuine new profits are taxed.
///      Built for the BNB Chain Good Vibes Only Hackathon.
contract MetaVault is ERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants ───────────────────────────────────────────────────────────
    /// @notice USDT on BSC mainnet
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    /// @notice Minimum deposit to prevent dust attacks
    uint256 public constant MIN_DEPOSIT = 1e18; // 1 USDT

    /// @notice Performance fee in basis points (10% of yield)
    uint256 public constant PERFORMANCE_FEE_BPS = 1000;

    // ─── Immutables ──────────────────────────────────────────────────────────
    /// @notice EngineCore contract - only address allowed to record harvests
    address public immutable engineCore;

    /// @notice StrategyRouter contract - holds vault's capital
    address public immutable strategyRouter;

    // ─── State ───────────────────────────────────────────────────────────────
    /// @notice Total assets at last harvest (for profit calculation)
    uint256 public lastHarvestAssets;

    /// @notice High watermark — the highest total assets ever recorded per share
    /// @dev Fees are only charged when total assets exceed this watermark.
    ///      Prevents double-charging fees on recovery after drawdowns.
    uint256 public highWatermark;

    /// @notice Total yield harvested lifetime
    uint256 public totalYieldHarvested;

    /// @notice Last harvest timestamp
    uint256 public lastHarvestTime;

    /// @notice Current annualized APY in basis points (rolling estimate)
    uint256 public currentAPYBps;

    // ─── Events ──────────────────────────────────────────────────────────────
    event FeeCompounded(uint256 profit, uint256 feeShares, uint256 timestamp);
    event APYUpdated(uint256 apyBps, uint256 timestamp);
    event HarvestRecorded(uint256 totalAssets, uint256 timestamp);
    event HighWatermarkUpdated(uint256 newWatermark, uint256 timestamp);

    // ─── Constructor ─────────────────────────────────────────────────────────
    constructor(
        address _engineCore,
        address _strategyRouter
    )
        ERC4626(IERC20(USDT))
        ERC20("MetaYield BSC Vault", "MYV")
    {
        require(_engineCore != address(0), "MetaVault: zero engine");
        require(_strategyRouter != address(0), "MetaVault: zero router");

        engineCore = _engineCore;
        strategyRouter = _strategyRouter;
        lastHarvestTime = block.timestamp;
    }

    // ─── ERC4626 Overrides ───────────────────────────────────────────────────

    /// @notice Total assets managed by vault (in StrategyRouter)
    function totalAssets() public view override returns (uint256) {
        // Query StrategyRouter for total managed assets
        (bool success, bytes memory data) = strategyRouter.staticcall(
            abi.encodeWithSignature("totalManagedAssets()")
        );
        if (!success || data.length == 0) {
            return IERC20(asset()).balanceOf(address(this));
        }
        return abi.decode(data, (uint256));
    }

    /// @notice Deposit USDT, receive MYV shares
    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant returns (uint256 shares) {
        require(assets >= MIN_DEPOSIT, "MetaVault: below min");
        require(receiver != address(0), "MetaVault: zero receiver");

        shares = super.deposit(assets, receiver);

        // Transfer deposited assets to StrategyRouter for deployment
        IERC20(asset()).safeTransfer(strategyRouter, assets);
    }

    /// @notice Mint exact MYV shares
    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant returns (uint256 assets) {
        require(receiver != address(0), "MetaVault: zero receiver");

        assets = super.mint(shares, receiver);

        // Transfer to StrategyRouter
        IERC20(asset()).safeTransfer(strategyRouter, assets);
    }

    /// @notice Withdraw USDT by burning MYV shares
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 shares) {
        require(receiver != address(0), "MetaVault: zero receiver");

        // Request withdrawal from StrategyRouter
        (bool success, ) = strategyRouter.call(
            abi.encodeWithSignature("withdrawAssets(uint256,address)", assets, address(this))
        );
        require(success, "MetaVault: withdraw failed");

        shares = super.withdraw(assets, receiver, owner);
    }

    /// @notice Redeem MYV shares for USDT
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 assets) {
        require(receiver != address(0), "MetaVault: zero receiver");

        assets = convertToAssets(shares);

        // Request withdrawal from StrategyRouter
        (bool success, ) = strategyRouter.call(
            abi.encodeWithSignature("withdrawAssets(uint256,address)", assets, address(this))
        );
        require(success, "MetaVault: redeem failed");

        assets = super.redeem(shares, receiver, owner);
    }

    // ─── Harvest Recording ───────────────────────────────────────────────────

    /// @notice Record harvest results from EngineCore
    /// @dev Only callable by EngineCore after a yield cycle.
    ///      Uses high watermark: fees only charged on NEW all-time-high profits.
    /// @param newTotalAssets Updated total assets after harvest
    function recordHarvest(uint256 newTotalAssets) external {
        require(msg.sender == engineCore, "MetaVault: only engine");

        // Only charge fees on profit above the high watermark
        uint256 profit = 0;
        if (newTotalAssets > highWatermark) {
            profit = newTotalAssets - highWatermark;
            highWatermark = newTotalAssets;
            emit HighWatermarkUpdated(newTotalAssets, block.timestamp);
        }

        if (profit > 0) {
            uint256 supply = totalSupply();
            uint256 feeShares = VaultMath.calcPerformanceFeeShares(
                profit,
                PERFORMANCE_FEE_BPS,
                lastHarvestAssets > 0 ? lastHarvestAssets : newTotalAssets,
                supply
            );

            if (feeShares > 0) {
                // Mint fee shares to vault itself (auto-compound)
                _mint(address(this), feeShares);
                emit FeeCompounded(profit, feeShares, block.timestamp);
            }

            // Update APY
            uint256 period = block.timestamp - lastHarvestTime;
            if (period > 0 && lastHarvestAssets > 0) {
                currentAPYBps = VaultMath.computeAPY(profit, lastHarvestAssets, period);
                emit APYUpdated(currentAPYBps, block.timestamp);
            }

            totalYieldHarvested += profit;
        }

        lastHarvestAssets = newTotalAssets;
        lastHarvestTime = block.timestamp;
        emit HarvestRecorded(newTotalAssets, block.timestamp);
    }

    // ─── View Functions ──────────────────────────────────────────────────────

    /// @notice Current share price (USDT per MYV)
    function sharePrice() external view returns (uint256) {
        return VaultMath.sharePrice(totalAssets(), totalSupply());
    }

    /// @notice Get user position
    function userPosition(address user) external view returns (uint256 shares, uint256 assets) {
        shares = balanceOf(user);
        assets = convertToAssets(shares);
    }

    /// @notice Total value locked
    function tvl() external view returns (uint256) {
        return totalAssets();
    }
}
