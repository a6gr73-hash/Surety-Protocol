// test/MerklePatriciaTrie.test.ts

import { expect } from "chai";
import { ethers } from "hardhat";
// No external RLP library needed
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

    it("Should correctly verify a valid, realistic inclusion proof", async function () { /* ... unchanged ... */ });
    it("Should correctly verify a valid, realistic non-inclusion proof", async function () { /* ... unchanged ... */ });
    it("Should fail to verify an inclusion proof with the wrong value", async function () { /* ... unchanged ... */ });

    describe("Internal Helper Functions", function() {
        it("DEBUG: Should show the output of _getNibbleKey", async function() { /* ... unchanged ... */ });

        it("DEBUG: Should show the output of _decodeNodePath", async function() {
            const leafNodeBytes = '0x' + Buffer.from(inclusionProof[inclusionProof.length - 1]).toString('hex');
            
            // ⭐ FIX: Using our own library via the mock contract ⭐
            const encodedPath = await mptLibrary.testRlpDecodeLeafNode(leafNodeBytes);

            console.log("\n--- MPT DEBUGGER (_decodeNodePath) ---");
            console.log("   ➡ Input (Encoded Path):", encodedPath);
            
            const decodedPath = await mptLibrary.testDecodeNodePath(encodedPath);
            console.log("   ➡ Output (Decoded Path):", decodedPath);
            console.log("----------------------------------------\n");

            expect(decodedPath).to.not.be.null;
        });
    });
});
