// scripts/deploy.js
import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // --- 1. DEPLOY TOKENS ---
  const suretyToken = await ethers.deployContract("Surety");
  await suretyToken.waitForDeployment();
  console.log(`Surety (SRT) Token deployed to: ${suretyToken.target}`);

  const mockUsdc = await ethers.deployContract("MockUSDC");
  await mockUsdc.waitForDeployment();
  console.log(`MockUSDC Token deployed to: ${mockUsdc.target}`);

  // --- 2. DEPLOY CORE CONTRACTS ---
  const collateralVault = await ethers.deployContract("CollateralVault", [
    suretyToken.target,
    mockUsdc.target,
  ]);
  await collateralVault.waitForDeployment();
  console.log(`CollateralVault deployed to: ${collateralVault.target}`);

  const poiProcessor = await ethers.deployContract("PoIClaimProcessor");
  await poiProcessor.waitForDeployment();
  console.log(`PoIClaimProcessor deployed to: ${poiProcessor.target}`);

  const minWatcherStake = ethers.parseEther("1000"); // 1,000 SRT
  const watcherRegistry = await ethers.deployContract("WatcherRegistry", [
    collateralVault.target,
    minWatcherStake,
  ]);
  await watcherRegistry.waitForDeployment();
  console.log(`WatcherRegistry deployed to: ${watcherRegistry.target}`);

  const finiteSettlement = await ethers.deployContract("FiniteSettlement", [
    collateralVault.target,
    poiProcessor.target,
    mockUsdc.target,
    suretyToken.target,
  ]);
  await finiteSettlement.waitForDeployment();
  console.log(`FiniteSettlement deployed to: ${finiteSettlement.target}`);

  // --- 3. POST-DEPLOYMENT CONFIGURATION ---
  console.log("\n--- Configuring Contracts ---");
  
  // Authorize the FiniteSettlement contract in the CollateralVault.
  // NOTE: The current vault design only allows one settlement contract.
  // For this test, we are authorizing FiniteSettlement. A production
  // system would require a vault that can authorize multiple contracts.
  await collateralVault.setSettlementContract(finiteSettlement.target);
  console.log("FiniteSettlement contract authorized in CollateralVault.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});