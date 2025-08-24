import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { FiniteSettlement, CollateralVault, PoIClaimProcessor, Surety, MockUSDC } from "../typechain-types";
import { Trie } from "@ethereumjs/trie";
import { Buffer } from "buffer";

describe("FiniteSettlement", function () {
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
    // Define a separate amount for the vault deposit
    const USDC_DEPOSIT_AMOUNT = ethers.parseUnits("5000", 6);
    const DISPUTE_TIMEOUT_BLOCKS = 21600;

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
        // Mint enough USDC to the payer for BOTH the deposit and the subsequent payment
        await usdc.mint(payer.address, USDC_DEPOSIT_AMOUNT + USDC_PAYMENT_AMOUNT);
        
        await srt.connect(payer).approve(await collateralVault.getAddress(), ethers.parseEther("5000"));
        // Payer approves the vault to spend the deposit amount
        await usdc.connect(payer).approve(await collateralVault.getAddress(), USDC_DEPOSIT_AMOUNT);
        await collateralVault.connect(payer).depositSRT(ethers.parseEther("5000"));
        // Payer deposits only the collateral amount, retaining the rest in their wallet
        await collateralVault.connect(payer).depositUSDC(USDC_DEPOSIT_AMOUNT);

        // Payer must approve the FiniteSettlement contract to spend USDC for the payment itself
        await usdc.connect(payer).approve(await finiteSettlement.getAddress(), USDC_PAYMENT_AMOUNT);
    });

    describe("Successful Payment", function () {
        it("Should process a successful payment and release collateral", async function () {
            const payerCollateralBefore = await collateralVault.usdcLocked(payer.address);
            const recipientBalanceBefore = await usdc.balanceOf(recipient.address);

            await finiteSettlement.connect(payer).initiatePayment(recipient.address, USDC_PAYMENT_AMOUNT, false);

            const payerCollateralAfter = await collateralVault.usdcLocked(payer.address);
            const recipientBalanceAfter = await usdc.balanceOf(recipient.address);
            
            expect(payerCollateralBefore).to.equal(0);
            expect(payerCollateralAfter).to.equal(0);
            expect(recipientBalanceAfter).to.equal(recipientBalanceBefore + USDC_PAYMENT_AMOUNT);
        });
    });

    describe("Failed Payment and Dispute Resolution", function () {
        let paymentId: string;
        let failedTxKey: Buffer;

        beforeEach(async function () {
            await usdc.setShouldFail(true);
            const tx = await finiteSettlement.connect(payer).initiatePayment(recipient.address, USDC_PAYMENT_AMOUNT, false);
            const receipt = await tx.wait();
            if (!receipt) throw new Error("Transaction failed to be mined.");
            const event = receipt.logs.find((e: any) => e.fragment && e.fragment.name === 'DisputeCreated');
            if (!event || !('args' in event)) throw new Error("DisputeCreated event not found.");
            paymentId = event.args[0];
            failedTxKey = Buffer.from(ethers.randomBytes(32)); 
        });

        it("Should create a dispute when the payment transfer fails", async function () {
            const dispute = await finiteSettlement.disputes(paymentId);
            expect(dispute.payer).to.equal(payer.address);
            expect(dispute.recipient).to.equal(recipient.address);
            expect(await usdc.balanceOf(await finiteSettlement.getAddress())).to.be.above(0);
        });

        it("Should resolve a dispute correctly after PoI authorization", async function () {
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
            
            expect(recipientBalanceAfter).to.be.above(recipientBalanceBefore);
            expect(payerBalanceAfter).to.be.above(payerBalanceBefore);
            expect(await usdc.balanceOf(await finiteSettlement.getAddress())).to.equal(0);
        });

        it("Should allow the payer to claim escrow after a timeout", async function () {
            await ethers.provider.send('hardhat_mine', [ethers.toQuantity(DISPUTE_TIMEOUT_BLOCKS + 1)]);

            const payerCollateralBefore = await usdc.balanceOf(payer.address);
            await finiteSettlement.connect(payer).claimExpiredEscrow(paymentId);
            const payerCollateralAfter = await usdc.balanceOf(payer.address);

            expect(payerCollateralAfter).to.be.above(payerCollateralBefore);
            expect(await usdc.balanceOf(await finiteSettlement.getAddress())).to.equal(0);
        });
    });
});