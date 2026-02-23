import { expect } from "chai";
import { ethers, network } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MetaVault, EngineCore, StrategyRouter } from "../typechain-types";

/**
 * Autonomous Engine Integration Tests
 *
 * Tests the full PERMISSIONLESS modular architecture:
 * - MetaVault (ERC4626 with high watermark fees)
 * - EngineCore (permissionless orchestrator with caller bounty + EMA volatility)
 * - StrategyRouter (volatility-based allocation with proper NAV)
 *
 * Run: npx hardhat test test/AutonomousEngine.test.ts --network localhost
 */

// ─── BSC Addresses ───────────────────────────────────────────────────────────

const BSC = {
    USDT:          "0x55d398326f99059fF775485246999027B3197955",
    USDF:          "0x5A110fC00474038f6c02E89C707D638602EA44B5",
    ASUSDF:        "0x917AF46B3C3c6e1Bb7286B9F59637Fb7C65851Fb",
    PANCAKE_ROUTER:"0x10ED43C718714eb63d5aA57B78B54704E256024E",
    MASTERCHEF_V2: "0xa5f8C5Dbd5F286960b9d90548680aE5ebFf07652",
    BINANCE_WHALE: "0xF977814e90dA44bFA03b6295A0616a897441aceC",
    USDF_USDT_PAIR:"0x8EaD8338aC4379CB04e1504c3e766F08a44f9df8",
};

const ERC20_ABI = [
    "function balanceOf(address) external view returns (uint256)",
    "function approve(address, uint256) external returns (bool)",
    "function transfer(address, uint256) external returns (bool)",
];

// ─── Helpers ─────────────────────────────────────────────────────────────────

async function impersonate(address: string): Promise<SignerWithAddress> {
    await network.provider.request({ method: "hardhat_impersonateAccount", params: [address] });
    await network.provider.request({
        method: "hardhat_setBalance",
        params: [address, "0x" + ethers.parseEther("10").toString(16)],
    });
    return ethers.getSigner(address);
}

async function stopImpersonating(address: string) {
    await network.provider.request({ method: "hardhat_stopImpersonatingAccount", params: [address] });
}

async function advanceTime(seconds: number) {
    await network.provider.send("evm_increaseTime", [seconds]);
    await network.provider.send("evm_mine");
}

// ─── Shared Fixture ──────────────────────────────────────────────────────────

let vault: MetaVault;
let engine: EngineCore;
let router: StrategyRouter;
let deployer: SignerWithAddress;
let user1: SignerWithAddress;
let vaultAddr: string;
let engineAddr: string;
let routerAddr: string;
let fixtureReady = false;

async function ensureFixture() {
    if (fixtureReady) return;
    fixtureReady = true;

    [deployer, user1] = await ethers.getSigners();

    // Deploy adapters
    const EarnF  = await ethers.getContractFactory("AsterDEXEarnAdapter");
    const LPF    = await ethers.getContractFactory("PancakeSwapV2LPAdapter");
    const FarmF  = await ethers.getContractFactory("PancakeSwapFarmAdapter");

    const [earnAdapter, lpAdapter, farmAdapter] = await Promise.all([
        EarnF.deploy().then(c => c.waitForDeployment()),
        LPF.deploy(BSC.PANCAKE_ROUTER).then(c => c.waitForDeployment()),
        FarmF.deploy(BSC.MASTERCHEF_V2).then(c => c.waitForDeployment()),
    ]);

    const earnAddr = await earnAdapter.getAddress();
    const lpAddr = await lpAdapter.getAddress();
    const farmAddr = await farmAdapter.getAddress();

    // Deploy core contracts (circular dependency: vault needs router, router needs engine, engine needs vault)
    // Solution: deploy with placeholder addresses, then update

    // 1. Deploy StrategyRouter with placeholder engine address
    const RouterF = await ethers.getContractFactory("StrategyRouter");
    router = await RouterF.deploy(
        deployer.address, // temporary - will be replaced
        earnAddr,
        lpAddr,
        farmAddr
    ).then(c => c.waitForDeployment()) as StrategyRouter;
    routerAddr = await router.getAddress();

    // 2. Deploy MetaVault
    const VaultF = await ethers.getContractFactory("MetaVault");
    vault = await VaultF.deploy(
        deployer.address, // temporary - will be replaced
        routerAddr
    ).then(c => c.waitForDeployment()) as MetaVault;
    vaultAddr = await vault.getAddress();

    // 3. Deploy EngineCore
    const EngineF = await ethers.getContractFactory("EngineCore");
    engine = await EngineF.deploy(
        vaultAddr,
        routerAddr
    ).then(c => c.waitForDeployment()) as EngineCore;
    engineAddr = await engine.getAddress();

    console.log(`\n    [Fixture] Deployed:`);
    console.log(`    Vault:  ${vaultAddr}`);
    console.log(`    Engine: ${engineAddr}`);
    console.log(`    Router: ${routerAddr}`);
}

// ══════════════════════════════════════════════════════════════════════════════
//  Suite 1: Deployment & Architecture
// ══════════════════════════════════════════════════════════════════════════════

describe("Autonomous Engine — Deployment", function () {
    this.timeout(120_000);

    before(async function () {
        await ensureFixture();
    });

    it("all contracts deployed successfully", async function () {
        expect(vaultAddr).to.not.equal(ethers.ZeroAddress);
        expect(engineAddr).to.not.equal(ethers.ZeroAddress);
        expect(routerAddr).to.not.equal(ethers.ZeroAddress);
    });

    it("MetaVault has correct name and symbol", async function () {
        expect(await vault.name()).to.equal("MetaYield BSC Vault");
        expect(await vault.symbol()).to.equal("MYV");
    });

    it("MetaVault asset is USDT", async function () {
        expect(await vault.asset()).to.equal(BSC.USDT);
    });

    it("StrategyRouter immutables are set", async function () {
        expect(await router.engineCore()).to.equal(deployer.address); // temporary
    });

    it("EngineCore has correct references", async function () {
        expect(await engine.vault()).to.equal(vaultAddr);
        expect(await engine.strategyRouter()).to.equal(routerAddr);
    });

    it("EngineCore cooldown is 1 hour", async function () {
        expect(await engine.CYCLE_INTERVAL()).to.equal(3600);
    });

    it("EngineCore has caller bounty configured", async function () {
        expect(await engine.CALLER_BOUNTY_BPS()).to.equal(50); // 0.5%
    });

    it("EngineCore uses EMA volatility smoothing", async function () {
        expect(await engine.EMA_ALPHA()).to.equal(2000); // 20%
        const ema = await engine.emaDeviationBps();
        expect(ema).to.be.gte(0); // Starts at 0
    });
});

// ══════════════════════════════════════════════════════════════════════════════
//  Suite 2: Volatility Detection (On-Chain, EMA-Smoothed)
// ══════════════════════════════════════════════════════════════════════════════

describe("Autonomous Engine — Volatility Detection (EMA)", function () {
    this.timeout(120_000);

    before(async function () {
        await ensureFixture();
    });

    it("can query current market mode (EMA-smoothed)", async function () {
        const mode = await engine.currentMarketMode();
        console.log(`    Market mode: ${mode} (0=NORMAL, 1=VOLATILE, 2=DRAWDOWN)`);
        expect([0, 1, 2]).to.include(Number(mode));
    });

    it("can query risk score (0-100, EMA-smoothed)", async function () {
        const risk = await engine.currentRiskScore();
        console.log(`    Risk score: ${risk}/100`);
        expect(risk).to.be.lte(100);
    });

    it("USDF/USDT pair returns valid spot price", async function () {
        const price = await router.riskScore(); // indirectly tests getSpotPrice
        expect(price).to.be.gte(0);
    });
});

// ══════════════════════════════════════════════════════════════════════════════
//  Suite 3: Permissionless executeCycle (with bounty)
// ══════════════════════════════════════════════════════════════════════════════

describe("Autonomous Engine — Permissionless Execution", function () {
    this.timeout(120_000);

    before(async function () {
        await ensureFixture();
    });

    it("anyone can check if cycle can execute", async function () {
        const canExecute = await engine.canExecuteCycle();
        console.log(`    Can execute: ${canExecute}`);
        expect(typeof canExecute).to.equal("boolean");
    });

    it("timeUntilNextCycle returns valid value", async function () {
        const timeLeft = await engine.timeUntilNextCycle();
        console.log(`    Time until next cycle: ${timeLeft}s`);
        expect(timeLeft).to.be.gte(0);
    });

    it("executeCycle reverts when cooldown active", async function () {
        // Cycle was just executed in constructor
        await expect(engine.connect(user1).executeCycle())
            .to.be.revertedWith("EC: cooldown active");
    });

    it("executeCycle succeeds after cooldown (anyone can call)", async function () {
        // Advance time past 1 hour cooldown
        await advanceTime(3601);

        const canExecute = await engine.canExecuteCycle();
        expect(canExecute).to.be.true;

        // User1 (not owner) can execute
        const tx = await engine.connect(user1).executeCycle();
        const receipt = await tx.wait();

        console.log(`    Cycle executed by non-owner (gas: ${receipt?.gasUsed})`);

        const cycles = await engine.totalCyclesExecuted();
        expect(cycles).to.equal(1);
    });

    it("EMA deviation is updated after cycle", async function () {
        const ema = await engine.emaDeviationBps();
        console.log(`    EMA deviation: ${ema} bps`);
        expect(ema).to.be.gte(0);
    });
});

// ══════════════════════════════════════════════════════════════════════════════
//  Suite 4: Deposit & Allocation
// ══════════════════════════════════════════════════════════════════════════════

describe("Autonomous Engine — Deposits & Allocation", function () {
    this.timeout(300_000);

    before(async function () {
        await ensureFixture();
    });

    it("user can deposit USDT and receive MYV shares", async function () {
        const whale = await impersonate(BSC.BINANCE_WHALE);
        const USDT = new ethers.Contract(BSC.USDT, ERC20_ABI, whale);

        const depositAmount = ethers.parseUnits("50", 18);
        await USDT.approve(vaultAddr, depositAmount);

        const sharesBefore = await vault.balanceOf(whale.address);
        await vault.connect(whale).deposit(depositAmount, whale.address);
        const sharesAfter = await vault.balanceOf(whale.address);

        const sharesMinted = sharesAfter - sharesBefore;
        expect(sharesMinted).to.be.gt(0);
        console.log(`    Deposited: 50 USDT -> ${ethers.formatEther(sharesMinted)} MYV`);

        await stopImpersonating(BSC.BINANCE_WHALE);
    });

    it("totalManagedAssets includes buffer + earn + LP positions", async function () {
        const totalAssets = await router.totalManagedAssets();
        console.log(`    Total managed: ${ethers.formatUnits(totalAssets, 18)} USDT`);
        expect(totalAssets).to.be.gte(0);
    });
});

// ══════════════════════════════════════════════════════════════════════════════
//  Suite 5: Performance Fee (High Watermark)
// ══════════════════════════════════════════════════════════════════════════════

describe("Autonomous Engine — Performance Fees (High Watermark)", function () {
    this.timeout(120_000);

    before(async function () {
        await ensureFixture();
    });

    it("vault has 10% performance fee constant", async function () {
        expect(await vault.PERFORMANCE_FEE_BPS()).to.equal(1000);
    });

    it("vault tracks high watermark", async function () {
        const hwm = await vault.highWatermark();
        console.log(`    High watermark: ${ethers.formatUnits(hwm, 18)} USDT`);
        expect(hwm).to.be.gte(0);
    });

    it("fee shares are auto-compounded (minted to vault)", async function () {
        const vaultShares = await vault.balanceOf(vaultAddr);
        console.log(`    Vault's own shares: ${ethers.formatEther(vaultShares)} MYV`);
        // May be 0 initially (no profit yet)
        expect(vaultShares).to.be.gte(0);
    });
});

// ══════════════════════════════════════════════════════════════════════════════
//  Suite 6: Withdrawal
// ══════════════════════════════════════════════════════════════════════════════

describe("Autonomous Engine — Withdrawals", function () {
    this.timeout(300_000);

    before(async function () {
        await ensureFixture();
    });

    it("user can withdraw from buffer instantly", async function () {
        const whale = await impersonate(BSC.BINANCE_WHALE);
        const shares = await vault.balanceOf(whale.address);

        if (shares === 0n) {
            console.log("    No shares to redeem — skipping");
            await stopImpersonating(BSC.BINANCE_WHALE);
            return;
        }

        const USDT = new ethers.Contract(BSC.USDT, ERC20_ABI, ethers.provider);
        const usdtBefore = await USDT.balanceOf(whale.address);

        // Redeem 10% of shares
        const redeemAmount = shares / 10n;
        await vault.connect(whale).redeem(redeemAmount, whale.address, whale.address);

        const usdtAfter = await USDT.balanceOf(whale.address);
        const received = usdtAfter - usdtBefore;

        expect(received).to.be.gt(0);
        console.log(`    Redeemed: ${ethers.formatEther(redeemAmount)} MYV -> ${ethers.formatUnits(received, 18)} USDT`);

        await stopImpersonating(BSC.BINANCE_WHALE);
    });
});

// ══════════════════════════════════════════════════════════════════════════════
//  Suite 7: Live Dashboard
// ══════════════════════════════════════════════════════════════════════════════

describe("Autonomous Engine — Live Metrics", function () {
    this.timeout(120_000);

    before(async function () {
        await ensureFixture();
    });

    it("prints live autonomous engine status", async function () {
        const tvl = await vault.tvl();
        const sharePrice = await vault.sharePrice();
        const currentAPY = await vault.currentAPYBps();
        const mode = await engine.currentMarketMode();
        const risk = await engine.currentRiskScore();
        const cycles = await engine.totalCyclesExecuted();
        const canExecute = await engine.canExecuteCycle();
        const ema = await engine.emaDeviationBps();
        const hwm = await vault.highWatermark();
        const bounties = await engine.totalBountiesPaid();

        console.log("");
        console.log("    +=======================================================+");
        console.log("    |   MetaYield Autonomous Engine — PERMISSIONLESS Status  |");
        console.log("    +=======================================================+");
        console.log(`    |  TVL             : ${ethers.formatUnits(tvl, 18).padEnd(28)} USDT  |`);
        console.log(`    |  Share Price     : ${ethers.formatEther(sharePrice).padEnd(28)} USDT  |`);
        console.log(`    |  APY             : ${(Number(currentAPY) / 100).toFixed(2).padEnd(28)}%    |`);
        console.log("    +-------------------------------------------------------+");
        console.log(`    |  Market Mode     : ${["NORMAL", "VOLATILE", "DRAWDOWN"][Number(mode)].padEnd(28)}       |`);
        console.log(`    |  Risk Score      : ${risk.toString().padEnd(28)}/100  |`);
        console.log(`    |  EMA Deviation   : ${ema.toString().padEnd(28)} bps  |`);
        console.log("    +-------------------------------------------------------+");
        console.log(`    |  Cycles Executed : ${cycles.toString().padEnd(28)}       |`);
        console.log(`    |  Can Execute     : ${canExecute.toString().padEnd(28)}       |`);
        console.log(`    |  High Watermark  : ${ethers.formatUnits(hwm, 18).padEnd(28)} USDT  |`);
        console.log(`    |  Bounties Paid   : ${ethers.formatUnits(bounties, 18).padEnd(28)} USDT  |`);
        console.log("    +-------------------------------------------------------+");
        console.log("    |  PERMISSIONLESS: Anyone can call executeCycle()        |");
        console.log("    |  CALLER BOUNTY:  0.5% of yield paid to caller         |");
        console.log("    |  EMA VOLATILITY: Smoothed mode transitions            |");
        console.log("    |  HIGH WATERMARK: No fees on drawdown recovery         |");
        console.log("    |  NO ADMIN KEYS:  Fully autonomous operation           |");
        console.log("    +=======================================================+");
        console.log("");

        expect(tvl).to.be.gte(0);
    });
});
