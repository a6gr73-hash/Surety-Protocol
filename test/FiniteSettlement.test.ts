import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import {
    FiniteSettlement,
    CollateralVault,
    PoIClaimProcessor,
    Surety,
    MockUSDC
} from "../typechain-types";
import { Trie } from "@ethereumjs/trie";
import { Buffer } from "buffer";

describe("FiniteSettlement (Production)", function () {
    // ... (variable declarations remain the same)
    let finiteSettlement: FiniteSettlement;
    let collateralVault: CollateralVault;
    let poiProcessor: PoIClaimProcessor;
    let srt: Surety;
    let usdc: MockUSDC;
    let owner: SignerWithAddress;
    let payer: SignerWithAddress;
    let recipient: SignerWithAddress;
    let watcher: SignerWithAddress;

    const USDC_PAYMENT_AMOUNT = ethers.parseUnits("1000", 6);
    const USDC_DEPOSIT_AMOUNT = ethers.parseUnits("5000", 6);
    const Status = { Pending: 0, Resolved: 1, Failed: 2, Expired: 3 };

    beforeEach(async function () {
        // ... (beforeEach setup remains the same)
        [owner, payer, recipient, watcher] = await ethers.getSigners();
        srt = await ethers.deployContract("Surety");
        usdc = await ethers.deployContract("MockUSDC");
        collateralVault = await ethers.deployContract("CollateralVault", [await srt.getAddress(), await usdc.getAddress()]);
        poiProcessor = await ethers.deployContract("PoIClaimProcessor");
        finiteSettlement = await ethers.deployContract("FiniteSettlement", [
            await collateralVault.getAddress(),
            await poiProcessor.getAddress(),
            await usdc.getAddress(),
            await srt.getAddress()
        ]);
        await collateralVault.connect(owner).addSettlementContract(await finiteSettlement.getAddress());
        await usdc.mint(payer.address, USDC_DEPOSIT_AMOUNT + USDC_PAYMENT_AMOUNT);
        await usdc.connect(payer).approve(await collateralVault.getAddress(), USDC_DEPOSIT_AMOUNT);
        await collateralVault.connect(payer).depositUSDC(USDC_DEPOSIT_AMOUNT);
        await usdc.connect(payer).approve(await finiteSettlement.getAddress(), USDC_PAYMENT_AMOUNT);
    });

    // Helper function to initiate a payment and return its ID
    async function initiatePayment(): Promise<string> {
        const tx = await finiteSettlement.connect(payer).initiatePayment(recipient.address, USDC_PAYMENT_AMOUNT, false);
        const receipt = await tx.wait();

        // FIX: Add type-safe guards for receipt and event parsing
        if (!receipt) throw new Error("Transaction receipt is null");
        const event = receipt.logs.find((e: any) => e.fragment?.name === 'PaymentInitiated');
        if (!event || !('args' in event)) throw new Error("PaymentInitiated event not found.");
        
        return event.args[0]; // paymentId
    }

    describe("Successful Payment Flow", function () {
        it("Should execute a successful payment and release all collateral", async function () {
            const paymentId = await initiatePayment();
            const recipientBalanceBefore = await usdc.balanceOf(recipient.address);

            await finiteSettlement.connect(payer).executePayment(paymentId);
            
            const dispute = await finiteSettlement.disputes(paymentId);
            expect(dispute.status).to.equal(Status.Resolved);
            expect(await usdc.balanceOf(recipient.address)).to.equal(recipientBalanceBefore + USDC_PAYMENT_AMOUNT);
            
            // FIX: Now calling the correct view functions that exist on the vault
            expect(await collateralVault.usdcLockedOf(payer.address)).to.equal(0);
            expect(await collateralVault.usdcFreeOf(payer.address)).to.equal(USDC_DEPOSIT_AMOUNT);
        });
    });

    describe("Failed Payment and Dispute Resolution Flow", function () {
        // ... (the rest of the test file remains the same)
        let paymentId: string;
        let trie: Trie;
        let root: string;
        let nonExistentKey: Buffer;
        let nonInclusionProof: string[];

        beforeEach(async function () {
            paymentId = await initiatePayment();
            await finiteSettlement.connect(payer).handlePaymentFailure(paymentId);
            trie = new Trie();
            const includedKey = Buffer.from(ethers.keccak256(ethers.toUtf8Bytes("some_other_tx")));
            await trie.put(includedKey, Buffer.from("some_value"));
            nonExistentKey = Buffer.from(ethers.keccak256(ethers.toUtf8Bytes("the_failed_tx")));
            root = '0x' + Buffer.from(trie.root()).toString('hex');
            const rawProof = await trie.createProof(nonExistentKey);
            nonInclusionProof = rawProof.map(node => '0x' + Buffer.from(node).toString('hex'));
            await poiProcessor.connect(owner).publishShardRoot(root);
        });

        it("Should successfully resolve a dispute with a valid proof", async function () {
            await poiProcessor.connect(watcher).processNonArrivalProof(paymentId, root, nonExistentKey, nonInclusionProof);
            const payerBalanceBefore = await usdc.balanceOf(payer.address);
            const recipientBalanceBefore = await usdc.balanceOf(recipient.address);
            const watcherBalanceBefore = await usdc.balanceOf(watcher.address);
            const treasuryBalanceBefore = await usdc.balanceOf(owner.address);
            await expect(finiteSettlement.connect(watcher).resolveDispute(paymentId))
                .to.emit(finiteSettlement, "DisputeResolved")
                .withArgs(paymentId, recipient.address, watcher.address);
            const collateralAmount = (USDC_PAYMENT_AMOUNT * 110n) / 100n;
            const totalFee = (USDC_PAYMENT_AMOUNT * 1n) / 100n;
            const watcherReward = (totalFee * 20n) / 100n;
            const treasuryFee = totalFee - watcherReward;
            const payerRefund = collateralAmount - USDC_PAYMENT_AMOUNT - totalFee;
            expect(await usdc.balanceOf(recipient.address)).to.equal(recipientBalanceBefore + USDC_PAYMENT_AMOUNT);
            expect(await usdc.balanceOf(watcher.address)).to.equal(watcherBalanceBefore + watcherReward);
            expect(await usdc.balanceOf(owner.address)).to.equal(treasuryBalanceBefore + treasuryFee);
            expect(await usdc.balanceOf(payer.address)).to.equal(payerBalanceBefore + payerRefund);
        });
    });
});