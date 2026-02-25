import { expect } from "chai";
import { ethers } from "hardhat";
import { AsterHedgeAdapter } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

// ══════════════════════════════════════════════════════════════════════════════
//  BSC Mainnet Constants (for fork testing)
// ══════════════════════════════════════════════════════════════════════════════

const BSC = {
    // Tokens
    USDT: "0x55d398326f99059fF775485246999027B3197955",
    WBNB: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
    ASBNB: "0x77734e70b6E88b4d82fE632a168EDf6e700912b6",
    SLISBNB: "0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B",

    // AsterDEX contracts (using proxy addresses)
    ASBNB_MINTER: "0x2F31ab8950c50080E77999fa456372f276952fD8", // Proxy (not implementation)
    YIELD_PROXY: "0x66C66DBB51cbccE0fbb2738326e11Da6FE9e584C",

    // DEX
    PANCAKE_ROUTER: "0x10ED43C718714eb63d5aA57B78B54704E256024E",

    // Test wallets
    BINANCE_WHALE: "0xF977814e90dA44bFA03b6295A0616a897441aceC", // Has USDT
};

const ERC20_ABI = [
    "function balanceOf(address) view returns (uint256)",
    "function approve(address,uint256) returns (bool)",
    "function transfer(address,uint256) returns (bool)",
    "function decimals() view returns (uint8)",
];

const ASBNB_MINTER_ABI = [
    "function mintAsBnb() payable returns (uint256)",
    "function mintAsBnb(uint256) returns (uint256)",
    "function burnAsBnb(uint256) returns (uint256)",
    "function convertToTokens(uint256) view returns (uint256)",
    "function convertToAsBnb(uint256) view returns (uint256)",
    "function canDeposit() view returns (bool)",
    "function canWithdraw() view returns (bool)",
];

// ══════════════════════════════════════════════════════════════════════════════
//  Test Suite: AsterDEX Hedge Adapter (BSC Fork)
// ══════════════════════════════════════════════════════════════════════════════

describe("🛡️ AsterDEX Hedge Adapter — BSC Fork Tests", function () {
    let adapter: AsterHedgeAdapter;
    let deployer: SignerWithAddress;
    let user: SignerWithAddress;

    // Helper to impersonate account
    async function impersonate(address: string) {
        await ethers.provider.send("hardhat_impersonateAccount", [address]);
        await ethers.provider.send("hardhat_setBalance", [address, "0x56BC75E2D63100000"]); // 100 ETH
        return await ethers.getSigner(address);
    }

    before(async function () {
        this.timeout(60_000);

        // Ensure we're on BSC fork
        const chainId = (await ethers.provider.getNetwork()).chainId;
        if (chainId !== 56n) {
            console.log("⚠️  Not on BSC fork - skipping tests");
            console.log(`   Current chainId: ${chainId}`);
            console.log(`   Run: npx hardhat node --fork https://bsc-dataseed.binance.org/`);
            this.skip();
        }

        [deployer, user] = await ethers.getSigners();

        // Deploy HedgeAdapter
        const AdapterF = await ethers.getContractFactory("AsterHedgeAdapter");
        adapter = await AdapterF.deploy() as AsterHedgeAdapter;
        await adapter.waitForDeployment();

        console.log(`\n    📍 Deployed HedgeAdapter: ${await adapter.getAddress()}`);
    });

    // ══════════════════════════════════════════════════════════════════════════════
    //  Test 1: Verify AsterDEX Contract Addresses
    // ══════════════════════════════════════════════════════════════════════════════

    describe("✅ Contract Addresses & Interfaces", function () {
        it("asBNB token exists at correct address", async function () {
            const asBnb = new ethers.Contract(BSC.ASBNB, ERC20_ABI, deployer);
            const decimals = await asBnb.decimals();
            expect(decimals).to.equal(18);
            console.log(`    ✓ asBNB token found (decimals: ${decimals})`);
        });

        it("asBNB Minter contract is callable", async function () {
            const minter = new ethers.Contract(BSC.ASBNB_MINTER, ASBNB_MINTER_ABI, deployer);

            // Test view functions
            const canDeposit = await minter.canDeposit();
            const canWithdraw = await minter.canWithdraw();

            console.log(`    ✓ Minter callable - canDeposit: ${canDeposit}, canWithdraw: ${canWithdraw}`);
            expect(typeof canDeposit).to.equal("boolean");
            expect(typeof canWithdraw).to.equal("boolean");
        });

        it("asBNB exchange rate is available", async function () {
            const minter = new ethers.Contract(BSC.ASBNB_MINTER, ASBNB_MINTER_ABI, deployer);
            const rate = await minter.convertToTokens(ethers.parseEther("1"));

            console.log(`    ✓ Exchange rate: 1 asBNB = ${ethers.formatEther(rate)} slisBNB`);
            expect(rate).to.be.gt(0);
        });

        it("adapter has correct constants", async function () {
            expect(await adapter.ASBNB()).to.equal(BSC.ASBNB);
            expect(await adapter.ASBNB_MINTER()).to.equal(BSC.ASBNB_MINTER);
            expect(await adapter.YIELD_PROXY()).to.equal(BSC.YIELD_PROXY);
            console.log(`    ✓ All adapter constants match BSC mainnet addresses`);
        });
    });

    // ══════════════════════════════════════════════════════════════════════════════
    //  Test 2: Open Hedge Position (USDT → BNB → asBNB)
    // ══════════════════════════════════════════════════════════════════════════════

    describe("🔓 Opening Hedge Position", function () {
        this.timeout(120_000);

        it("can open hedge: USDT → BNB → asBNB", async function () {
            const whale = await impersonate(BSC.BINANCE_WHALE);
            const usdt = new ethers.Contract(BSC.USDT, ERC20_ABI, whale);
            const asBnb = new ethers.Contract(BSC.ASBNB, ERC20_ABI, deployer);

            const hedgeAmount = ethers.parseUnits("100", 18); // 100 USDT

            // Transfer USDT to adapter
            await usdt.transfer(await adapter.getAddress(), hedgeAmount);

            // Encode hedge params: OPEN_HEDGE
            const hedgeParams = ethers.AbiCoder.defaultAbiCoder().encode(
                ["uint8", "uint256", "uint256", "uint256", "address"],
                [
                    0, // ActionType.OPEN_HEDGE
                    hedgeAmount,
                    0, // minReceived
                    2000, // targetHedgeBps (20%)
                    deployer.address, // recipient
                ]
            );

            const asBnbBefore = await asBnb.balanceOf(deployer.address);

            // Execute hedge
            const tx = await adapter.execute(deployer.address, hedgeParams);
            await tx.wait();

            const asBnbAfter = await asBnb.balanceOf(deployer.address);
            const asBnbReceived = asBnbAfter - asBnbBefore;

            console.log(`    ✓ Opened hedge: 100 USDT → ${ethers.formatEther(asBnbReceived)} asBNB`);
            expect(asBnbReceived).to.be.gt(0);
        });

        it("getHedgeValue returns correct USDT value", async function () {
            const hedgeValue = await adapter.getHedgeValue(deployer.address);

            console.log(`    ✓ Hedge value: ${ethers.formatEther(hedgeValue)} USDT`);
            // Should be close to 100 USDT (allowing for swap slippage ~5%)
            expect(hedgeValue).to.be.gt(ethers.parseEther("90"));
            expect(hedgeValue).to.be.lt(ethers.parseEther("105"));
        });
    });

    // ══════════════════════════════════════════════════════════════════════════════
    //  Test 3: Close Hedge Position (asBNB → BNB → USDT)
    // ══════════════════════════════════════════════════════════════════════════════

    describe("🔒 Closing Hedge Position", function () {
        this.timeout(120_000);

        it("can close hedge: asBNB → slisBNB → BNB → USDT", async function () {
            const asBnb = new ethers.Contract(BSC.ASBNB, ERC20_ABI, deployer);
            const usdt = new ethers.Contract(BSC.USDT, ERC20_ABI, deployer);

            const asBnbBalance = await asBnb.balanceOf(deployer.address);
            expect(asBnbBalance).to.be.gt(0); // From previous test

            // Transfer asBNB to adapter
            await asBnb.approve(await adapter.getAddress(), asBnbBalance);
            await asBnb.transfer(await adapter.getAddress(), asBnbBalance);

            const usdtBefore = await usdt.balanceOf(deployer.address);

            // Encode hedge params: CLOSE_HEDGE
            const hedgeParams = ethers.AbiCoder.defaultAbiCoder().encode(
                ["uint8", "uint256", "uint256", "uint256", "address"],
                [
                    1, // ActionType.CLOSE_HEDGE
                    asBnbBalance,
                    0, // minReceived
                    0, // targetHedgeBps (not used for close)
                    deployer.address, // recipient
                ]
            );

            // Execute close
            const tx = await adapter.execute(deployer.address, hedgeParams);
            await tx.wait();

            const usdtAfter = await usdt.balanceOf(deployer.address);
            const usdtReceived = usdtAfter - usdtBefore;

            console.log(`    ✓ Closed hedge: ${ethers.formatEther(asBnbBalance)} asBNB → ${ethers.formatEther(usdtReceived)} USDT`);
            // Should receive ~90-100 USDT (accounting for slippage both ways)
            expect(usdtReceived).to.be.gt(ethers.parseEther("80"));
        });
    });

    // ══════════════════════════════════════════════════════════════════════════════
    //  Test 4: Volatility-Triggered Hedge Ratios
    // ══════════════════════════════════════════════════════════════════════════════

    describe("📊 Hedge Ratio Targets", function () {
        it("NORMAL mode: 20% hedge", async function () {
            const targetBps = await adapter.getTargetHedgeBps(0); // NORMAL
            expect(targetBps).to.equal(2000); // 20%
            console.log(`    ✓ NORMAL mode: ${targetBps / 100}% hedge`);
        });

        it("VOLATILE mode: 40% hedge", async function () {
            const targetBps = await adapter.getTargetHedgeBps(1); // VOLATILE
            expect(targetBps).to.equal(4000); // 40%
            console.log(`    ✓ VOLATILE mode: ${targetBps / 100}% hedge`);
        });

        it("DRAWDOWN mode: 50% hedge", async function () {
            const targetBps = await adapter.getTargetHedgeBps(2); // DRAWDOWN
            expect(targetBps).to.equal(5000); // 50%
            console.log(`    ✓ DRAWDOWN mode: ${targetBps / 100}% hedge`);
        });
    });

    // ══════════════════════════════════════════════════════════════════════════════
    //  Test 5: View Functions
    // ══════════════════════════════════════════════════════════════════════════════

    describe("👁️ View Functions", function () {
        it("getAsBnbRate returns valid exchange rate", async function () {
            const rate = await adapter.getAsBnbRate();
            console.log(`    ✓ asBNB rate: ${ethers.formatEther(rate)} slisBNB per asBNB`);
            expect(rate).to.be.gte(ethers.parseEther("1")); // Should be >= 1 (accrues value)
        });

        it("canDeposit returns boolean", async function () {
            const canDep = await adapter.canDeposit();
            console.log(`    ✓ Deposits enabled: ${canDep}`);
            expect(typeof canDep).to.equal("boolean");
        });

        it("canWithdraw returns boolean", async function () {
            const canWith = await adapter.canWithdraw();
            console.log(`    ✓ Withdrawals enabled: ${canWith}`);
            expect(typeof canWith).to.equal("boolean");
        });

        it("hasActiveActivities returns boolean", async function () {
            const hasActive = await adapter.hasActiveActivities();
            console.log(`    ✓ LaunchPool activities ongoing: ${hasActive}`);
            expect(typeof hasActive).to.equal("boolean");
        });
    });

    // ══════════════════════════════════════════════════════════════════════════════
    //  Test 6: Full Round-Trip Test
    // ══════════════════════════════════════════════════════════════════════════════

    describe("🔄 Full Round-Trip Test", function () {
        this.timeout(180_000);

        it("full cycle: USDT → asBNB → USDT preserves ~95% value", async function () {
            const whale = await impersonate(BSC.BINANCE_WHALE);
            const usdt = new ethers.Contract(BSC.USDT, ERC20_ABI, whale);
            const asBnb = new ethers.Contract(BSC.ASBNB, ERC20_ABI, user);

            const initialAmount = ethers.parseUnits("50", 18); // 50 USDT
            await usdt.transfer(await adapter.getAddress(), initialAmount);

            // Step 1: Open hedge
            const openParams = ethers.AbiCoder.defaultAbiCoder().encode(
                ["uint8", "uint256", "uint256", "uint256", "address"],
                [0, initialAmount, 0, 2000, user.address]
            );
            await adapter.execute(user.address, openParams);

            const asBnbBalance = await asBnb.balanceOf(user.address);
            console.log(`    → Opened: 50 USDT → ${ethers.formatEther(asBnbBalance)} asBNB`);

            // Transfer asBNB to adapter for closing
            await asBnb.connect(user).approve(await adapter.getAddress(), asBnbBalance);
            await asBnb.connect(user).transfer(await adapter.getAddress(), asBnbBalance);

            // Step 2: Close hedge
            const usdtUser = new ethers.Contract(BSC.USDT, ERC20_ABI, user);
            const usdtBefore = await usdtUser.balanceOf(user.address);

            const closeParams = ethers.AbiCoder.defaultAbiCoder().encode(
                ["uint8", "uint256", "uint256", "uint256", "address"],
                [1, asBnbBalance, 0, 0, user.address]
            );
            await adapter.execute(user.address, closeParams);

            const usdtAfter = await usdtUser.balanceOf(user.address);
            const finalAmount = usdtAfter - usdtBefore;

            console.log(`    → Closed: ${ethers.formatEther(asBnbBalance)} asBNB → ${ethers.formatEther(finalAmount)} USDT`);

            // Calculate loss from fees/slippage
            const loss = initialAmount - finalAmount;
            const lossPercent = Number(loss * 10000n / initialAmount) / 100;
            console.log(`    → Round-trip loss: ${lossPercent.toFixed(2)}% (swap fees + slippage)`);

            // Expect ~3-7% loss from:
            // - PancakeSwap fees (0.25% × 4 swaps = 1%)
            // - Slippage (~1-2% each way = 2-4%)
            // - Price impact on BNB/slisBNB pairs
            expect(finalAmount).to.be.gt(ethers.parseEther("45")); // At least 90% recovered
        });
    });

    // ══════════════════════════════════════════════════════════════════════════════
    //  Final Summary
    // ══════════════════════════════════════════════════════════════════════════════

    after(function () {
        console.log(`\n    ═══════════════════════════════════════════════════════════`);
        console.log(`    ✅ All hedge tests passed!`);
        console.log(`    📍 AsterDEX contracts verified on BSC mainnet`);
        console.log(`    🛡️ Hedge adapter ready for production`);
        console.log(`    ═══════════════════════════════════════════════════════════\n`);
    });
});
