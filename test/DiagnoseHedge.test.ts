import { ethers } from "hardhat";

const BSC = {
    USDT: "0x55d398326f99059fF775485246999027B3197955",
    WBNB: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
    ASBNB: "0x77734e70b6E88b4d82fE632a168EDf6e700912b6",
    SLISBNB: "0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B",
    ASBNB_MINTER: "0x2F31ab8950c50080E77999fa456372f276952fD8",
    PANCAKE_ROUTER: "0x10ED43C718714eb63d5aA57B78B54704E256024E",
    BINANCE_WHALE: "0xF977814e90dA44bFA03b6295A0616a897441aceC",
};

const ERC20_ABI = ["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)", "function transfer(address,uint256) returns (bool)"];
const MINTER_ABI = ["function burnAsBnb(uint256) returns (uint256)", "function canWithdraw() view returns (bool)"];
const ROUTER_ABI = ["function swapExactTokensForETH(uint256,uint256,address[],address,uint256) returns (uint256[])", "function getAmountsOut(uint256,address[]) view returns (uint256[])"];

describe("🔍 Diagnose Hedge Closing Issue", function () {
    this.timeout(120_000);

    async function impersonate(address: string) {
        await ethers.provider.send("hardhat_impersonateAccount", [address]);
        await ethers.provider.send("hardhat_setBalance", [address, "0x56BC75E2D63100000"]);
        return await ethers.getSigner(address);
    }

    it("Step-by-step: Burn asBNB and track slisBNB", async function () {
        const whale = await impersonate(BSC.BINANCE_WHALE);
        const deployer = (await ethers.getSigners())[0];

        // Deploy hedge adapter
        const AdapterF = await ethers.getContractFactory("AsterHedgeAdapter");
        const adapter = await AdapterF.deploy();
        await adapter.waitForDeployment();
        const adapterAddr = await adapter.getAddress();

        console.log(`\n    📍 Adapter: ${adapterAddr}`);

        // Get 100 USDT and open hedge
        const usdt = new ethers.Contract(BSC.USDT, ERC20_ABI, whale);
        const asBnb = new ethers.Contract(BSC.ASBNB, ERC20_ABI, deployer);
        const slisBnb = new ethers.Contract(BSC.SLISBNB, ERC20_ABI, deployer);

        const amount = ethers.parseUnits("100", 18);
        await usdt.transfer(adapterAddr, amount);

        // Open hedge
        const openParams = ethers.AbiCoder.defaultAbiCoder().encode(
            ["uint8", "uint256", "uint256", "uint256", "address"],
            [0, amount, 0, 2000, deployer.address]
        );
        await adapter.execute(deployer.address, openParams);

        const asBnbBalance = await asBnb.balanceOf(deployer.address);
        console.log(`    ✓ Opened: 100 USDT → ${ethers.formatEther(asBnbBalance)} asBNB`);

        // Check if withdrawals are enabled
        const minter = new ethers.Contract(BSC.ASBNB_MINTER, MINTER_ABI, ethers.provider);
        const canWithdraw = await minter.canWithdraw();
        console.log(`    ✓ Can withdraw: ${canWithdraw}`);

        // Transfer asBNB to adapter and check slisBNB balance before burn
        await asBnb.connect(deployer).approve(adapterAddr, asBnbBalance);
        await asBnb.connect(deployer).transfer(adapterAddr, asBnbBalance);

        const slisBnbBefore = await slisBnb.balanceOf(adapterAddr);
        console.log(`    → slisBNB before burn: ${ethers.formatEther(slisBnbBefore)}`);

        // Try calling burnAsBnb directly to see what happens
        const fullMinterABI = [
            "function burnAsBnb(uint256) returns (uint256)",
            "function canWithdraw() view returns (bool)"
        ];
        const minterWithSigner = new ethers.Contract(BSC.ASBNB_MINTER, fullMinterABI, deployer);

        // Approve and try direct burn
        await asBnb.connect(deployer).approve(BSC.ASBNB_MINTER, asBnbBalance);
        console.log(`    → Calling burnAsBnb with ${ethers.formatEther(asBnbBalance)} asBNB...`);

        const slisBnbDirectBefore = await slisBnb.balanceOf(deployer.address);
        const burnTx = await minterWithSigner.burnAsBnb(asBnbBalance);
        await burnTx.wait();
        const slisBnbDirectAfter = await slisBnb.balanceOf(deployer.address);

        console.log(`    ✓ Direct burn: received ${ethers.formatEther(slisBnbDirectAfter - slisBnbDirectBefore)} slisBNB`);

        const slisBnbAfter = await slisBnb.balanceOf(adapterAddr);
        console.log(`    → slisBNB after close: ${ethers.formatEther(slisBnbAfter)}`);
        console.log(`    → slisBNB received from burn: ${ethers.formatEther(slisBnbAfter - slisBnbBefore)}`);

        const usdtAfter = await usdt.balanceOf(deployer.address);
        console.log(`    ✓ Closed: got ${ethers.formatEther(usdtAfter)} USDT back`);

        // Check what PancakeSwap would quote for slisBNB → WBNB → USDT
        if (slisBnbAfter > slisBnbBefore) {
            const slisBnbAmount = slisBnbAfter - slisBnbBefore;
            const router = new ethers.Contract(BSC.PANCAKE_ROUTER, ROUTER_ABI, ethers.provider);
            const path = [BSC.SLISBNB, BSC.WBNB, BSC.USDT];
            const amounts = await router.getAmountsOut(slisBnbAmount, path);
            console.log(`    → PancakeSwap quote for ${ethers.formatEther(slisBnbAmount)} slisBNB:`);
            console.log(`      slisBNB → ${ethers.formatEther(amounts[1])} WBNB → ${ethers.formatEther(amounts[2])} USDT`);
        }
    });
});
