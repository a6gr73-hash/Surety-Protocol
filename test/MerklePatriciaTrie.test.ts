import { expect } from "chai";
import { ethers } from "hardhat";
import { MerklePatriciaTrieMock } from "../typechain-types";
import { Trie } from "@ethereumjs/trie";
import { Buffer } from "buffer";

describe("MerklePatriciaTrie", function () {
    let mptLibrary: MerklePatriciaTrieMock;
    let trie: Trie;
    let root: Uint8Array;
    let inclusionProof: Uint8Array[];
    let nonInclusionProof: Uint8Array[];

    const testKey = Buffer.from("test-key");
    const testValue = Buffer.from("test-value");
    const nonExistentKey = Buffer.from("non-existent-key");

    before(async () => {
        const MockMPTLibrary = await ethers.getContractFactory("MerklePatriciaTrieMock");
        mptLibrary = await MockMPTLibrary.deploy();
        await mptLibrary.waitForDeployment();

        trie = new Trie();
        await trie.put(testKey, testValue);
        await trie.put(Buffer.from("another-key"), Buffer.from("another-value"));

        root = trie.root();
        inclusionProof = await trie.createProof(testKey);
        nonInclusionProof = await trie.createProof(nonExistentKey);
    });

    it("Should correctly verify a valid, realistic inclusion proof", async function () {
        const formattedProof = inclusionProof.map(node => '0x' + Buffer.from(node).toString('hex'));

        const isValid = await mptLibrary.verifyInclusion(
            formattedProof,
            '0x' + Buffer.from(root).toString('hex'),
            '0x' + testKey.toString('hex'),
            '0x' + testValue.toString('hex')
        );

        expect(isValid).to.be.true;
    });

    it("Should correctly verify a valid, realistic non-inclusion proof", async function () {
        const formattedProof = nonInclusionProof.map(node => '0x' + Buffer.from(node).toString('hex'));

        // Call get() and check that the returned value is empty (0x)
        const result = await mptLibrary.get(
            formattedProof,
            '0x' + Buffer.from(root).toString('hex'),
            '0x' + nonExistentKey.toString('hex')
        );

        expect(result).to.equal("0x");
    });

    it("Should fail to verify an inclusion proof with the wrong value", async function () {
         const formattedProof = inclusionProof.map(node => '0x' + Buffer.from(node).toString('hex'));
         const wrongValue = Buffer.from("wrong-value");

         const isValid = await mptLibrary.verifyInclusion(
            formattedProof,
            '0x' + Buffer.from(root).toString('hex'),
            '0x' + testKey.toString('hex'),
            '0x' + wrongValue.toString('hex')
        );

        expect(isValid).to.be.false;
    });
});
