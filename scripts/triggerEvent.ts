// scripts/triggerEvent.ts
import { task } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";

task("trigger-event", "Triggers a PaymentInitiated event for the watcher to detect")
  .addOptionalPositionalParam("amount", "The amount of USDC to send", "50") // Default value is "50"
  .setAction(async (taskArgs: { amount: string }, hre: HardhatRuntimeEnvironment) => {
    const { ethers } = hre;
    
    // --- CONFIGURATION ---
    const finiteSettlementAddress = "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707"; // 👈 ENSURE THIS IS YOUR DEPLOYED ADDRESS
    const paymentAmountString = taskArgs.amount;
    const paymentAmount = ethers.parseUnits(paymentAmountString, 6);
    
    console.log(`\n--- Triggering event with amount: ${paymentAmountString} USDC ---\n`);
    // --- END CONFIGURATION ---

    const [payer, recipient] = await ethers.getSigners();
    const usdcAddress = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512";
    const collateralVaultAddress = "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0";

    console.log(`Using Payer: ${payer.address}`);
    console.log(`Using Recipient: ${recipient.address}`);
    
    const finiteSettlement = await ethers.getContractAt("FiniteSettlement", finiteSettlementAddress);
    const usdc = await ethers.getContractAt("MockUSDC", usdcAddress);
    const collateralVault = await ethers.getContractAt("CollateralVault", collateralVaultAddress);

    console.log("Minting and approving funds for payer...");
    const collateralAmount = (paymentAmount * 110n) / 100n;
    const totalMintAmount = paymentAmount + collateralAmount;
    await usdc.connect(payer).mint(payer.address, totalMintAmount);

    await usdc.connect(payer).approve(finiteSettlement.target, paymentAmount);
    await usdc.connect(payer).approve(collateralVault.target, collateralAmount);
    
    await collateralVault.connect(payer).depositUSDC(collateralAmount);
    console.log("Funds approved and collateral deposited.");

    console.log("\nInitiating payment...");
    const tx = await finiteSettlement.connect(payer).initiatePayment(
      recipient.address,
      paymentAmount,
      false // useSrtCollateral = false
    );

    await tx.wait();
    console.log("✅ PaymentInitiated event has been emitted.");
  });

// This line is needed to make the file a module.
export {};
