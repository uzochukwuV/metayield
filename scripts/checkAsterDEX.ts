import { ethers } from "hardhat";

async function main() {
    console.log("\n🔍 Investigating AsterDEX asBNB Minter Contract\n");

    const ASBNB_MINTER = "0x7F52773065Fd350b5a935CE2B293FdB16551A6FC";

    // Try to get contract code
    const code = await ethers.provider.getCode(ASBNB_MINTER);
    console.log(`✓ Contract exists: ${code.length > 2 ? 'YES' : 'NO'}`);
    console.log(`  Code length: ${code.length} bytes\n`);

    // Try multiple possible function signatures
    const signatures = [
        "canDeposit()",
        "depositsEnabled()",
        "paused()",
        "minMintAmount()",
        "mintAsBnb() payable",
        "deposit() payable",
        "mint() payable"
    ];

    console.log("📞 Testing function signatures:\n");

    for (const sig of signatures) {
        try {
            const iface = new ethers.Interface([`function ${sig} returns (bool)`]);
            const selector = iface.getFunction(sig.split('(')[0])?.selector;

            const result = await ethers.provider.call({
                to: ASBNB_MINTER,
                data: selector
            });

            console.log(`✓ ${sig}: ${result}`);
        } catch (e: any) {
            console.log(`✗ ${sig}: ${e.message.slice(0, 80)}`);
        }
    }

    // Check if it's an upgradeable proxy
    console.log("\n🔄 Checking for proxy pattern:\n");

    const implementationSlot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
    const implAddr = await ethers.provider.getStorage(ASBNB_MINTER, implementationSlot);

    if (implAddr !== "0x" + "0".repeat(64)) {
        console.log(`✓ Proxy detected!`);
        console.log(`  Implementation: ${ethers.getAddress("0x" + implAddr.slice(26))}`);
    } else {
        console.log(`✗ Not an EIP-1967 proxy`);
    }

    // Try to call with different ABIs
    console.log("\n📋 Testing with provided ABI:\n");

    const minterAbi = [
        "function canDeposit() view returns (bool)",
        "function canWithdraw() view returns (bool)",
        "function minMintAmount() view returns (uint256)",
        "function totalTokens() view returns (uint256)",
        "function convertToTokens(uint256) view returns (uint256)",
        "function convertToAsBnb(uint256) view returns (uint256)"
    ];

    const minter = new ethers.Contract(ASBNB_MINTER, minterAbi, ethers.provider);

    try {
        const canDep = await minter.canDeposit();
        console.log(`  canDeposit: ${canDep}`);
    } catch (e: any) {
        console.log(`  canDeposit: ERROR - ${e.message.slice(0, 80)}`);
    }

    try {
        const canWith = await minter.canWithdraw();
        console.log(`  canWithdraw: ${canWith}`);
    } catch (e: any) {
        console.log(`  canWithdraw: ERROR - ${e.message.slice(0, 80)}`);
    }

    try {
        const minMint = await minter.minMintAmount();
        console.log(`  minMintAmount: ${ethers.formatEther(minMint)} BNB`);
    } catch (e: any) {
        console.log(`  minMintAmount: ERROR - ${e.message.slice(0, 80)}`);
    }

    try {
        const total = await minter.totalTokens();
        console.log(`  totalTokens: ${ethers.formatEther(total)} tokens`);
    } catch (e: any) {
        console.log(`  totalTokens: ERROR - ${e.message.slice(0, 80)}`);
    }

    // Check official AsterDEX site behavior
    console.log("\n💡 Recommendations:\n");
    console.log("1. Visit https://www.asterdex.finance/stake to see how they call the contract");
    console.log("2. Check if there's a different entry point or router");
    console.log("3. Verify if asBNB minting requires going through YieldProxy instead");
    console.log("4. Look for events emitted by recent successful mints on BSCScan");
    console.log("\n📍 Contract: https://bscscan.com/address/" + ASBNB_MINTER);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
