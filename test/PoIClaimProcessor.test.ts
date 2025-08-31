import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { PoIClaimProcessor } from "../typechain-types";

// Off-chain library for generating proofs
import { Trie } from "@ethereumjs/trie";
import { Buffer } from "buffer";

describe("PoIClaimProcessor (Production)", function () {
    let poiProcessor: PoIClaimProcessor;
    let owner: SignerWithAddress;
    let watcher: SignerWithAddress;
    let otherUser: SignerWithAddress;

    beforeEach(async function () {
        [owner, watcher, otherUser] = await ethers.getSigners();

        const PoIProcessorFactory = await ethers.getContractFactory("PoIClaimProcessor");
        poiProcessor = await PoIProcessorFactory.deploy();
        await poiProcessor.waitForDeployment();
    });

    describe("Root Publication", function () {
        it("Should allow the owner to publish a shard root", async function () {
            const root = ethers.randomBytes(32);
            await expect(poiProcessor.connect(owner).publishShardRoot(root))
                .to.emit(poiProcessor, "ShardRootPublished")
                .withArgs(ethers.hexlify(root));
            expect(await poiProcessor.publishedRoots(root)).to.be.true;
        });

        it("Should prevent non-owners from publishing a root", async function () {
            const root = ethers.randomBytes(32);
            await expect(poiProcessor.connect(watcher).publishShardRoot(root))
                .to.be.revertedWith("Ownable: caller is not the owner");
        });

        it("Should prevent publishing the same root twice", async function () {
            const root = ethers.randomBytes(32);
            await poiProcessor.connect(owner).publishShardRoot(root);
            await expect(poiProcessor.connect(owner).publishShardRoot(root))
                .to.be.revertedWith("PoI: Root already published");
        });
    });

    describe("Proof Processing", function () {
        let trie: Trie;
        let root: string;
        let includedKey: Buffer;
        let includedValue: Buffer;
        let nonExistentKey: Buffer;
        let inclusionProof: string[];
        let nonInclusionProof: string[];
        const paymentId = ethers.randomBytes(32);

        beforeEach(async function () {
            // 1. Setup an off-chain trie with some data
            trie = new Trie();
            includedKey = Buffer.from(ethers.keccak256(ethers.toUtf8Bytes("real_tx_data")));
            includedValue = Buffer.from("this-is-a-real-tx-value");
            nonExistentKey = Buffer.from(ethers.keccak256(ethers.toUtf8Bytes("missing_tx_data")));

            await trie.put(includedKey, includedValue);
            await trie.put(Buffer.from(ethers.keccak256(ethers.toUtf8Bytes("another_tx"))), Buffer.from("some-other-value"));

            // 2. Generate the root hash of the trie
            root = '0x' + Buffer.from(trie.root()).toString('hex');
            
            // 3. Generate a proof for a key that IS in the trie (inclusion proof)
            const rawInclusionProof = await trie.createProof(includedKey);
            inclusionProof = rawInclusionProof.map(node => '0x' + Buffer.from(node).toString('hex'));
            
            // 4. Generate a proof for a key that IS NOT in the trie (non-inclusion proof)
            const rawNonInclusionProof = await trie.createProof(nonExistentKey);
            nonInclusionProof = rawNonInclusionProof.map(node => '0x' + Buffer.from(node).toString('hex'));

            // 5. Publish the trusted root on-chain
            await poiProcessor.connect(owner).publishShardRoot(root);
        });

        it("should process a valid non-arrival (non-inclusion) proof", async function () {
            await expect(poiProcessor.connect(watcher).processNonArrivalProof(paymentId, root, nonExistentKey, nonInclusionProof))
                .to.emit(poiProcessor, "PayoutAuthorized")
                .withArgs(ethers.hexlify(paymentId), watcher.address);

            expect(await poiProcessor.isPayoutAuthorized(paymentId)).to.be.true;
            expect(await poiProcessor.getProofSubmitter(paymentId)).to.equal(watcher.address);
        });

        it("should reject a proof if the root has not been published", async function () {
            const unpublishedRoot = ethers.randomBytes(32);
            await expect(poiProcessor.connect(watcher).processNonArrivalProof(paymentId, unpublishedRoot, nonExistentKey, nonInclusionProof))
                .to.be.revertedWith("PoI: Target root not published");
        });

        it("should reject a proof if the payment ID is already authorized", async function () {
            await poiProcessor.connect(watcher).processNonArrivalProof(paymentId, root, nonExistentKey, nonInclusionProof);

            await expect(poiProcessor.connect(otherUser).processNonArrivalProof(paymentId, root, nonExistentKey, nonInclusionProof))
                .to.be.revertedWith("PoI: Payout already authorized");
        });

        it("should reject a proof of inclusion", async function () {
            // Critical security test: The function must reject proofs that show a key EXISTS.
            await expect(poiProcessor.connect(watcher).processNonArrivalProof(paymentId, root, includedKey, inclusionProof))
                .to.be.revertedWith("PoI: Key was found in the trie (inclusion proof provided)");
        });
    });
});