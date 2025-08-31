import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MerklePatriciaTrieMock } from "../typechain-types";


describe("MerklePatriciaTrie Mock", function () {
    let mpt: MerklePatriciaTrieMock;
    let owner: SignerWithAddress;
    let addr1: SignerWithAddress;

    beforeEach(async function () {
        [owner, addr1] = await ethers.getSigners();

        const MPTFactory = await ethers.getContractFactory("MerklePatriciaTrieMock");
        mpt = (await MPTFactory.deploy()) as unknown as MerklePatriciaTrieMock;
        await mpt.waitForDeployment();
    });

    it("Should allow inserting a key/value pair", async function () {
        const key = ethers.hexlify(ethers.randomBytes(32));
        const value = ethers.hexlify(ethers.randomBytes(32));

        // Use the proper method signature
        await expect(mpt.set(key, value)).to.not.be.reverted;
    });

    it("Should verify inclusion proofs", async function () {
        const key = ethers.hexlify(ethers.randomBytes(32));
        const value = ethers.hexlify(ethers.randomBytes(32));

        await mpt.set(key, value);
        const root = await mpt.getRoot();

        // Assuming generateProof returns a proof array (Uint8Array[])
        const proof = await mpt.generateProof(key);

        // Correctly call verifyInclusion with 5 arguments (proof, root, key, value, overrides)
        const isIncluded = await mpt.verifyInclusion(
            proof as unknown as any[],
            root,
            key,
            value
        );
        expect(isIncluded).to.be.true;
    });

    it("Should reject invalid proofs", async function () {
        const key = ethers.hexlify(ethers.randomBytes(32));
        const value = ethers.hexlify(ethers.randomBytes(32));
        await mpt.set(key, value);
        const root = await mpt.getRoot();

        // Tamper with proof to make it invalid
        const fakeProof = [ethers.hexlify(ethers.randomBytes(32))];

        const isIncluded = await mpt.verifyInclusion(
            fakeProof as unknown as any[],
            root,
            key,
            value
        );
        expect(isIncluded).to.be.false;
    });
});
