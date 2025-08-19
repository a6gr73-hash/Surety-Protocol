import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { PoIClaimProcessor, CollateralVault, Surety, MockERC20 } from "../typechain-types";
import { Trie } from "@ethereumjs/trie";
import { Buffer } from "buffer";

describe("PoIClaimProcessor", function () {
    let poiProcessor: PoIClaimProcessor;
    let vault: CollateralVault;
    let owner: SignerWithAddress;
    let payer: SignerWithAddress;
    let merchant: SignerWithAddress;
    let relayer: SignerWithAddress;
    let sourceTrie: Trie;
    let targetTrie: Trie;
    let slashedTxData: Buffer;
    let claim: any;
    let claimData: string;
    let claimHash: string;

    beforeEach(async function () {
        [owner, payer, merchant, relayer] = await ethers.getSigners();

        const SuretyFactory = await ethers.getContractFactory("Surety");
        const suretyToken = await SuretyFactory.deploy(ethers.parseEther("1000000"));
        const MockUsdcFactory = await ethers.getContractFactory("MockERC20");
        const mockUsdc = await MockUsdcFactory.deploy("Mock USDC", "mUSDC");
        const VaultFactory = await ethers.getContractFactory("CollateralVault");
        vault = await VaultFactory.deploy(await suretyToken.getAddress(), await mockUsdc.getAddress());
        const PoIProcessorFactory = await ethers.getContractFactory("PoIClaimProcessor");
        poiProcessor = await PoIProcessorFactory.deploy(await vault.getAddress());

        sourceTrie = new Trie();
        targetTrie = new Trie();
        slashedTxData = Buffer.from("example-slashed-transaction");

        const slashedTxHashHex = ethers.keccak256('0x' + slashedTxData.toString('hex'));
        const keyBuf = Buffer.from(slashedTxHashHex.slice(2), 'hex');

        await sourceTrie.put(keyBuf, slashedTxData);

        const sourceRootBuf = sourceTrie.root();
        const targetRootBuf = targetTrie.root();

        const rawSlashedProof = await sourceTrie.createProof(keyBuf);
        const rawNonArrivalProof = await targetTrie.createProof(keyBuf);

        const slashedProof = rawSlashedProof.map((node: Buffer) => '0x' + node.toString('hex'));
        const nonArrivalProof = rawNonArrivalProof.map((node: Buffer) => '0x' + node.toString('hex'));

        const nonce = await poiProcessor.nextNonce(payer.address);
        claim = {
            payer: payer.address,
            merchant: merchant.address,
            collateralToken: ethers.ZeroAddress,
            slashedAmount: ethers.parseEther("100"),
            timestamp: Math.floor(Date.now() / 1000),
            nonce: nonce,
            slashedTxData: '0x' + slashedTxData.toString('hex'),
            slashedProof: slashedProof,
            nonArrivalProof: nonArrivalProof,
            sourceShardRoot: '0x' + sourceRootBuf.toString('hex'),
            targetShardRoot: '0x' + targetRootBuf.toString('hex'),
            isVerified: false,
            isReimbursed: false,
            relayer: ethers.ZeroAddress
        };

        const values = [
            claim.payer,
            claim.merchant,
            claim.collateralToken,
            claim.slashedAmount,
            claim.timestamp,
            claim.nonce,
            claim.slashedTxData,
            claim.slashedProof,
            claim.nonArrivalProof,
            claim.sourceShardRoot,
            claim.targetShardRoot,
            claim.isVerified,
            claim.isReimbursed,
            claim.relayer
        ];

        const abiCoder = new ethers.AbiCoder();
        claimData = abiCoder.encode(
            ['(address,address,address,uint256,uint256,uint256,bytes,bytes[],bytes[],bytes32,bytes32,bool,bool,address)'],
            [values]
        );

        claimHash = ethers.keccak256(claimData);
    });

    describe("Claim Submission", function () {
        it("Should allow a relayer to submit a valid PoI claim on behalf of a payer", async function () {
            const signature = await payer.signMessage(ethers.getBytes(claimHash));
            await expect(poiProcessor.connect(relayer).submitPoIClaim(claimData, signature))
                .to.emit(poiProcessor, "PoIClaimSubmitted")
                .withArgs(payer.address, claimHash);
            expect(await poiProcessor.nextNonce(payer.address)).to.equal(claim.nonce + BigInt(1));
        });

        it("Should reject a claim with an invalid signature", async function () {
            const invalidSignature = await relayer.signMessage(ethers.getBytes(claimHash));
            await expect(poiProcessor.connect(relayer).submitPoIClaim(claimData, invalidSignature))
                .to.be.revertedWith("Invalid signature or payer address");
        });

        it("Should reject a claim with an invalid nonce", async function () {
            claim.nonce = await poiProcessor.nextNonce(payer.address) + BigInt(1);
            const values = Object.values(claim);
            const invalidClaimData = new ethers.AbiCoder().encode(['(address,address,address,uint256,uint256,uint256,bytes,bytes[],bytes[],bytes32,bytes32,bool,bool,address)'],[values]);
            const signature = await payer.signMessage(ethers.getBytes(ethers.keccak256(invalidClaimData)));
            await expect(poiProcessor.connect(relayer).submitPoIClaim(invalidClaimData, signature))
                .to.be.revertedWith("Invalid nonce");
        });

        it("Should reject a duplicate claim", async function () {
            const signature = await payer.signMessage(ethers.getBytes(claimHash));
            await poiProcessor.connect(relayer).submitPoIClaim(claimData, signature);
            await expect(poiProcessor.connect(relayer).submitPoIClaim(claimData, signature))
                .to.be.revertedWith("Claim already submitted");
        });
    });

    describe("Claim Verification", function () {
        beforeEach(async function() {
            const signature = await payer.signMessage(ethers.getBytes(claimHash));
            await poiProcessor.connect(relayer).submitPoIClaim(claimData, signature);
        });

        it("Should allow the owner to verify a valid claim", async function () {
            await poiProcessor.connect(owner).publishShardRoot(claim.sourceShardRoot);
            await poiProcessor.connect(owner).publishShardRoot(claim.targetShardRoot);

            await expect(poiProcessor.connect(owner).verifyPoIClaim(claimHash))
                .to.emit(poiProcessor, "PoIClaimVerified")
                .withArgs(claimHash, claim.slashedAmount);

            const storedClaim = await poiProcessor.claims(claimHash);
            expect(storedClaim.isVerified).to.be.true;
        });

        it("Should reject a verification attempt from a non-owner", async function () {
            await expect(poiProcessor.connect(relayer).verifyPoIClaim(claimHash))
                .to.be.revertedWith("Ownable: caller is not the owner");
        });

        it("Should reject a claim if the source shard root is not published", async function () {
            await poiProcessor.connect(owner).publishShardRoot(claim.targetShardRoot);
            await expect(poiProcessor.connect(owner).verifyPoIClaim(claimHash))
                .to.be.revertedWith("Source shard root not published");
        });
        
        it("Should reject a claim if the proof of departure is invalid", async function () {
            await poiProcessor.connect(owner).publishShardRoot(claim.sourceShardRoot);
            await poiProcessor.connect(owner).publishShardRoot(claim.targetShardRoot);

            const invalidClaim = { ...claim };
            const wrongKeyProof = (await sourceTrie.createProof(Buffer.from("wrong_key"))).map(n => '0x' + Buffer.from(n).toString('hex'));
            invalidClaim.slashedProof = wrongKeyProof;
            invalidClaim.nonce = await poiProcessor.nextNonce(payer.address);
            
            const values = Object.values(invalidClaim);
            const invalidClaimData = new ethers.AbiCoder().encode(['(address,address,address,uint256,uint256,uint256,bytes,bytes[],bytes[],bytes32,bytes32,bool,bool,address)'],[values]);
            const invalidClaimHash = ethers.keccak256(invalidClaimData);
            const signature = await payer.signMessage(ethers.getBytes(invalidClaimHash));
            
            await poiProcessor.connect(relayer).submitPoIClaim(invalidClaimData, signature);

            await expect(poiProcessor.connect(owner).verifyPoIClaim(invalidClaimHash))
                .to.emit(poiProcessor, "PoIClaimRejected");
        });

        it("Should reject a claim if the proof of non-arrival is invalid (i.e., the tx did arrive)", async function () {
            const newTargetTrie = new Trie();
            const txHashBytes = Buffer.from(ethers.keccak256('0x' + slashedTxData.toString('hex')).slice(2), 'hex');
            await newTargetTrie.put(txHashBytes, slashedTxData);
            const newTargetRoot = '0x' + Buffer.from(newTargetTrie.root()).toString('hex');
            
            const newNonArrivalProof = (await newTargetTrie.createProof(txHashBytes)).map(n => '0x' + Buffer.from(n).toString('hex'));

            await poiProcessor.connect(owner).publishShardRoot(claim.sourceShardRoot);
            await poiProcessor.connect(owner).publishShardRoot(newTargetRoot);
            
            const invalidClaim = { ...claim, targetShardRoot: newTargetRoot, nonArrivalProof: newNonArrivalProof, nonce: await poiProcessor.nextNonce(payer.address) };

            const values = Object.values(invalidClaim);
            const invalidClaimData = new ethers.AbiCoder().encode(['(address,address,address,uint256,uint256,uint256,bytes,bytes[],bytes[],bytes32,bytes32,bool,bool,address)'],[values]);
            const invalidClaimHash = ethers.keccak256(invalidClaimData);
            const signature = await payer.signMessage(ethers.getBytes(invalidClaimHash));
            
            await poiProcessor.connect(relayer).submitPoIClaim(invalidClaimData, signature);

            await expect(poiProcessor.connect(owner).verifyPoIClaim(invalidClaimHash))
                .to.emit(poiProcessor, "PoIClaimRejected");
        });
    });

    describe("Reimbursement", function () { 
        // TODO: Implement reimbursement tests
    });
});