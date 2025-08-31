// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;


import "./libraries/MerklePatriciaTrie.sol";

contract MerklePatriciaTrieMock {
    mapping(bytes32 => bytes) private store;

    function put(bytes32 key, bytes memory value) external {
        store[key] = value;
    }

    function get(
        bytes[] memory proof,
        bytes32 root,
        bytes memory key
    ) external pure returns (bytes memory) {
        return MerklePatriciaTrie.get(proof, root, key);
    }

    function makeProof(bytes32 key) external view returns (bytes[] memory) {
        bytes; // ✅ declare and allocate
        proof[0] = store[key]; // ✅ assign value
        return proof;
    }
}