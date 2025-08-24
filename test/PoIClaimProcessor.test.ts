import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { PoIClaimProcessor } from "../typechain-types";
import { Trie } from "@ethereumjs/trie";
import { Buffer } from "buffer";

describe("PoIClaimProcessor", function () {
    let poiProcessor: PoIClaimProcessor;
    let owner: SignerWithAddress;
    let relayer: SignerWithAddress;

    const paymentId = ethers.randomBytes(32);

    beforeEach(async function () {
        [owner, relayer] = await ethers.getSigners();

        const PoIProcessorFactory = await ethers.getContractFactory("PoIClaimProcessor");
        poiProcessor = await PoIProcessorFactory.deploy();
        await poiProcessor.waitForDeployment();
    });

    it("Should allow the owner to publish a root", async function () {
        const root = ethers.randomBytes(32);
        await expect(poiProcessor.connect(owner).publishShardRoot(root))
            .to.emit(poiProcessor, "ShardRootPublished")
            .withArgs(root);
        expect(await poiProcessor.publishedRoots(root)).to.be.true;
    });

    it("Should prevent non-owners from publishing a root", async function () {
        const root = ethers.randomBytes(32);
        await expect(poiProcessor.connect(relayer).publishShardRoot(root))
            .to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("Should process a valid non-arrival proof", async function () {
        const nonExistentKey = Buffer.from("this-key-does-not-exist");

        const trie = new Trie();
        await trie.put(Buffer.from("some-other-key"), Buffer.from("some-value"));

        const proof = await trie.createProof(nonExistentKey);
        const formattedProof = proof.map(node => '0x' + Buffer.from(node).toString('hex'));

        // ⭐ FIX: Convert the Uint8Array from trie.root() to a Buffer before creating the hex string.
        const root = '0x' + Buffer.from(trie.root()).toString('hex');
        await poiProcessor.connect(owner).publishShardRoot(root);
        
        await expect(poiProcessor.connect(relayer).processNonArrivalProof(paymentId, root, '0x' + nonExistentKey.toString('hex'), formattedProof))
            .to.emit(poiProcessor, "PayoutAuthorized")
            .withArgs(paymentId);
        
        expect(await poiProcessor.isPayoutAuthorized(paymentId)).to.be.true;
    });

    it("Should fail if the root is not published", async function () {
        const root = ethers.randomBytes(32);
        const dummyProof = [ethers.randomBytes(32)];
        await expect(poiProcessor.connect(relayer).processNonArrivalProof(paymentId, root, "0x", dummyProof))
            .to.be.revertedWith("PoI: Target root not published");
    });
});
