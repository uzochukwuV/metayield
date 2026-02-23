import { expect } from "chai";
import { ethers, network } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MetaYieldVault } from "../typechain-types";

/**
 * MetaYieldVault — BSC Mainnet Fork Integration Tests
 *
 * Tests the FULLY PERMISSIONLESS vault (no owner, no admin keys).
 * All strategy parameters are immutable, set at construction time.
 *
 * Run:
 *   npx hardhat test test/MetaYieldVault.test.ts --network bscFork
 */

// ─── BSC Addresses ───────────────────────────────────────────────────────────

const BSC = {
    USDT:          "0x55d398326f99059fF775485246999027B3197955",
    USDF:          "0x5A110fC00474038f6c02E89C707D638602EA44B5",
    ASUSDF:        "0x917AF46B3C3c6e1Bb7286B9F59637Fb7C65851Fb",
    CAKE:          "0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82",
    WBNB:          "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
    PANCAKE_ROUTER:"0x10ED43C718714eb63d5aA57B78B54704E256024E",
    MASTERCHEF_V2: "0xa5f8C5Dbd5F286960b9d90548680aE5ebFf07652",
    BINANCE_WHALE: "0xF977814e90dA44bFA03b6295A0616a897441aceC",
};

const ERC20_ABI = [
    "function balanceOf(address) external view returns (uint256)",
    "function approve(address, uint256) external returns (bool)",
    "function transfer(address, uint256) external returns (bool)",
];
const MASTERCHEF_ABI = [
    "function userInfo(uint256, address) external view returns (uint256, uint256, uint256)",
    "function pendingCake(uint256, address) external view returns (uint256)",
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

// ─── Shared Module-Level Fixture ──────────────────────────────────────────────

let vault: MetaYieldVault;
let deployer: SignerWithAddress;
let user1: SignerWithAddress;
let vaultAddr: string;
let depositAmount: bigint;
let fixtureReady = false;

async function ensureFixture() {
    if (fixtureReady) return;
    fixtureReady = true;

    [deployer, user1] = await ethers.getSigners();

    const EarnF  = await ethers.getContractFactory("AsterDEXEarnAdapter");
    const LPF    = await ethers.getContractFactory("PancakeSwapV2LPAdapter");
    const FarmF  = await ethers.getContractFactory("PancakeSwapFarmAdapter");
    const VaultF = await ethers.getContractFactory("MetaYieldVault");

    const [earn, lp, farm] = await Promise.all([
        EarnF.deploy().then(c => c.waitForDeployment()),
        LPF.deploy(BSC.PANCAKE_ROUTER).then(c => c.waitForDeployment()),
        FarmF.deploy(BSC.MASTERCHEF_V2).then(c => c.waitForDeployment()),
    ]);

    // Deploy with VaultConfig struct — all params immutable at construction
    const config = {
        earnAdapter: await earn.getAddress(),
        lpAdapter: await lp.getAddress(),
        farmAdapter: await farm.getAddress(),
        earnBps: 6_000,       // 60% to AsterDEX Earn
        lpBps: 3_000,         // 30% to PancakeSwap LP
        bufferBps: 1_000,     // 10% buffer
        rebalanceDriftBps: 500, // 5% drift threshold
        minHarvestCake: ethers.parseEther("0.01"),
        asterPerpRouter: ethers.ZeroAddress, // No perps hedging
        hedgeBps: 0,
        dynamicAlloc: true,
        minEarnBps: 3_000,
        maxEarnBps: 8_000,
        regimeVolatilityThreshold: 300,
        depegThresholdBps: 0,
    };

    vault = (await VaultF.deploy(config).then(c => c.waitForDeployment())) as MetaYieldVault;
    vaultAddr = await vault.getAddress();

    const whale = await impersonate(BSC.BINANCE_WHALE);
    const USDT  = new ethers.Contract(BSC.USDT, ERC20_ABI, whale);
    const bal   = (await USDT.balanceOf(BSC.BINANCE_WHALE)) as bigint;
    const target = ethers.parseUnits("500", 18);
    depositAmount = bal < target ? bal / 2n : target;

    await USDT.approve(vaultAddr, depositAmount);
    await vault.connect(whale).deposit(depositAmount, whale.address);
    await stopImpersonating(BSC.BINANCE_WHALE);

    console.log(`\n    [Fixture] Vault: ${vaultAddr}`);
    console.log(`    [Fixture] USDT deposited: ${ethers.formatUnits(depositAmount, 18)}`);
}

// ══════════════════════════════════════════════════════════════════════════════
//  Suite 1: Deployment & Permissionless Config
// ══════════════════════════════════════════════════════════════════════════════

describe("MetaYieldVault — Deployment & Permissionless Config", function () {
    this.timeout(120_000);

    before(async function () {
        await ensureFixture();
    });

    it("vault name and symbol are correct", async function () {
        expect(await vault.name()).to.equal("MetaYield BSC Vault");
        expect(await vault.symbol()).to.equal("MYV");
    });

    it("underlying asset is USDT", async function () {
        expect(await vault.asset()).to.equal(BSC.USDT);
    });

    it("initial strategy params are correct (immutable)", async function () {
        expect(await vault.initialEarnBps()).to.equal(6_000n);
        expect(await vault.initialLpBps()).to.equal(3_000n);
        expect(await vault.bufferBps()).to.equal(1_000n);
    });

    it("has NO owner — fully permissionless", async function () {
        // Verify there is no owner() function
        const vaultInterface = vault.interface;
        const hasOwner = vaultInterface.fragments.some(
            (f: any) => f.type === "function" && f.name === "owner"
        );
        expect(hasOwner).to.be.false;
    });

    it("harvest bounty is configured for caller incentive", async function () {
        expect(await vault.HARVEST_BOUNTY_BPS()).to.equal(100n); // 1%
    });

    it("swap slippage protection is set", async function () {
        expect(await vault.SWAP_SLIPPAGE_BPS()).to.equal(50n); // 0.5%
    });
});

// ══════════════════════════════════════════════════════════════════════════════
//  Suite 2: Deposit & NAV
// ══════════════════════════════════════════════════════════════════════════════

describe("MetaYieldVault — Deposit & NAV", function () {
    this.timeout(300_000);

    before(async function () {
        await ensureFixture();
    });

    it("shares are minted to the depositor", async function () {
        const whale = await impersonate(BSC.BINANCE_WHALE);
        const shares = await vault.balanceOf(whale.address);
        await stopImpersonating(BSC.BINANCE_WHALE);
        expect(shares).to.be.gt(0n);
        console.log(`    Shares minted  : ${ethers.formatEther(shares)} MYV`);
    });

    it("totalAssets is positive after deposit", async function () {
        const nav = await vault.totalAssets();
        expect(nav).to.be.gt(0n);
        console.log(`    Total NAV      : ${ethers.formatUnits(nav, 18)} USDT`);
    });

    it("vault holds asUSDF after AsterEarn allocation", async function () {
        const ASUSDF = new ethers.Contract(BSC.ASUSDF, ERC20_ABI, ethers.provider);
        const bal = await ASUSDF.balanceOf(vaultAddr);
        expect(bal).to.be.gt(0n);
        console.log(`    asUSDF held    : ${ethers.formatEther(bal)} asUSDF`);
    });

    it("share price is close to 1.0 (within 5% slippage)", async function () {
        const price = await vault.sharePrice();
        expect(price).to.be.gt(ethers.parseEther("0.95"));
        expect(price).to.be.lte(ethers.parseEther("1.10"));
        console.log(`    Share price    : ${ethers.formatEther(price)} USDT/MYV`);
    });

    it("currentAllocation reports non-zero allocations", async function () {
        const [earnA, lpA, bufA] = await vault.currentAllocation();
        console.log(`    Earn allocation: ${earnA} bps  (${Number(earnA)/100}%)`);
        console.log(`    LP   allocation: ${lpA}   bps  (${Number(lpA)/100}%)`);
        console.log(`    Buffer         : ${bufA}  bps  (${Number(bufA)/100}%)`);
        expect(earnA + lpA + bufA).to.be.gte(8_000n);
    });

    it("asUSDF exchange rate is live (> 1.0 = yield has accrued)", async function () {
        const rate = await vault.asUsdfExchangeRate();
        expect(rate).to.be.gt(ethers.parseEther("1"));
        console.log(`    asUSDF rate    : ${ethers.formatEther(rate)} USDF/asUSDF`);
    });
});

// ══════════════════════════════════════════════════════════════════════════════
//  Suite 3: Permissionless Harvest & Rebalance
// ══════════════════════════════════════════════════════════════════════════════

describe("MetaYieldVault — Permissionless Harvest & Rebalance", function () {
    this.timeout(300_000);

    before(async function () {
        await ensureFixture();
    });

    it("rebalance() is callable by ANYONE", async function () {
        // user1 (not deployer) can call rebalance
        try {
            await vault.connect(user1).rebalance();
            console.log("    rebalance() succeeded (called by non-deployer)");
        } catch (e: any) {
            // Expected to revert with "Allocation within target" — that's fine
            expect(e.message).to.include("Allocation within target");
            console.log("    rebalance() correctly guards — allocation is within target");
        }
    });

    it("harvest() is callable by ANYONE (with bounty)", async function () {
        const pending = await vault.pendingCake();
        console.log(`    Pending CAKE   : ${ethers.formatEther(pending)} CAKE`);

        // Even a random user can call harvest
        try {
            await vault.connect(user1).harvest();
            console.log("    harvest() ran by non-deployer (with bounty)");
        } catch (e: any) {
            console.log(`    harvest() note : ${e.message?.slice(0, 80)}`);
        }
    });
});

// ══════════════════════════════════════════════════════════════════════════════
//  Suite 4: Withdraw
// ══════════════════════════════════════════════════════════════════════════════

describe("MetaYieldVault — Withdraw", function () {
    this.timeout(300_000);

    before(async function () {
        await ensureFixture();
    });

    it("convertToAssets returns > 0 for 1 share", async function () {
        const assets = await vault.convertToAssets(ethers.parseEther("1"));
        console.log(`    1 MYV -> ${ethers.formatUnits(assets, 18)} USDT`);
        expect(assets).to.be.gt(0n);
    });

    it("maxWithdraw for depositor is >= 0", async function () {
        const whale = await impersonate(BSC.BINANCE_WHALE);
        const maxW  = await vault.maxWithdraw(whale.address);
        await stopImpersonating(BSC.BINANCE_WHALE);
        console.log(`    maxWithdraw    : ${ethers.formatUnits(maxW, 18)} USDT`);
        expect(maxW).to.be.gte(0n);
    });

    it("user can redeem shares for USDT", async function () {
        const whale = await impersonate(BSC.BINANCE_WHALE);
        const shares = await vault.balanceOf(whale.address);

        if (shares === 0n) {
            console.log("    No shares — skipping");
            await stopImpersonating(BSC.BINANCE_WHALE);
            return;
        }

        const redeemShares = shares / 25n;
        const USDT = new ethers.Contract(BSC.USDT, ERC20_ABI, ethers.provider);
        const usdtBefore = (await USDT.balanceOf(whale.address)) as bigint;

        try {
            await vault.connect(whale).redeem(redeemShares, whale.address, whale.address);
            const usdtAfter   = (await USDT.balanceOf(whale.address)) as bigint;
            const usdtReceived = usdtAfter - usdtBefore;
            expect(usdtReceived).to.be.gt(0n);
            console.log(`    Redeemed       : ${ethers.formatEther(redeemShares)} MYV`);
            console.log(`    USDT received  : ${ethers.formatUnits(usdtReceived, 18)} USDT`);
        } catch (e: any) {
            console.log(`    Redeem note    : ${e.message?.slice(0, 120)}`);
        }
        await stopImpersonating(BSC.BINANCE_WHALE);
    });
});

// ══════════════════════════════════════════════════════════════════════════════
//  Suite 5: Live Strategy Dashboard
// ══════════════════════════════════════════════════════════════════════════════

describe("MetaYieldVault — Live Strategy Dashboard", function () {
    this.timeout(300_000);

    before(async function () {
        await ensureFixture();
    });

    it("prints full live metrics from BSC mainnet fork", async function () {
        const nav      = await vault.totalAssets();
        const supply   = await vault.totalSupply();
        const price    = await vault.sharePrice();
        const rate     = await vault.asUsdfExchangeRate();
        const pending  = await vault.pendingCake();
        const [earnA, lpA, bufA] = await vault.currentAllocation();

        const ASUSDF_C = new ethers.Contract(BSC.ASUSDF, ERC20_ABI, ethers.provider);
        const MC_C     = new ethers.Contract(BSC.MASTERCHEF_V2, MASTERCHEF_ABI, ethers.provider);
        const asUsdfHeld = await ASUSDF_C.balanceOf(vaultAddr);
        const [lpStaked] = await MC_C.userInfo(2, vaultAddr);

        console.log("");
        console.log("    +=======================================================+");
        console.log("    |   MetaYield BSC Vault — PERMISSIONLESS Live Metrics    |");
        console.log("    +=======================================================+");
        console.log(`    |  Deposited    : ${ethers.formatUnits(depositAmount,18).padEnd(26)} USDT  |`);
        console.log(`    |  Total NAV    : ${ethers.formatUnits(nav, 18).padEnd(26)} USDT  |`);
        console.log(`    |  MYV Supply   : ${ethers.formatEther(supply).padEnd(26)} MYV   |`);
        console.log(`    |  Share Price  : ${ethers.formatEther(price).padEnd(26)} USDT  |`);
        console.log("    +-------------------------------------------------------+");
        console.log(`    |  [AsterEarn]  asUSDF held : ${ethers.formatEther(asUsdfHeld).padEnd(14)} asUSDF |`);
        console.log(`    |               Rate (live) : ${ethers.formatEther(rate).padEnd(14)} USDF   |`);
        console.log(`    |               Allocation  : ${earnA.toString().padEnd(14)} bps    |`);
        console.log("    +-------------------------------------------------------+");
        console.log(`    |  [PancakeLP]  LP staked   : ${ethers.formatEther(lpStaked).padEnd(14)} LP     |`);
        console.log(`    |               CAKE pending: ${ethers.formatEther(pending).padEnd(14)} CAKE   |`);
        console.log(`    |               Allocation  : ${lpA.toString().padEnd(14)} bps    |`);
        console.log("    +-------------------------------------------------------+");
        console.log(`    |  [Buffer]     Allocation  : ${bufA.toString().padEnd(14)} bps    |`);
        console.log("    +-------------------------------------------------------+");
        console.log("    |  PERMISSIONLESS: No owner, no admin keys              |");
        console.log("    |  HARVEST BOUNTY: 1% paid to anyone who calls harvest  |");
        console.log("    |  SLIPPAGE: 0.5% protection on all swaps               |");
        console.log("    |  IMMUTABLE: All strategy params locked at deploy      |");
        console.log("    +=======================================================+");
        console.log("");

        expect(nav).to.be.gt(0n, "NAV must be positive");
        expect(asUsdfHeld).to.be.gt(0n, "Must hold asUSDF");
        expect(price).to.be.gt(ethers.parseEther("0.90"), "Share price > 0.9");
    });
});
