import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { FiniteSettlement, CollateralVault, PoIClaimProcessor, Surety, MockUSDC } from "../typechain-types";
import { Trie } from "@ethereumjs/trie";
import { Buffer } from "buffer";

describe("FiniteSettlement (Refactored)", function () {
    let finiteSettlement: FiniteSettlement;
    let collateralVault: CollateralVault;
    let poiProcessor: PoIClaimProcessor;
    let srt: Surety;
    let usdc: MockUSDC;
    let owner: SignerWithAddress;
    let payer: SignerWithAddress;
    let recipient: SignerWithAddress;
    let relayer: SignerWithAddress;

    const USDC_PAYMENT_AMOUNT = ethers.parseUnits("100", 6);
    const USDC_DEPOSIT_AMOUNT = ethers.parseUnits("5000", 6);
    const DISPUTE_TIMEOUT_BLOCKS = 21600;
    
    // Enum matching the Solidity contract
    const Status = {
        Pending: 0,
        Resolved: 1,
        Failed: 2,
        Expired: 3,
    };

    beforeEach(async function () {
        [owner, payer, recipient, relayer] = await ethers.getSigners();
        
        const SuretyFactory = await ethers.getContractFactory("Surety");
        srt = await SuretyFactory.deploy();
        await srt.waitForDeployment();

        const MockUSDCFactory = await ethers.getContractFactory("MockUSDC");
        usdc = await MockUSDCFactory.deploy();
        await usdc.waitForDeployment();

        const CollateralVaultFactory = await ethers.getContractFactory("CollateralVault");
        collateralVault = await CollateralVaultFactory.deploy(await srt.getAddress(), await usdc.getAddress());
        await collateralVault.waitForDeployment();

        const PoIProcessorFactory = await ethers.getContractFactory("PoIClaimProcessor");
        poiProcessor = await PoIProcessorFactory.deploy();
        await poiProcessor.waitForDeployment();

        const FiniteSettlementFactory = await ethers.getContractFactory("FiniteSettlement");
        finiteSettlement = await FiniteSettlementFactory.deploy(
            await collateralVault.getAddress(),
            await poiProcessor.getAddress(),
            await usdc.getAddress(),
            await srt.getAddress()
        );
        await finiteSettlement.waitForDeployment();

        await collateralVault.connect(owner).setSettlementContract(await finiteSettlement.getAddress());

        await srt.transfer(payer.address, ethers.parseEther("5000"));
        await usdc.mint(payer.address, USDC_DEPOSIT_AMOUNT + USDC_PAYMENT_AMOUNT);
        
        await srt.connect(payer).approve(await collateralVault.getAddress(), ethers.parseEther("5000"));
        await usdc.connect(payer).approve(await collateralVault.getAddress(), USDC_DEPOSIT_AMOUNT);
        await collateralVault.connect(payer).depositSRT(ethers.parseEther("5000"));
        await collateralVault.connect(payer).depositUSDC(USDC_DEPOSIT_AMOUNT);

        await usdc.connect(payer).approve(await finiteSettlement.getAddress(), USDC_PAYMENT_AMOUNT);
    });

    describe("Successful Payment Flow", function () {
        it("Should process a successful payment and release collateral", async function () {
            const payerCollateralBefore = await collateralVault.usdcLockedOf(payer.address);
            const recipientBalanceBefore = await usdc.balanceOf(recipient.address);
            
            const tx = await finiteSettlement.connect(payer).initiatePayment(recipient.address, USDC_PAYMENT_AMOUNT, false);
            const receipt = await tx.wait();
            const event = receipt.logs.find((e: any) => e.fragment && e.fragment.name === 'PaymentInitiated');
            if (!event || !('args' in event)) throw new Error("PaymentInitiated event not found.");
            const paymentId = event.args[0];

            const disputeAfterInitiate = await finiteSettlement.disputes(paymentId);
            expect(disputeAfterInitiate.status).to.equal(Status.Pending);

            await finiteSettlement.connect(payer).executePayment(paymentId);
            
            const payerCollateralAfter = await collateralVault.usdcLockedOf(payer.address);
            const recipientBalanceAfter = await usdc.balanceOf(recipient.address);
            const disputeAfterExecute = await finiteSettlement.disputes(paymentId);

            expect(disputeAfterExecute.status).to.equal(Status.Resolved);
            expect(payerCollateralBefore).to.equal(0);
            expect(payerCollateralAfter).to.equal(0);
            expect(recipientBalanceAfter).to.equal(recipientBalanceBefore + USDC_PAYMENT_AMOUNT);
        });
    });

    describe("Failed Payment Flow", function () {
        let paymentId: string;
        let failedTxKey: Buffer;

        beforeEach(async function () {
            const tx = await finiteSettlement.connect(payer).initiatePayment(recipient.address, USDC_PAYMENT_AMOUNT, false);
            const receipt = await tx.wait();
            const event = receipt.logs.find((e: any) => e.fragment && e.fragment.name === 'PaymentInitiated');
            if (!event || !('args' in event)) throw new Error("PaymentInitiated event not found.");
            paymentId = event.args[0];

            await usdc.setShouldFail(true);
            await finiteSettlement.connect(payer).executePayment(paymentId);
            failedTxKey = Buffer.from(ethers.randomBytes(32)); 
        });

        it("Should handle a failed payment and set the dispute status to Failed", async function () {
            const dispute = await finiteSettlement.disputes(paymentId);
            expect(dispute.status).to.equal(Status.Failed);
            expect(await usdc.balanceOf(await finiteSettlement.getAddress())).to.be.above(0);
        });

        it("Should resolve a failed dispute correctly after PoI authorization", async function () {
            const trie = new Trie();
            await trie.put(Buffer.from('some-other-key'), Buffer.from('some-value'));

            const proof = await trie.createProof(failedTxKey);
            const formattedProof = proof.map(node => '0x' + Buffer.from(node).toString('hex'));

            const root = '0x' + Buffer.from(trie.root()).toString('hex');
            await poiProcessor.connect(owner).publishShardRoot(root);

            await poiProcessor.connect(relayer).processNonArrivalProof(paymentId, root, '0x' + failedTxKey.toString('hex'), formattedProof);

            const recipientBalanceBefore = await usdc.balanceOf(recipient.address);
            const payerBalanceBefore = await usdc.balanceOf(payer.address);

            await finiteSettlement.connect(owner).resolveDispute(paymentId);

            const recipientBalanceAfter = await usdc.balanceOf(recipient.address);
            const payerBalanceAfter = await usdc.balanceOf(payer.address);
            const dispute = await finiteSettlement.disputes(paymentId);
            
            expect(dispute.status).to.equal(Status.Resolved);
            expect(recipientBalanceAfter).to.be.above(recipientBalanceBefore);
            expect(payerBalanceAfter).to.be.above(payerBalanceBefore);
            expect(await usdc.balanceOf(await finiteSettlement.getAddress())).to.equal(0);
        });

        it("Should allow the payer to claim escrow after a timeout", async function () {
            await ethers.provider.send('hardhat_mine', [ethers.toQuantity(DISPUTE_TIMEOUT_BLOCKS + 1)]);

            const payerCollateralBefore = await usdc.balanceOf(payer.address);
            await finiteSettlement.connect(payer).claimExpiredEscrow(paymentId);
            const payerCollateralAfter = await usdc.balanceOf(payer.address);
            const dispute = await finiteSettlement.disputes(paymentId);

            expect(dispute.status).to.equal(Status.Expired);
            expect(payerCollateralAfter).to.be.above(payerCollateralBefore);
            expect(await usdc.balanceOf(await finiteSettlement.getAddress())).to.equal(0);
        });
    });
});
