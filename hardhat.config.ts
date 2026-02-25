import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv";

dotenv.config();

const BSC_RPC_URL = process.env.BSC_RPC_URL || "https://bsc-dataseed.binance.org";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    hardhat: {
      chainId: 56,
      forking: {
        url: BSC_RPC_URL
      },
    },
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 56,
    },
    bnb: {
      url: BSC_RPC_URL,
      chainId: 56,
      accounts: process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : [],
    },
  },
};

export default config;
