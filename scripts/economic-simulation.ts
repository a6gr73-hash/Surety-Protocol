// scripts/economic-simulation.ts

import { ethers } from "hardhat";
import { Signer } from "ethers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { WatcherRegistry } from "../typechain-types";

// ##################################################################################
// --- HELPER FUNCTIONS ---
// ##################################################################################

async function initiateAndFailPayment(finiteSettlement: any, payer: Signer, recipient: Signer, usdc: any, amount: bigint) {
    await usdc.connect(payer).approve(finiteSettlement.target, amount);
    const tx = await finiteSettlement.connect(payer).initiatePayment(await recipient.getAddress(), amount, false);
    const receipt = await tx.wait();
    const event = receipt.logs.find((e: any) => e.fragment?.name === 'PaymentInitiated');
    if (!event || !('args' in event)) throw new Error("PaymentInitiated event not found.");
    const paymentId = event.args[0];
    await finiteSettlement.connect(payer).handlePaymentFailure(paymentId);
    return { paymentId };
}

async function watcherAuthorizesPayout(poiProcessor: any, watcher: Signer, paymentId: string) {
    const tx = await poiProcessor.connect(watcher).processNonArrivalProof(paymentId);
    const receipt = await tx.wait();
    // FIX: Explicitly cast receipt values to BigInt for type safety
    const gasCost = BigInt(receipt.gasUsed) * BigInt(receipt.gasPrice);
    return { gasCost };
}

async function resolveDispute(finiteSettlement: any, caller: Signer, paymentId: string) {
    const tx = await finiteSettlement.connect(caller).resolveDispute(paymentId);
    const receipt = await tx.wait();
    // FIX: Explicitly cast receipt values to BigInt for type safety
    const gasCost = BigInt(receipt.gasUsed) * BigInt(receipt.gasPrice);
    return { gasCost };
}

async function distributeStipends(
    watcherRegistry: WatcherRegistry, 
    usdc: any, 
    treasury: Signer, 
    watchers: HardhatEthersSigner[],
    treasuryTracker: { balance: bigint }
) {
    if (treasuryTracker.balance <= 0n) {
        return; // No funds to distribute
    }

    const totalDistribution = treasuryTracker.balance / 2n; // Distribute 50% of the treasury
    const amountPerWatcher = totalDistribution / BigInt(watchers.length);
    if (amountPerWatcher <= 0n) return;

    // Treasury sends funds to the WatcherRegistry contract
    await usdc.connect(treasury).transfer(watcherRegistry.target, totalDistribution);
    
    // DAO/owner calls the distribution function
    const watcherAddresses = watchers.map(w => w.address);
    await watcherRegistry.connect(treasury).distributeStipends(watcherAddresses, amountPerWatcher);
    
    // Update trackers
    treasuryTracker.balance -= totalDistribution;
    return totalDistribution;
}


// ##################################################################################
// --- MAIN SIMULATION SCRIPT ---
// ##################################################################################

async function main() {
    console.log("--- Starting FSP Large-Scale Economic Simulation ---");

    // --- 1. SIMULATION PARAMETERS ---
    const NUM_USERS = 15;
    const NUM_WATCHERS = 3;
    const MIN_WATCHER_STAKE = ethers.parseEther("5000");
    const SIMULATION_ROUNDS = 1000;
    const STIPEND_INTERVAL = 100;

    // --- 2. DEPLOYMENT & SETUP ---
    console.log("\nDeploying contracts...");
    const [deployer] = await ethers.getSigners();
    const accounts = await ethers.getSigners();
    
    const suretyToken = await ethers.deployContract("Surety");
    const mockUsdc = await ethers.deployContract("MockUSDC");
    const collateralVault = await ethers.deployContract("CollateralVault", [suretyToken.target, mockUsdc.target]);
    
    // FIX: Corrected typo from "PoIProcessor" to "PoIClaimProcessor"
    const PoIProcessorFactory = await ethers.getContractFactory("PoIClaimProcessor");
    const poiProcessor = await PoIProcessorFactory.deploy();
    
    const watcherRegistry = await ethers.deployContract("WatcherRegistry", [
        collateralVault.target,
        mockUsdc.target,
        MIN_WATCHER_STAKE
    ]);

    const finiteSettlement = await ethers.deployContract("FiniteSettlement", [collateralVault.target, poiProcessor.target, mockUsdc.target, suretyToken.target]);

    await collateralVault.addSettlementContract(finiteSettlement.target);
    await collateralVault.addSettlementContract(watcherRegistry.target);
    console.log("✅ Contracts deployed.");

    // --- 3. ACTOR INITIALIZATION ---
    console.log("\nSetting up actors...");
    const availableAccounts = accounts.slice(1);
    const users = availableAccounts.slice(0, NUM_USERS);
    const watchers = availableAccounts.slice(NUM_USERS, NUM_USERS + NUM_WATCHERS);
    if (users.length < 2 || watchers.length < 1) throw new Error("Not enough accounts.");
    
    for (const user of users) {
        await mockUsdc.mint(await user.getAddress(), ethers.parseUnits("100000", 6));
        await mockUsdc.connect(user).approve(collateralVault.target, ethers.parseUnits("50000", 6));
        await collateralVault.connect(user).depositUSDC(ethers.parseUnits("50000", 6));
    }
    for (const watcher of watchers) {
        await suretyToken.transfer(await watcher.getAddress(), ethers.parseEther("100000"));
    }
    console.log(`✅ ${NUM_USERS} users and ${NUM_WATCHERS} watchers funded.`);

    // --- 4. WATCHER REGISTRATION ---
    console.log("\nRegistering watchers...");
    for (const watcher of watchers) {
        await suretyToken.connect(watcher).approve(collateralVault.target, MIN_WATCHER_STAKE);
        await collateralVault.connect(watcher).depositSRT(MIN_WATCHER_STAKE);
        await watcherRegistry.connect(watcher).registerWatcher(MIN_WATCHER_STAKE);
    }
    console.log("✅ All watchers registered.");

    // --- 5. SIMULATION STATE TRACKING ---
    const watcherStats: { [address: string]: { rewards: bigint, stipends: bigint, gasCosts: bigint } } = {};
    for(const watcher of watchers) {
        watcherStats[watcher.address] = { rewards: 0n, stipends: 0n, gasCosts: 0n };
    }
    const treasuryTracker = { balance: 0n };
    let totalStipendsPaid = 0n;


    // --- 6. SIMULATION LOOP ---
    console.log(`\n--- Starting Simulation for ${SIMULATION_ROUNDS} Rounds ---\n`);

    for (let i = 0; i < SIMULATION_ROUNDS; i++) {
        process.stdout.write(`Executing round ${i + 1}/${SIMULATION_ROUNDS}\r`);

        if (i > 0 && i % STIPEND_INTERVAL === 0) {
            const paidAmount = await distributeStipends(watcherRegistry, mockUsdc, deployer, watchers as HardhatEthersSigner[], treasuryTracker);
            if(paidAmount) {
                totalStipendsPaid += paidAmount;
                const amountPer = paidAmount / BigInt(watchers.length);
                for(const watcher of watchers) {
                    watcherStats[watcher.address].stipends += amountPer;
                }
            }
        }

        const payer = users[i % users.length];
        const recipient = users[(i + 1) % users.length];
        const watcher = watchers[i % watchers.length] as HardhatEthersSigner;
        const paymentAmount = ethers.parseUnits(`${Math.floor(Math.random() * 500) + 50}`, 6);

        const treasuryBalanceBefore = await mockUsdc.balanceOf(deployer.address);
        const watcherBalanceBefore = await mockUsdc.balanceOf(watcher.address);

        const { paymentId } = await initiateAndFailPayment(finiteSettlement, payer, recipient, mockUsdc, paymentAmount);
        const { gasCost: authGasCost } = await watcherAuthorizesPayout(poiProcessor, watcher, paymentId);
        const { gasCost: resolveGasCost } = await resolveDispute(finiteSettlement, watcher, paymentId);
        
        const watcherBalanceAfter = await mockUsdc.balanceOf(watcher.address);
        const treasuryBalanceAfter = await mockUsdc.balanceOf(deployer.address);

        const proofReward = watcherBalanceAfter - watcherBalanceBefore;
        
        watcherStats[watcher.address].rewards += proofReward;
        watcherStats[watcher.address].gasCosts += (authGasCost + resolveGasCost);
        treasuryTracker.balance += (treasuryBalanceAfter - treasuryBalanceBefore);
    }
    
    // --- 7. FINAL REPORT ---
    console.log("\n\n--- Simulation Complete ---");
    console.log("\n--- Final Economic Report ---");
    console.log(`\nTotal Rounds: ${SIMULATION_ROUNDS}`);
    console.log(`Treasury Starting Balance: 0.0 USDC`);
    console.log(`Total Treasury Revenue: ${ethers.formatUnits(treasuryTracker.balance + totalStipendsPaid, 6)} USDC`);
    console.log(`Total Stipends Paid:    -${ethers.formatUnits(totalStipendsPaid, 6)} USDC`);
    console.log(`Treasury Final Balance:   ${ethers.formatUnits(treasuryTracker.balance, 6)} USDC`);
    
    console.log("\n--- Watcher Profitability Analysis ---");
    for(const watcher of watchers) {
        const stats = watcherStats[watcher.address];
        console.log(`\nWatcher: ${watcher.address}`);
        console.log(`  - Income (Proof Rewards): ${ethers.formatUnits(stats.rewards, 6)} USDC`);
        console.log(`  - Income (Stipends):      ${ethers.formatUnits(stats.stipends, 6)} USDC`);
        console.log(`  - Total Income:           ${ethers.formatUnits(stats.rewards + stats.stipends, 6)} USDC`);
        console.log(`  - Total Gas Costs:        ${ethers.formatEther(stats.gasCosts)} ETH`);
        console.log(`  - NOTE: Net profit calculation requires an ETH/USDC price conversion.`);
    }
    console.log("\n---------------------------------");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});