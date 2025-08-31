import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      // ADD THIS LINE:
      viaIR: true,
    },
  },
  networks: {
    hardhat: {
      // Standard configuration for the local network.
    },
  },
};

export default config;
