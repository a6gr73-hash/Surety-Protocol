// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./RLPReader.sol";

library MerklePatriciaTrie {
    using RLPReader for RLPReader.RLPItem;
    using RLPReader for bytes;

    uint8 private constant BRANCH_VALUE_INDEX = 16;
    uint8 private constant HASH_SIZE = 32;

    // -------- Public API --------

    /**
     * @notice Retrieves a value from a Merkle Patricia Trie given a proof.
     * @param proof An array of RLP-encoded trie nodes, starting with the root node.
     * @param root The 32-byte keccak256 hash of the RLP-encoded root node.
     * @param key The key to look up in the trie.
     * @return The value associated with the key, or empty bytes if not found.
     */
    function get(bytes[] memory proof, bytes32 root, bytes memory key) internal pure returns (bytes memory) {
        (bytes memory result, , ) = _getWithIndex(proof, root, key);
        return result;
    }

    /**
     * @notice Verifies that a key/value pair is present in a Merkle Patricia Trie.
     * @param proof An array of RLP-encoded trie nodes.
     * @param root The 32-byte keccak256 hash of the RLP-encoded root node.
     * @param key The key to verify.
     * @param value The value to verify.
     * @return True if the key/value pair is proven to be in the trie, false otherwise.
     */
    function verifyInclusion(bytes[] memory proof, bytes32 root, bytes memory key, bytes memory value)
        internal
        pure
        returns (bool)
    {
        bytes memory result = get(proof, root, key);
        return keccak256(result) == keccak256(value);
    }

    // -------- Debug Helpers --------

    function getForDebug(bytes[] memory proof, bytes32 root, bytes memory key)
        internal
        pure
        returns (bytes memory finalValue, bytes memory debugRemainingPath, bytes memory debugLeafPath)
    {
        return _getWithIndex(proof, root, key);
    }

    // -------- Core Implementation --------

    function _getWithIndex(bytes[] memory proof, bytes32 root, bytes memory key)
        private
        pure
        returns (bytes memory finalValue, bytes memory debugRemainingPath, bytes memory debugLeafPath)
    {
        require(proof.length > 0, "MPT: proof cannot be empty");
        bytes memory fullPath = _getNibbleKey(key);
        uint256 pathIdx = 0;

        bytes memory currentNodeBytes = proof[0];
        require(keccak256(currentNodeBytes) == root, "MPT: invalid root");
        RLPReader.RLPItem[] memory currentNode = currentNodeBytes.toRlpItem().toList();
        uint256 proofIdx = 1;

        while (true) {
            if (currentNode.length == 2) { // Leaf or Extension Node
                bytes memory encodedPath = currentNode[0].toBytes();
                bytes memory nodePath = _decodeNodePath(encodedPath);

                if (_isLeafNode(encodedPath)) {
                    debugRemainingPath = _subslice(fullPath, pathIdx);
                    debugLeafPath = nodePath;
                    if ((fullPath.length - pathIdx) == nodePath.length && _pathStartsWithAt(fullPath, pathIdx, nodePath)) {
                        finalValue = currentNode[1].toBytes();
                    }
                    return (finalValue, debugRemainingPath, debugLeafPath);
                } else { // Extension Node
                    if (!_pathStartsWithAt(fullPath, pathIdx, nodePath)) {
                        return ("", "", "");
                    }
                    pathIdx += nodePath.length;
                    
                    RLPReader.RLPItem memory item = currentNode[1];
                    if (item.isList()) {
                        // Embedded child node
                        currentNode = item.toList();
                    } else {
                        // Hash pointer
                        bytes memory payload = item.toBytes();
                        require(payload.length == HASH_SIZE, "MPT: hash pointer must be 32 bytes");
                        bytes32 nodeHash;
                        assembly { nodeHash := mload(add(payload, 32)) }
                        
                        require(proofIdx < proof.length, "MPT: proof too short for extension");
                        currentNodeBytes = proof[proofIdx];
                        require(keccak256(currentNodeBytes) == nodeHash, "MPT: invalid extension proof");
                        currentNode = currentNodeBytes.toRlpItem().toList();
                        proofIdx++;
                    }
                }
            } else if (currentNode.length == 17) { // Branch Node
                if (pathIdx == fullPath.length) {
                    finalValue = currentNode[BRANCH_VALUE_INDEX].toBytes();
                    return (finalValue, debugRemainingPath, debugLeafPath);
                }

                uint8 nibble = uint8(fullPath[pathIdx]);
                require(nibble < 16, "MPT: invalid nibble index");
                pathIdx++;

                RLPReader.RLPItem memory item = currentNode[nibble];
                if (item.len == 0) return ("", "", "");

                if (item.isList()) {
                    // Embedded child node
                    currentNode = item.toList();
                } else {
                    // Hash pointer
                    bytes memory payload = item.toBytes();
                    require(payload.length == HASH_SIZE, "MPT: hash pointer must be 32 bytes");
                    bytes32 nodeHash;
                    assembly { nodeHash := mload(add(payload, 32)) }

                    require(proofIdx < proof.length, "MPT: proof too short for branch");
                    currentNodeBytes = proof[proofIdx];
                    require(keccak256(currentNodeBytes) == nodeHash, "MPT: invalid branch proof");

                    currentNode = currentNodeBytes.toRlpItem().toList();
                    proofIdx++;
                }
            } else {
                revert("MPT: Invalid node structure");
            }
        }
    }

    // -------- Helper Functions --------

    function _getNibbleKey(bytes memory key) internal pure returns (bytes memory) {
        bytes memory nibbles = new bytes(key.length * 2);
        for (uint256 i = 0; i < key.length; i++) {
            uint8 b = uint8(key[i]);
            nibbles[i * 2] = bytes1(b >> 4);
            nibbles[i * 2 + 1] = bytes1(b & 0x0F);
        }
        return nibbles;
    }

    function _decodeNodePath(bytes memory data) internal pure returns (bytes memory) {
        if (data.length == 0) return "";
        uint8 prefix = uint8(data[0]);
        bool isOddLen = ((prefix >> 4) % 2) == 1;
        uint offset = 1;
        uint pathLen = isOddLen ? (data.length - 1) * 2 + 1 : (data.length - 1) * 2;
        bytes memory path = new bytes(pathLen);
        uint pathIdx = 0;
        if (isOddLen) {
            path[pathIdx++] = bytes1(prefix & 0x0F);
        }
        for (uint i = offset; i < data.length; i++) {
            path[pathIdx++] = bytes1(uint8(data[i]) >> 4);
            path[pathIdx++] = bytes1(uint8(data[i]) & 0x0F);
        }
        return path;
    }

    function _isLeafNode(bytes memory data) private pure returns (bool) {
        if (data.length == 0) return false;
        return (uint8(data[0]) >> 4) >= 2;
    }

    function _pathStartsWithAt(bytes memory path, uint256 start, bytes memory subpath) private pure returns (bool) {
        if (path.length < start || path.length - start < subpath.length) return false;
        for (uint256 i = 0; i < subpath.length; i++) {
            if (path[start + i] != subpath[i]) return false;
        }
        return true;
    }

    function _subslice(bytes memory data, uint256 start) private pure returns (bytes memory) {
        if (start >= data.length) return "";
        uint256 len = data.length - start;
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = data[start + i];
        }
        return out;
    }
}
