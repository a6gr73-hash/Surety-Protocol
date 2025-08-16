// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./libraries/MerklePatriciaTrie.sol";

/**
 * @title MerklePatriciaTrieMock
 * @dev A simple wrapper to test the public functions of the MerklePatriciaTrie library.
 */
contract MerklePatriciaTrieMock {
    function verifyInclusion(
        bytes[] memory proof, 
        bytes32 root, 
        bytes memory key, 
        bytes memory value
    ) public pure returns (bool) {
        return MerklePatriciaTrie.verifyInclusion(proof, root, key, value);
    }

    function get(
        bytes[] memory proof, 
        bytes32 root, 
        bytes memory key
    ) public pure returns (bytes memory) {
        return MerklePatriciaTrie.get(proof, root, key);
    }
}




