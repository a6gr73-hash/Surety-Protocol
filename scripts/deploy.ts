import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // --- DEPLOY SRT (SURETY) TOKEN ---
  const suretyTokenFactory = await ethers.getContractFactory("Surety");
  const initialSupply = ethers.parseEther("1000000000"); // 1 Billion SRT
  const suretyToken = await suretyTokenFactory.deploy(initialSupply);
  await suretyToken.waitForDeployment();
  console.log(`Surety (SRT) Token deployed to: ${await suretyToken.getAddress()}`);

  // --- DEPLOY MOCK USDC TOKEN ---
  const mockUsdcFactory = await ethers.getContractFactory("MockERC20");
  const mockUsdc = await mockUsdcFactory.deploy("Mock USDC", "mUSDC");
  await mockUsdc.waitForDeployment();
  console.log(`MockUSDC deployed to: ${await mockUsdc.getAddress()}`);

  // --- DEPLOY COLLATERAL VAULT ---
  const collateralVaultFactory = await ethers.getContractFactory("CollateralVault");
  const collateralVault = await collateralVaultFactory.deploy(
    await suretyToken.getAddress(),
    await mockUsdc.getAddress()
  );
  await collateralVault.waitForDeployment();
  console.log(`CollateralVault deployed to: ${await collateralVault.getAddress()}`);

  // --- DEPLOY INSTANT SETTLEMENT ---
  const softCap = ethers.parseUnits("1000", 6); // $1,000 soft cap
  const instantSettlementFactory = await ethers.getContractFactory("InstantSettlement");
  const instantSettlement = await instantSettlementFactory.deploy(
    await collateralVault.getAddress(),
    await mockUsdc.getAddress(),
    await suretyToken.getAddress(),
    softCap
  );
  await instantSettlement.waitForDeployment();
  console.log(`InstantSettlement deployed to: ${await instantSettlement.getAddress()}`);

  // --- POST-DEPLOYMENT CONFIGURATION ---
  console.log("\n--- Configuring Contracts ---");
  await collateralVault.setSettlementContract(await instantSettlement.getAddress());
  console.log("Settlement contract authorized in Vault.");

  const srtPrice = 25_000_000; // $0.25
  await instantSettlement.setSrtPrice(srtPrice);
  console.log("Initial SRT price set.");

  await instantSettlement.registerMerchant(deployer.address, true);
  console.log("Deployer registered as a merchant.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
