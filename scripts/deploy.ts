import { ethers } from "hardhat";
import { CollateralVault, InstantSettlement } from "../typechain-types"; // only for typing

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with:", deployer.address);

  const srtAddress = "0xSRT_TOKEN_ADDRESS";   // replace
  const usdcAddress = "0xUSDC_TOKEN_ADDRESS"; // replace

  // --- CollateralVault ---
  const CollateralVaultFactory = await ethers.getContractFactory("CollateralVault");
  const collateralVault: CollateralVault = await CollateralVaultFactory.deploy(srtAddress, usdcAddress);
  await collateralVault.waitForDeployment(); // ethers-v6 uses waitForDeployment instead of deployed()
  console.log("CollateralVault deployed to:", collateralVault.target);

  // --- InstantSettlement ---
  const softCap = 10_000 * 10 ** 6;
  const InstantSettlementFactory = await ethers.getContractFactory("InstantSettlement");
  const instantSettlement: InstantSettlement = await InstantSettlementFactory.deploy(
    collateralVault.target,
    usdcAddress,
    srtAddress,
    softCap
  );
  await instantSettlement.waitForDeployment();
  console.log("InstantSettlement deployed to:", instantSettlement.target);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});

