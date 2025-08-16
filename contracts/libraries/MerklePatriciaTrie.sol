// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./RLPReader.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title MerklePatriciaTrie
 * @dev A modular and gas-efficient library for verifying Merkle Patricia Trie proofs.
 * Designed to be reusable for on-chain proof verification in a sharded environment.
 */
library MerklePatriciaTrie {
    using RLPReader for bytes;
    using RLPReader for RLPReader.RLPItem; // Added this line
    using SafeMath for uint256;

    // The empty trie hash
    bytes32 constant EMPTY_TRIE_HASH =
        0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421;

    /**
     * @notice Verifies a Merkle Patricia Trie inclusion proof.
     * @param proof The Merkle Patricia proof, an array of RLP-encoded nodes.
     * @param root The hash of the trie's root node.
     * @param key The key to verify.
     * @param value The value to verify.
     * @return True if the proof is valid, false otherwise.
     */
    function verifyInclusion(
        bytes[] memory proof,
        bytes32 root,
        bytes memory key,
        bytes memory value
    ) internal pure returns (bool) {
        if (root == EMPTY_TRIE_HASH) {
            return false;
        }

        bytes memory encodedProof = _flattenProof(proof);

        bytes memory path = new bytes(key.length * 2);
        for (uint256 i = 0; i < key.length; i++) {
            path[i * 2] = bytes1(uint8(key[i]) >> 4);
            path[i * 2 + 1] = bytes1(uint8(key[i]) & 0x0F);
        }

        bytes memory actualValue = _traverseTrie(
            encodedProof,
            root,
            path,
            true
        );

        return
            actualValue.length > 0 &&
            keccak256(actualValue) == keccak256(value);
    }

    /**
     * @notice Verifies a Merkle Patricia Trie non-inclusion proof.
     * @param proof The Merkle Patricia proof, an array of RLP-encoded nodes.
     * @param root The hash of the trie's root node.
     * @param key The key to verify.
     * @return True if the proof is valid, false otherwise.
     */
    function verifyNonInclusion(
        bytes[] memory proof,
        bytes32 root,
        bytes memory key
    ) internal pure returns (bool) {
        if (root == EMPTY_TRIE_HASH) {
            return true;
        }

        bytes memory encodedProof = _flattenProof(proof);

        bytes memory path = new bytes(key.length * 2);
        for (uint256 i = 0; i < key.length; i++) {
            path[i * 2] = bytes1(uint8(key[i]) >> 4);
            path[i * 2 + 1] = bytes1(uint8(key[i]) & 0x0F);
        }

        bytes memory value = _traverseTrie(encodedProof, root, path, false);

        return value.length == 0;
    }

    /**
     * @dev Flattens a proof array into a single byte array for easier parsing.
     * @param proof The Merkle Patricia proof, an array of RLP-encoded nodes.
     * @return The flattened proof as a single byte array.
     */
    /**
     * @dev Flattens a proof array into a single byte array for easier parsing.
     * @param proof The Merkle Patricia proof, an array of RLP-encoded nodes.
     * @return The flattened proof as a single byte array.
     */
    function _flattenProof(
        bytes[] memory proof
    ) private pure returns (bytes memory) {
        uint256 totalLength = 0;
        for (uint256 i = 0; i < proof.length; i++) {
            totalLength = totalLength.add(proof[i].length);
        }
        bytes memory flatProof = new bytes(totalLength);
        uint256 offset = 0;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes memory node = proof[i];
            for (uint256 j = 0; j < node.length; j++) {
                flatProof[offset.add(j)] = node[j];
            }
            offset = offset.add(node.length);
        }
        return flatProof;
    }

    /**
     * @dev Internal function to get a single node from a flattened proof.
     * @param encodedProof The flattened byte array containing the proof nodes.
     * @param index The starting index of the node to extract.
     * @return The RLP-encoded node as a byte array.
     */
    function _getNodeFromProof(
        bytes memory encodedProof,
        uint256 index
    ) private pure returns (bytes memory) {
        uint256 start;
        uint256 len;
        (start, len) = encodedProof._findNextItem(index);

        if (len == 0 || index.add(len) > encodedProof.length) {
            revert("Proof too short or invalid RLP item.");
        }

        bytes memory node = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            node[i] = encodedProof[start.add(i)];
        }

        return node;
    }

    /**
     * @dev Internal function to get the next node from a flattened proof.
     * @param encodedProof The flattened byte array containing the proof nodes.
     * @param index The starting index of the node to extract.
     * @return The next RLP-encoded node as a byte array.
     */
    function _getNextNodeFromProof(
        bytes memory encodedProof,
        uint256 index
    ) private pure returns (bytes memory) {
        uint256 start;
        uint256 len;
        (start, len) = encodedProof._findNextItem(index);

        uint256 nextIndex = index.add(len);
        (start, len) = encodedProof._findNextItem(nextIndex);

        if (len == 0 || nextIndex.add(len) > encodedProof.length) {
            revert("Proof too short or invalid RLP item.");
        }

        bytes memory node = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            node[i] = encodedProof[nextIndex.add(i)];
        }

        return node;
    }

    /**
     * @dev Internal function to decode an MPT prefix.
     * @param encodedPath The RLP-encoded path segment.
     * @return path The decoded path nibbles.
     * @return type The node type (1 for extension, 2 for leaf).
     */
    function _decodePrefix(
        bytes memory encodedPath
    ) private pure returns (bytes memory, uint8) {
        uint8 prefix = uint8(encodedPath[0]);
        uint8 offset;

        if ((prefix & 0x10) == 0x10) {
            offset = 1;
        } else {
            offset = 2;
        }

        bytes memory path = new bytes(encodedPath.length - offset);

        for (uint256 i = 0; i < path.length; i++) {
            path[i] = encodedPath[i + offset];
        }

        return (path, (prefix & 0x20) == 0x20 ? 2 : 1);
    }

    /**
     * @dev Navigates the trie to find a node's value or prove its non-existence.
     * @param encodedProof The flattened proof byte array.
     * @param root The trie's root hash.
     * @param key The key to look up, in nibble format.
     * @param inclusion Whether we are verifying inclusion or non-inclusion.
     * @return The value of the found node, or an empty byte array if not found.
     */
    function _traverseTrie(
        bytes memory encodedProof,
        bytes32 root,
        bytes memory key,
        bool inclusion
    ) private pure returns (bytes memory) {
        bytes32 currentNodeHash = root;
        uint256 proofIndex = 0;
        uint256 pathIndex = 0;

        while (pathIndex < key.length && proofIndex < encodedProof.length) {
            bytes memory currentEncodedNode = _getNodeFromProof(
                encodedProof,
                proofIndex
            );

            // Check if it's a hash node
            if (currentEncodedNode.length == 32) {
                // If it's a hash, the next node must match this hash
                currentNodeHash = bytes32(currentEncodedNode);
                proofIndex = proofIndex.add(currentEncodedNode.length);
                continue;
            }

            // Verify the current node's hash against the expected hash
            if (keccak256(currentEncodedNode) != currentNodeHash) {
                revert("Invalid proof node hash during traversal.");
            }

            // Move to the next node in the proof
            proofIndex = proofIndex.add(currentEncodedNode.length);

            // RLP decode the current node
            RLPReader.RLPItem memory nodeItem = currentEncodedNode.toRlpItem();
            RLPReader.RLPItem[] memory decodedNode = nodeItem.toList();

            // Handle different node types
            if (decodedNode.length == 2) {
                // Extension or Leaf node
                (bytes memory sharedPath, uint8 nodeType) = _decodePrefix(
                    decodedNode[0].toBytes()
                );

                // Verify path match
                for (uint256 i = 0; i < sharedPath.length; i++) {
                    if (
                        pathIndex.add(i) >= key.length ||
                        key[pathIndex.add(i)] != sharedPath[i]
                    ) {
                        // Key does not match the path, this is a non-inclusion proof
                        return new bytes(0);
                    }
                }

                pathIndex = pathIndex.add(sharedPath.length);

                if (nodeType == 2) {
                    // This is a leaf node, return the value
                    return decodedNode[1].toBytes();
                } else {
                    // This is an extension node, the next node's hash is the last element
                    bytes memory nextHashBytes = decodedNode[1].toBytes();
                    if (nextHashBytes.length != 32) {
                        revert("Extension node points to an invalid hash.");
                    }
                    currentNodeHash = bytes32(nextHashBytes);
                }
            } else if (decodedNode.length == 17) {
                // Branch node
                uint8 nibble = uint8(key[pathIndex]);
                bytes memory nextNodeHashBytes = decodedNode[nibble].toBytes();

                // If this branch is empty, it's a non-inclusion proof
                if (nextNodeHashBytes.length == 0) {
                    return new bytes(0);
                }

                // Move to the next node
                pathIndex++;
                if (nextNodeHashBytes.length != 32) {
                    revert("Branch node points to an invalid hash.");
                }
                currentNodeHash = bytes32(nextNodeHashBytes);
            } else {
                revert("Invalid node type: not 2 or 17 elements.");
            }
        }

        // End of proof or path, check for final value
        if (pathIndex == key.length) {
            return new bytes(0); // This means the key was a partial path and no value was found
        }

        return new bytes(0);
    }
}