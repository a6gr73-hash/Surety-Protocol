import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@typechain/hardhat";

const config: HardhatUserConfig = {
  solidity: "0.8.20",
  typechain: {
    outDir: "typechain-types",
    target: "ethers-v6" // <--- match installed @typechain/ethers-v6
  }
};

export default config;
