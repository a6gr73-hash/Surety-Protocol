// contracts/MerklePatriciaTrieMock.sol

// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./libraries/MerklePatriciaTrie.sol";
import "./libraries/RLPReader.sol"; // Import RLPReader

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

    function getForDebug(
        bytes[] memory proof, 
        bytes32 root, 
        bytes memory key
    ) public pure returns (bytes memory value, bytes memory remainingPath, bytes memory leafPath) {
        return MerklePatriciaTrie.getForDebug(proof, root, key);
    }

    function testGetNibbleKey(bytes memory key) public pure returns (bytes memory) {
        return MerklePatriciaTrie._getNibbleKey(key);
    }

    function testDecodeNodePath(bytes memory data) public pure returns (bytes memory) {
        return MerklePatriciaTrie._decodeNodePath(data);
    }

    // ⭐ NEW: Exposing our own RLPReader for testing ⭐
    function testRlpDecodeLeafNode(bytes memory leafNodeData) public pure returns (bytes memory) {
        RLPReader.RLPItem memory item = RLPReader.toRlpItem(leafNodeData);
        RLPReader.RLPItem[] memory decodedList = RLPReader.toList(item);
        
        require(decodedList.length == 2, "Leaf node must have 2 elements");
        
        // Return the first element, which is the encodedPath
        return RLPReader.toBytes(decodedList[0]);
    }
}
