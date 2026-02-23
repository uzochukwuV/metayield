// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IAsterPerp.sol";

// ─── External Protocol Interfaces ────────────────────────────────────────────

interface IPancakeRouter02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external view returns (uint256[] memory amounts);
}

interface IPancakePair {
    function totalSupply() external view returns (uint256);
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32 ts);
}

interface IMasterChefV2View {
    function userInfo(uint256 pid, address user)
        external view returns (uint256 amount, uint256 rewardDebt, uint256 boostMultiplier);
    function lpToken(uint256 pid) external view returns (address);
    function pendingCake(uint256 pid, address user) external view returns (uint256);
}

interface ISimpleEarnView {
    function exchangePrice() external view returns (uint256);
}

// ─── Adapter call interface (minimal) ────────────────────────────────────────

interface IAdapter {
    function execute(address vault, bytes calldata params)
        external returns (bool success, bytes memory result);
}

/**
 * @title MetaYieldVault
 * @notice Self-Driving Yield Engine — FULLY PERMISSIONLESS ERC4626 vault that
 *         autonomously orchestrates three stacked yield strategies on BNB Chain.
 *
 *   Layer 1 (Primary — 60%): AsterDEX Earn
 *     USDT → USDF_MINTER → USDF → ASUSDF_MINTER → asUSDF
 *     Base yield: 6–9% from asUSDF exchange-price appreciation.
 *
 *   Layer 2 (Secondary — 40%): PancakeSwap CAKE/WBNB LP + MasterChef farm
 *     USDT → swap to CAKE + WBNB → add liquidity → stake in pool 2
 *     Yield: LP trading fees + CAKE farm emissions.
 *
 *   Layer 3 (Hedge — optional, immutable config): Aster Perps delta-neutral short
 *     asUSDF collateral → short BNB on Aster Perps (Hedge Mode)
 *     Protects LP position from IL during BNB drawdowns.
 *
 * Autonomous operations (permissionless — anyone can call):
 *   harvest()    — Claim CAKE from farm, swap → USDT, compound back.
 *                  Caller receives HARVEST_BOUNTY_BPS of harvested value.
 *   rebalance()  — Re-align allocation to targets when drift > rebalanceDriftBps.
 *
 * FULLY PERMISSIONLESS:
 *   - NO owner. NO admin keys. NO Ownable. NO pause.
 *   - All strategy parameters are IMMUTABLE (set at construction).
 *   - Dynamic allocation adjusts autonomously based on on-chain APR tracking.
 *   - Regime switching is fully deterministic from on-chain BNB price.
 *   - Harvest bounty incentivizes callers without any centralized keeper.
 *
 * @dev Built for the BNB Chain Good Vibes Only Hackathon.
 */
contract MetaYieldVault is ERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Regime Enum ============

    /// @notice Operating regime that determines allocation bias.
    enum Regime {
        NORMAL,     // APR-proportional allocation (default)
        DEFENSIVE,  // High volatility detected — shift toward stable earn yield
        AGGRESSIVE  // Low volatility + LP outperforms — amplify LP allocation
    }

    // ============ BSC Mainnet Constants ============

    address public constant USDT          = 0x55d398326f99059fF775485246999027B3197955;
    address public constant USDF          = 0x5A110fC00474038f6c02E89C707D638602EA44B5;
    address public constant ASUSDF        = 0x917AF46B3C3c6e1Bb7286B9F59637Fb7C65851Fb;
    address public constant CAKE          = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address public constant WBNB          = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    address public constant USDF_MINTER   = 0xC271fc70dD9E678ac1AB632f797894fe4BE2C345;
    address public constant ASUSDF_MINTER = 0xdB57a53C428a9faFcbFefFB6dd80d0f427543695;

    address public constant PANCAKE_ROUTER   = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant MASTERCHEF_V2    = 0xa5f8C5Dbd5F286960b9d90548680aE5ebFf07652;
    uint256 public constant CAKE_WBNB_POOL   = 2;

    uint256 public constant MAX_BPS = 10_000;

    /// @notice Estimated gas units for a full harvest call.
    uint256 public constant HARVEST_GAS_ESTIMATE = 350_000;

    /// @notice Harvest only when CAKE value >= HARVEST_SAFETY_FACTOR% of estimated gas cost.
    uint256 public constant HARVEST_SAFETY_FACTOR = 300;

    /// @notice Bounty paid to harvest() caller in bps of harvested USDT (1%)
    uint256 public constant HARVEST_BOUNTY_BPS = 100;

    /// @notice Minimum slippage protection for swaps (0.5%)
    uint256 public constant SWAP_SLIPPAGE_BPS = 50;

    // Adapter action constants
    uint8 private constant EARN_DEPOSIT          = 0;
    uint8 private constant EARN_REQUEST_WITHDRAW = 2;
    uint8 private constant EARN_CLAIM_WITHDRAW   = 3;
    uint8 private constant EARN_ASSET_USDF       = 0;
    uint8 private constant EARN_ASSET_ASUSDF     = 2;

    uint8 private constant LP_ADD_LIQUIDITY    = 0;
    uint8 private constant LP_REMOVE_LIQUIDITY = 2;

    uint8 private constant FARM_DEPOSIT  = 0;
    uint8 private constant FARM_WITHDRAW = 1;
    uint8 private constant FARM_HARVEST  = 2;

    // ============ Adapters (immutable) ============

    address public immutable earnAdapter;
    address public immutable lpAdapter;
    address public immutable farmAdapter;

    // ============ Strategy Configuration (immutable) ============

    /// @notice Target earn allocation in basis points
    uint256 public immutable initialEarnBps;
    /// @notice Target LP allocation in basis points
    uint256 public immutable initialLpBps;
    /// @notice Buffer allocation in basis points
    uint256 public immutable bufferBps;
    /// @notice Rebalance drift threshold in basis points
    uint256 public immutable rebalanceDriftBps;
    /// @notice Minimum CAKE for harvest to proceed
    uint256 public immutable minHarvestCake;

    // ============ Hedge Configuration (immutable) ============

    address public immutable asterPerpRouter;
    uint256 public immutable hedgeBps;

    // ============ Dynamic Allocation (immutable bounds) ============

    bool   public immutable dynamicAlloc;
    uint256 public immutable minEarnBps;
    uint256 public immutable maxEarnBps;

    // ============ Regime Config (immutable) ============

    uint256 public immutable regimeVolatilityThreshold;
    uint256 public immutable depegThresholdBps;

    // ============ Dynamic Allocation State ============

    uint256 public earnBps;
    uint256 public lpBps;
    uint256 public earnAprBps;
    uint256 public lpAprBps;

    uint256 private _lastAsUsdfRate;
    uint256 private _lastRateTimestamp;
    uint256 private _lastCakeUsdtValue;
    uint256 private _lastHarvestTimestamp;
    uint256 private _lastLpValueUsdt;

    // ============ Regime State ============

    Regime public currentRegime;
    uint256 public lastBnbPrice;
    uint256 public lastPriceTimestamp;

    // ============ Hedge Tracking ============

    bytes32 public openHedgeKey;
    uint256 public hedgeCollateralUsdt;

    // ============ State Tracking ============

    uint256 public totalCakeHarvested;
    uint256 public totalBountiesPaid;
    mapping(address => uint256) public pendingWithdrawRequest;
    mapping(address => uint256) public pendingWithdrawShares;

    // ============ Events ============

    event StrategyAllocated(uint256 earnAmt, uint256 lpAmt, uint256 buffer);
    event Harvested(uint256 cakeAmount, uint256 usdtCompounded, address indexed caller, uint256 bounty);
    event EarnSkippedDepeg(uint256 usdtHeld, uint256 rateObserved);
    event Rebalanced(uint256 earnBpsActual, uint256 timestamp);
    event WithdrawRequested(address indexed user, uint256 shares, uint256 asUsdfAmount);
    event WithdrawClaimed(address indexed user, uint256 usdtReceived);
    event HedgeOpened(bytes32 indexed tradeHash, uint256 collateralUsdt, uint80 qty);
    event HedgeClosed(bytes32 indexed tradeHash);
    event AllocationAutoAdjusted(uint256 newEarnBps, uint256 newLpBps, uint256 earnAprBps, uint256 lpAprBps);
    event RegimeSwitched(Regime indexed newRegime, uint256 volatilityBps);
    event AutoHarvested(uint256 cakeAmount, uint256 usdtCompounded);

    // ============ Constructor ============

    struct VaultConfig {
        address earnAdapter;
        address lpAdapter;
        address farmAdapter;
        uint256 earnBps;
        uint256 lpBps;
        uint256 bufferBps;
        uint256 rebalanceDriftBps;
        uint256 minHarvestCake;
        address asterPerpRouter;
        uint256 hedgeBps;
        bool    dynamicAlloc;
        uint256 minEarnBps;
        uint256 maxEarnBps;
        uint256 regimeVolatilityThreshold;
        uint256 depegThresholdBps;
    }

    constructor(VaultConfig memory cfg)
        ERC4626(IERC20(USDT))
        ERC20("MetaYield BSC Vault", "MYV")
    {
        require(cfg.earnAdapter  != address(0), "Invalid earnAdapter");
        require(cfg.lpAdapter    != address(0), "Invalid lpAdapter");
        require(cfg.farmAdapter  != address(0), "Invalid farmAdapter");
        require(cfg.earnBps + cfg.lpBps + cfg.bufferBps == MAX_BPS, "Must sum to 10000");
        require(cfg.rebalanceDriftBps >= 50 && cfg.rebalanceDriftBps <= 2_000, "Drift: 0.5%-20%");
        require(cfg.hedgeBps <= 5_000, "Hedge cannot exceed 50%");
        if (cfg.dynamicAlloc) {
            require(cfg.minEarnBps < cfg.maxEarnBps, "Invalid bounds");
            require(cfg.maxEarnBps + cfg.bufferBps <= MAX_BPS, "Bounds overflow buffer");
        }

        earnAdapter  = cfg.earnAdapter;
        lpAdapter    = cfg.lpAdapter;
        farmAdapter  = cfg.farmAdapter;

        initialEarnBps = cfg.earnBps;
        initialLpBps   = cfg.lpBps;
        bufferBps      = cfg.bufferBps;
        rebalanceDriftBps = cfg.rebalanceDriftBps;
        minHarvestCake = cfg.minHarvestCake;

        asterPerpRouter = cfg.asterPerpRouter;
        hedgeBps        = cfg.hedgeBps;

        dynamicAlloc = cfg.dynamicAlloc;
        minEarnBps   = cfg.dynamicAlloc ? cfg.minEarnBps : cfg.earnBps;
        maxEarnBps   = cfg.dynamicAlloc ? cfg.maxEarnBps : cfg.earnBps;

        regimeVolatilityThreshold = cfg.regimeVolatilityThreshold > 0 ? cfg.regimeVolatilityThreshold : 300;
        depegThresholdBps = cfg.depegThresholdBps;

        // Initialize mutable allocation state
        earnBps = cfg.earnBps;
        lpBps   = cfg.lpBps;
    }

    // ============ ERC4626 Override: NAV ============

    function totalAssets() public view override returns (uint256) {
        uint256 cash        = IERC20(USDT).balanceOf(address(this));
        uint256 earnValue   = _asUsdfValueInUsdt();
        uint256 lpValue     = _lpValueInUsdt();
        return cash + earnValue + lpValue;
    }

    // ============ ERC4626 Override: Deposit Hook ============

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        super._deposit(caller, receiver, assets, shares);
        _maybeHarvest();
        _updateRegime();
        _allocate(assets);
    }

    // ============ ERC4626 Override: Withdraw Hook ============

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        _updateRegime();
        _ensureLiquidity(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ============ Autonomous: Harvest (permissionless, with bounty) ============

    /// @notice Harvest CAKE rewards, compound into strategy, pay bounty to caller
    /// @dev Anyone can call. Caller receives HARVEST_BOUNTY_BPS of harvested USDT.
    function harvest() external nonReentrant {
        bytes memory farmParams = _encodeFarmAction(FARM_HARVEST, CAKE_WBNB_POOL, 0, address(this));
        IAdapter(farmAdapter).execute(address(this), farmParams);

        uint256 cakeBalance = IERC20(CAKE).balanceOf(address(this));
        require(cakeBalance >= minHarvestCake, "Nothing to harvest");

        uint256 usdtReceived = _swapToUsdt(CAKE, cakeBalance);
        if (usdtReceived == 0) revert("Swap produced no USDT");

        // Pay bounty to caller before compounding
        uint256 bounty = (usdtReceived * HARVEST_BOUNTY_BPS) / MAX_BPS;
        if (bounty > 0) {
            IERC20(USDT).safeTransfer(msg.sender, bounty);
            totalBountiesPaid += bounty;
            usdtReceived -= bounty;
        }

        totalCakeHarvested += cakeBalance;
        _allocate(usdtReceived);
        _updateAprTracking(usdtReceived);
        _autoAdjustAllocation();

        emit Harvested(cakeBalance, usdtReceived, msg.sender, bounty);
    }

    // ============ Autonomous: Rebalance (permissionless) ============

    function rebalance() external nonReentrant {
        uint256 nav = totalAssets();
        require(nav > 0, "Empty vault");

        uint256 earnValue = _asUsdfValueInUsdt();
        uint256 currentEarnBps = (earnValue * MAX_BPS) / nav;
        (uint256 targetEarnBps,) = _computeTargetAlloc();

        uint256 drift = currentEarnBps > targetEarnBps
            ? currentEarnBps - targetEarnBps
            : targetEarnBps - currentEarnBps;

        require(drift >= rebalanceDriftBps, "Allocation within target");

        if (currentEarnBps > targetEarnBps) {
            uint256 excessValue = ((currentEarnBps - targetEarnBps) * nav) / MAX_BPS;
            uint256 asUsdfToExit = _usdtToAsUsdf(excessValue);
            if (asUsdfToExit > 0) {
                _exitAsUsdfToUsdt(asUsdfToExit);
                uint256 recoveredUsdt = IERC20(USDT).balanceOf(address(this));
                if (recoveredUsdt > 0) _allocateToLP(recoveredUsdt);
            }
        } else {
            uint256 excessValue = ((targetEarnBps - currentEarnBps) * nav) / MAX_BPS;
            _unwindLP(excessValue);
            uint256 recoveredUsdt = IERC20(USDT).balanceOf(address(this));
            if (recoveredUsdt > 0) _allocateToEarn(recoveredUsdt);
        }

        emit Rebalanced(currentEarnBps, block.timestamp);
    }

    receive() external payable {}

    // ============ View Helpers ============

    function sharePrice() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        return (totalAssets() * 1e18) / supply;
    }

    function currentAllocation()
        external view
        returns (uint256 earnAlloc, uint256 lpAlloc, uint256 bufferAlloc)
    {
        uint256 nav = totalAssets();
        if (nav == 0) return (0, 0, 0);
        earnAlloc   = (_asUsdfValueInUsdt() * MAX_BPS) / nav;
        lpAlloc     = (_lpValueInUsdt()     * MAX_BPS) / nav;
        bufferAlloc = (IERC20(USDT).balanceOf(address(this)) * MAX_BPS) / nav;
    }

    function asUsdfExchangeRate() external view returns (uint256) {
        try ISimpleEarnView(ASUSDF_MINTER).exchangePrice() returns (uint256 p) {
            return p;
        } catch {
            return 1e18;
        }
    }

    function pendingCake() external view returns (uint256) {
        return IMasterChefV2View(MASTERCHEF_V2).pendingCake(CAKE_WBNB_POOL, address(this));
    }

    function shouldHarvest() public view returns (bool) {
        return _shouldHarvest();
    }

    // ============ Internal: Capital Allocation ============

    function _allocate(uint256 usdtAmount) internal {
        if (usdtAmount == 0) return;

        uint256 bufferAmt  = (usdtAmount * bufferBps) / MAX_BPS;
        uint256 toAllocate = usdtAmount - bufferAmt;

        (uint256 targetEarnBps_, uint256 targetLpBps_) = _computeTargetAlloc();
        uint256 total   = targetEarnBps_ + targetLpBps_;
        uint256 earnAmt = total > 0 ? (toAllocate * targetEarnBps_) / total : toAllocate;
        uint256 lpAmt   = toAllocate - earnAmt;

        if (earnAmt > 0) _allocateToEarn(earnAmt);
        if (lpAmt   > 0) _allocateToLP(lpAmt);

        emit StrategyAllocated(earnAmt, lpAmt, bufferAmt);
    }

    function _isUsdFDepegged() internal view returns (bool) {
        if (depegThresholdBps == 0) return false;

        uint256 usdfPrice = _getAmountOut(1 ether, USDF, USDT);
        if (usdfPrice == 0) return false;

        uint256 floor = 1e18 - (depegThresholdBps * 1e18 / MAX_BPS);
        return usdfPrice < floor;
    }

    function _allocateToEarn(uint256 usdtAmount) internal {
        if (_isUsdFDepegged()) {
            uint256 rate;
            try ISimpleEarnView(ASUSDF_MINTER).exchangePrice() returns (uint256 r) { rate = r; } catch {}
            emit EarnSkippedDepeg(usdtAmount, rate);
            return;
        }

        IERC20(USDT).safeTransfer(earnAdapter, usdtAmount);
        bytes memory p1 = _encodeEarnDeposit(EARN_ASSET_USDF, usdtAmount, address(this));
        (bool ok1,) = IAdapter(earnAdapter).execute(address(this), p1);
        if (!ok1) return;

        uint256 usdfBal = IERC20(USDF).balanceOf(address(this));
        if (usdfBal == 0) return;
        IERC20(USDF).safeTransfer(earnAdapter, usdfBal);
        bytes memory p2 = _encodeEarnDeposit(EARN_ASSET_ASUSDF, usdfBal, address(this));
        IAdapter(earnAdapter).execute(address(this), p2);

        if (hedgeBps > 0 && asterPerpRouter != address(0) && openHedgeKey == bytes32(0)) {
            uint256 hedgeUsdt = (usdtAmount * hedgeBps) / MAX_BPS;
            if (hedgeUsdt > 0) _openHedge(hedgeUsdt);
        }
    }

    function _allocateToLP(uint256 usdtAmount) internal {
        if (usdtAmount == 0) return;

        uint256 half = usdtAmount / 2;
        uint256 rest = usdtAmount - half;

        uint256 cakeReceived = _swapFromUsdt(CAKE, half);
        uint256 wbnbReceived = _swapFromUsdt(WBNB, rest);

        if (cakeReceived == 0 || wbnbReceived == 0) return;

        IERC20(CAKE).safeTransfer(lpAdapter, cakeReceived);
        IERC20(WBNB).safeTransfer(lpAdapter, wbnbReceived);

        bytes memory lpParams = _encodeLPAdd(CAKE, WBNB, cakeReceived, wbnbReceived, address(this));
        (bool lpOk,) = IAdapter(lpAdapter).execute(address(this), lpParams);
        if (!lpOk) return;

        address lpTokenAddr = IMasterChefV2View(MASTERCHEF_V2).lpToken(CAKE_WBNB_POOL);
        uint256 lpBal = IERC20(lpTokenAddr).balanceOf(address(this));
        if (lpBal == 0) return;

        IERC20(lpTokenAddr).safeTransfer(farmAdapter, lpBal);
        bytes memory farmParams = _encodeFarmAction(FARM_DEPOSIT, CAKE_WBNB_POOL, lpBal, address(this));
        IAdapter(farmAdapter).execute(address(this), farmParams);
    }

    // ============ Internal: Position Exit ============

    function _ensureLiquidity(uint256 usdtNeeded) internal {
        uint256 cashHeld = IERC20(USDT).balanceOf(address(this));
        if (cashHeld >= usdtNeeded) return;

        uint256 shortfall = usdtNeeded - cashHeld;

        uint256 lpVal = _lpValueInUsdt();
        if (lpVal > 0) {
            uint256 toUnwind = shortfall > lpVal ? lpVal : shortfall;
            _unwindLP(toUnwind);
            cashHeld = IERC20(USDT).balanceOf(address(this));
            if (cashHeld >= usdtNeeded) return;
        }

        require(IERC20(USDT).balanceOf(address(this)) >= usdtNeeded,
            "Insufficient liquidity: use requestVaultWithdraw for large exits");
    }

    function _unwindLP(uint256 targetUsdt) internal {
        (uint256 lpStaked,,) = IMasterChefV2View(MASTERCHEF_V2).userInfo(CAKE_WBNB_POOL, address(this));
        if (lpStaked == 0) return;

        address lpTokenAddr = IMasterChefV2View(MASTERCHEF_V2).lpToken(CAKE_WBNB_POOL);
        uint256 lpTotalSupply = IERC20(lpTokenAddr).totalSupply();
        if (lpTotalSupply == 0) return;

        uint256 lpValue = _lpValueInUsdt();
        uint256 lpToWithdraw = lpValue > 0
            ? (lpStaked * targetUsdt) / lpValue
            : lpStaked;
        if (lpToWithdraw > lpStaked) lpToWithdraw = lpStaked;

        bytes memory farmParams = _encodeFarmAction(FARM_WITHDRAW, CAKE_WBNB_POOL, lpToWithdraw, address(this));
        (bool ok,) = IAdapter(farmAdapter).execute(address(this), farmParams);
        if (!ok) return;

        uint256 lpBal = IERC20(lpTokenAddr).balanceOf(address(this));
        if (lpBal == 0) return;
        IERC20(lpTokenAddr).safeTransfer(lpAdapter, lpBal);
        bytes memory removeLPParams = _encodeLPRemove(CAKE, WBNB, lpBal, address(this));
        IAdapter(lpAdapter).execute(address(this), removeLPParams);

        uint256 cakeBal = IERC20(CAKE).balanceOf(address(this));
        if (cakeBal > 0) _swapToUsdt(CAKE, cakeBal);

        uint256 wbnbBal = IERC20(WBNB).balanceOf(address(this));
        if (wbnbBal > 0) _swapToUsdt(WBNB, wbnbBal);
    }

    function _exitAsUsdfToUsdt(uint256 asUsdfAmount) internal {
        uint256 asUsdfBal = IERC20(ASUSDF).balanceOf(address(this));
        if (asUsdfBal == 0 || asUsdfAmount == 0) return;
        if (asUsdfAmount > asUsdfBal) asUsdfAmount = asUsdfBal;

        IERC20(ASUSDF).safeTransfer(earnAdapter, asUsdfAmount);
        bytes memory req = _encodeEarnRequest(EARN_ASSET_ASUSDF, asUsdfAmount, address(this));
        IAdapter(earnAdapter).execute(address(this), req);

        uint256 usdfBal = IERC20(USDF).balanceOf(address(this));
        if (usdfBal > 0) _swapToUsdt(USDF, usdfBal);
    }

    // ============ Internal: NAV Calculation ============

    function _asUsdfValueInUsdt() internal view returns (uint256) {
        uint256 asUsdfBal = IERC20(ASUSDF).balanceOf(address(this));
        if (asUsdfBal == 0) return 0;
        try ISimpleEarnView(ASUSDF_MINTER).exchangePrice() returns (uint256 price) {
            return (asUsdfBal * price) / 1e18;
        } catch {
            return asUsdfBal;
        }
    }

    function _lpValueInUsdt() internal view returns (uint256) {
        (uint256 lpStaked,,) = IMasterChefV2View(MASTERCHEF_V2).userInfo(CAKE_WBNB_POOL, address(this));
        if (lpStaked == 0) return 0;

        address lpToken = IMasterChefV2View(MASTERCHEF_V2).lpToken(CAKE_WBNB_POOL);
        uint256 lpTotal = IERC20(lpToken).totalSupply();
        if (lpTotal == 0) return 0;

        (uint112 r0, uint112 r1,) = IPancakePair(lpToken).getReserves();
        address t0 = IPancakePair(lpToken).token0();

        uint256 ourCake = (uint256(t0 == CAKE ? r0 : r1) * lpStaked) / lpTotal;
        uint256 ourWbnb = (uint256(t0 == CAKE ? r1 : r0) * lpStaked) / lpTotal;

        uint256 usdtFromCake = _getAmountOut(ourCake, CAKE, USDT);
        uint256 usdtFromWbnb = _getAmountOut(ourWbnb, WBNB, USDT);
        return usdtFromCake + usdtFromWbnb;
    }

    function _usdtToAsUsdf(uint256 usdtAmount) internal view returns (uint256) {
        try ISimpleEarnView(ASUSDF_MINTER).exchangePrice() returns (uint256 price) {
            if (price == 0) return usdtAmount;
            return (usdtAmount * 1e18) / price;
        } catch {
            return usdtAmount;
        }
    }

    // ============ Internal: Swap Helpers (with slippage protection) ============

    function _swapFromUsdt(address toToken, uint256 usdtAmount) internal returns (uint256) {
        if (usdtAmount == 0) return 0;
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = toToken;

        // Get expected output for slippage calculation
        uint256 expectedOut = _getAmountOut(usdtAmount, USDT, toToken);
        uint256 minOut = (expectedOut * (MAX_BPS - SWAP_SLIPPAGE_BPS)) / MAX_BPS;

        IERC20(USDT).forceApprove(PANCAKE_ROUTER, usdtAmount);
        try IPancakeRouter02(PANCAKE_ROUTER).swapExactTokensForTokens(
            usdtAmount, minOut, path, address(this), block.timestamp + 300
        ) returns (uint256[] memory amounts) {
            IERC20(USDT).forceApprove(PANCAKE_ROUTER, 0);
            return amounts[amounts.length - 1];
        } catch {
            IERC20(USDT).forceApprove(PANCAKE_ROUTER, 0);
            return 0;
        }
    }

    function _swapToUsdt(address fromToken, uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        address[] memory path = new address[](2);
        path[0] = fromToken;
        path[1] = USDT;

        // Get expected output for slippage calculation
        uint256 expectedOut = _getAmountOut(amount, fromToken, USDT);
        uint256 minOut = (expectedOut * (MAX_BPS - SWAP_SLIPPAGE_BPS)) / MAX_BPS;

        IERC20(fromToken).forceApprove(PANCAKE_ROUTER, amount);
        try IPancakeRouter02(PANCAKE_ROUTER).swapExactTokensForTokens(
            amount, minOut, path, address(this), block.timestamp + 300
        ) returns (uint256[] memory amounts) {
            IERC20(fromToken).forceApprove(PANCAKE_ROUTER, 0);
            return amounts[amounts.length - 1];
        } catch {
            IERC20(fromToken).forceApprove(PANCAKE_ROUTER, 0);
            return 0;
        }
    }

    function _getAmountOut(uint256 amountIn, address fromToken, address toToken)
        internal view returns (uint256)
    {
        if (amountIn == 0) return 0;
        if (fromToken == toToken) return amountIn;
        address[] memory path = new address[](2);
        path[0] = fromToken;
        path[1] = toToken;
        try IPancakeRouter02(PANCAKE_ROUTER).getAmountsOut(amountIn, path)
            returns (uint256[] memory amounts)
        {
            return amounts[amounts.length - 1];
        } catch {
            return 0;
        }
    }

    // ============ Internal: ABI Encoding Helpers ============

    function _encodeEarnDeposit(uint8 asset, uint256 amount, address recipient)
        internal pure returns (bytes memory)
    {
        return abi.encode(
            uint8(EARN_DEPOSIT), asset, amount,
            uint256(0), uint256(0), uint256(0), recipient
        );
    }

    function _encodeEarnRequest(uint8 asset, uint256 amount, address recipient)
        internal pure returns (bytes memory)
    {
        return abi.encode(
            uint8(EARN_REQUEST_WITHDRAW), asset, amount,
            uint256(0), uint256(0), uint256(0), recipient
        );
    }

    function _encodeEarnClaim(uint8 asset, uint256 requestId, address recipient)
        internal pure returns (bytes memory)
    {
        return abi.encode(
            uint8(EARN_CLAIM_WITHDRAW), asset, uint256(0),
            uint256(0), uint256(0), requestId, recipient
        );
    }

    function _encodeLPAdd(
        address tokenA, address tokenB,
        uint256 amountA, uint256 amountB,
        address recipient
    ) internal pure returns (bytes memory) {
        return abi.encode(
            uint8(LP_ADD_LIQUIDITY),
            tokenA, tokenB,
            amountA, amountB,
            uint256(0), uint256(0),
            uint256(0),
            uint256(50),
            recipient
        );
    }

    function _encodeLPRemove(
        address tokenA, address tokenB,
        uint256 liquidity,
        address recipient
    ) internal pure returns (bytes memory) {
        return abi.encode(
            uint8(LP_REMOVE_LIQUIDITY),
            tokenA, tokenB,
            uint256(0), uint256(0),
            uint256(0), uint256(0),
            liquidity,
            uint256(50),
            recipient
        );
    }

    function _encodeFarmAction(
        uint8 action, uint256 poolId, uint256 amount, address recipient
    ) internal pure returns (bytes memory) {
        return abi.encode(
            action, poolId, amount,
            uint256(0),
            uint256(0),
            uint256(0),
            recipient
        );
    }

    // ============ Internal: APR Tracking ============

    function _updateAprTracking(uint256 cakeUsdtValue) internal {
        uint256 currentRate    = _getAsUsdfRate();
        uint256 currentLpVal   = _lpValueInUsdt();
        uint256 now_           = block.timestamp;

        if (_lastRateTimestamp > 0 && now_ > _lastRateTimestamp && currentRate > _lastAsUsdfRate) {
            uint256 elapsed = now_ - _lastRateTimestamp;
            earnAprBps = (currentRate - _lastAsUsdfRate) * 365 days * 10_000
                         / (_lastAsUsdfRate * elapsed);
        }

        if (_lastHarvestTimestamp > 0 && _lastLpValueUsdt > 0 && now_ > _lastHarvestTimestamp) {
            uint256 elapsed = now_ - _lastHarvestTimestamp;
            lpAprBps = cakeUsdtValue * 365 days * 10_000
                       / (_lastLpValueUsdt * elapsed);
        }

        _lastAsUsdfRate       = currentRate;
        _lastRateTimestamp    = now_;
        _lastCakeUsdtValue    = cakeUsdtValue;
        _lastHarvestTimestamp = now_;
        _lastLpValueUsdt      = currentLpVal;
    }

    function _autoAdjustAllocation() internal {
        if (!dynamicAlloc) return;
        if (earnAprBps == 0 && lpAprBps == 0) return;

        uint256 newEarnBps = earnBps;

        if (earnAprBps > lpAprBps + 100) {
            uint256 candidate = earnBps + 500;
            newEarnBps = candidate > maxEarnBps ? maxEarnBps : candidate;
        } else if (lpAprBps > earnAprBps + 100) {
            newEarnBps = earnBps > minEarnBps + 500 ? earnBps - 500 : minEarnBps;
        }

        if (newEarnBps != earnBps) {
            uint256 newLpBps = MAX_BPS - newEarnBps - bufferBps;
            earnBps = newEarnBps;
            lpBps   = newLpBps;
            emit AllocationAutoAdjusted(newEarnBps, newLpBps, earnAprBps, lpAprBps);
        }
    }

    // ============ Internal: Autonomous Strategy Kernel ============

    function _computeTargetAlloc()
        internal view
        returns (uint256 targetEarnBps, uint256 targetLpBps)
    {
        if (!dynamicAlloc || (earnAprBps == 0 && lpAprBps == 0)) {
            return (earnBps, lpBps);
        }

        uint256 available = MAX_BPS - bufferBps;
        uint256 totalApr  = earnAprBps + lpAprBps;

        if (currentRegime == Regime.DEFENSIVE) {
            targetEarnBps = (available * 80) / 100;
        } else if (currentRegime == Regime.AGGRESSIVE) {
            targetEarnBps = (available * 30) / 100;
        } else {
            targetEarnBps = (earnAprBps * available) / totalApr;
        }

        if (targetEarnBps < minEarnBps) targetEarnBps = minEarnBps;
        if (targetEarnBps > maxEarnBps) targetEarnBps = maxEarnBps;

        targetLpBps = available - targetEarnBps;
    }

    // ============ Internal: Embedded Hooks + Gas Scheduler ============

    function _maybeHarvest() internal {
        if (!_shouldHarvest()) return;

        bytes memory farmParams = _encodeFarmAction(FARM_HARVEST, CAKE_WBNB_POOL, 0, address(this));
        IAdapter(farmAdapter).execute(address(this), farmParams);

        uint256 cakeBalance = IERC20(CAKE).balanceOf(address(this));
        if (cakeBalance < minHarvestCake) return;

        uint256 usdtReceived = _swapToUsdt(CAKE, cakeBalance);
        if (usdtReceived == 0) return;

        totalCakeHarvested += cakeBalance;
        _allocate(usdtReceived);
        _updateAprTracking(usdtReceived);
        _autoAdjustAllocation();

        emit AutoHarvested(cakeBalance, usdtReceived);
    }

    function _shouldHarvest() internal view returns (bool) {
        uint256 pending = IMasterChefV2View(MASTERCHEF_V2).pendingCake(CAKE_WBNB_POOL, address(this));
        if (pending < minHarvestCake) return false;

        uint256 cakeValueUsdt = _getAmountOut(pending, CAKE, USDT);
        if (cakeValueUsdt == 0) return false;

        uint256 gasPrice    = block.basefee > 0 ? block.basefee + 1 gwei : 5 gwei;
        uint256 bnbCostWei  = gasPrice * HARVEST_GAS_ESTIMATE;
        uint256 bnbInUsdt   = _getAmountOut(1 ether, WBNB, USDT);
        if (bnbInUsdt == 0) return false;

        uint256 gasCostUsdt = (bnbCostWei * bnbInUsdt) / 1 ether;

        return cakeValueUsdt * 100 >= gasCostUsdt * HARVEST_SAFETY_FACTOR;
    }

    // ============ Internal: Defensive Regime Switching ============

    function _updateRegime() internal {
        uint256 currentBnbPrice = _getAmountOut(1 ether, WBNB, USDT);
        if (currentBnbPrice == 0) return;

        if (lastBnbPrice > 0) {
            uint256 delta = currentBnbPrice > lastBnbPrice
                ? currentBnbPrice - lastBnbPrice
                : lastBnbPrice - currentBnbPrice;

            uint256 volatilityBps = (delta * MAX_BPS) / lastBnbPrice;

            Regime newRegime = currentRegime;

            if (volatilityBps >= regimeVolatilityThreshold) {
                newRegime = Regime.DEFENSIVE;
            } else if (volatilityBps <= regimeVolatilityThreshold / 3) {
                newRegime = (lpAprBps > earnAprBps) ? Regime.AGGRESSIVE : Regime.NORMAL;
            }

            if (newRegime != currentRegime) {
                currentRegime = newRegime;
                emit RegimeSwitched(newRegime, volatilityBps);
            }
        }

        lastBnbPrice       = currentBnbPrice;
        lastPriceTimestamp = block.timestamp;
    }

    function _getAsUsdfRate() internal view returns (uint256) {
        try ISimpleEarnView(ASUSDF_MINTER).exchangePrice() returns (uint256 p) {
            return p;
        } catch {
            return 1e18;
        }
    }

    // ============ Internal: Perp Hedge ============

    function _openHedge(uint256 collateralUsdt) internal {
        if (collateralUsdt == 0) return;
        if (collateralUsdt > type(uint96).max) collateralUsdt = type(uint96).max;

        uint256 bnbPrice;
        {
            (bool ok, bytes memory priceData) = asterPerpRouter.staticcall(
                abi.encodeWithSignature("getPriceFromCacheOrOracle(address)", WBNB)
            );
            if (!ok || priceData.length < 32) return;
            bnbPrice = abi.decode(priceData, (uint256));
        }
        if (bnbPrice == 0) return;

        IAsterPerp perp = IAsterPerp(asterPerpRouter);

        uint256 qtyCalc = collateralUsdt / bnbPrice;
        if (qtyCalc == 0 || qtyCalc > type(uint80).max) return;

        IERC20(USDT).forceApprove(asterPerpRouter, collateralUsdt);

        IAsterPerp.OpenDataInput memory data = IAsterPerp.OpenDataInput({
            pairBase:   WBNB,
            isLong:     false,
            tokenIn:    USDT,
            amountIn:   uint96(collateralUsdt),
            qty:        uint80(qtyCalc),
            price:      0,
            stopLoss:   0,
            takeProfit: 0,
            broker:     0
        });

        try perp.openMarketTrade(data) returns (bytes32 key) {
            openHedgeKey        = key;
            hedgeCollateralUsdt = collateralUsdt;
            IERC20(USDT).forceApprove(asterPerpRouter, 0);
            emit HedgeOpened(key, collateralUsdt, uint80(qtyCalc));
        } catch {
            IERC20(USDT).forceApprove(asterPerpRouter, 0);
        }
    }

    function _closeHedge() internal {
        if (openHedgeKey == bytes32(0) || asterPerpRouter == address(0)) return;
        try IAsterPerp(asterPerpRouter).closeTrade(openHedgeKey) {
            emit HedgeClosed(openHedgeKey);
            openHedgeKey        = bytes32(0);
            hedgeCollateralUsdt = 0;
        } catch {
        }
    }
}
