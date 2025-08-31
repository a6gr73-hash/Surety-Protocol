// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "./RLPReader.sol";

library MerklePatriciaTrie {
    using RLPReader for RLPReader.RLPItem;
    using RLPReader for bytes;

    /**
     * @dev Returns the value of a key in a Merkle Patricia Trie using a proof.
     * @param proof Array of RLP-encoded nodes leading from root to the key.
     * @param root Root hash of the trie.
     * @param key The key to look up.
     */
    function get(
        bytes[] memory proof,
        bytes32 root,
        bytes memory key
    ) internal pure returns (bytes memory value) {
        // name the return variable
        bytes memory path = _getNibbleKey(key);
        uint256 proofIdx = 0;

        if (proof.length == 0) {
            return ""; // explicitly return empty bytes
        }

        bytes memory currentNodeBytes = proof[proofIdx++];
        require(keccak256(currentNodeBytes) == root, "MPT: Invalid root");
        RLPReader.RLPItem[] memory currentNode = currentNodeBytes
            .toRlpItem()
            .toList();

        while (path.length > 0) {
            if (proofIdx > proof.length) return "";

            if (currentNode.length == 17) {
                uint8 nibble = uint8(path[0]);
                path = _pathSlice(path, 1);
                RLPReader.RLPItem memory child = currentNode[nibble];
                if (child.len == 0) return "";

                bytes memory childBytes = child.toBytes();
                if (child.len < 32) {
                    currentNodeBytes = childBytes;
                    currentNode = currentNodeBytes.toRlpItem().toList();
                } else {
                    bytes32 nodeHash = bytes32(childBytes);
                    require(proofIdx < proof.length, "MPT: Proof too short");
                    currentNodeBytes = proof[proofIdx++];
                    require(
                        keccak256(currentNodeBytes) == nodeHash,
                        "MPT: Invalid proof"
                    );
                    currentNode = currentNodeBytes.toRlpItem().toList();
                }
            } else if (currentNode.length == 2) {
                bytes memory nodePath = _decodeNodePath(
                    currentNode[0].toBytes()
                );
                if (_pathStartsWith(path, nodePath)) {
                    path = _pathSlice(path, nodePath.length);
                    if (_isLeafNode(currentNode[0].toBytes())) {
                        if (path.length == 0) return currentNode[1].toBytes();
                        return "";
                    } else {
                        bytes32 nodeHash = bytes32(currentNode[1].toBytes());
                        require(
                            proofIdx < proof.length,
                            "MPT: Proof too short"
                        );
                        currentNodeBytes = proof[proofIdx++];
                        require(
                            keccak256(currentNodeBytes) == nodeHash,
                            "MPT: Invalid proof"
                        );
                        currentNode = currentNodeBytes.toRlpItem().toList();
                    }
                } else {
                    return "";
                }
            } else {
                revert("MPT: Invalid node");
            }
        }

        if (currentNode.length == 17) {
            value = currentNode[16].toBytes();
        } else {
            value = "";
        }
    }

    /**
     * @dev Verifies inclusion of a key/value pair in the trie.
     */
    function verifyInclusion(
        bytes[] memory proof,
        bytes32 root,
        bytes memory key,
        bytes memory value
    ) internal pure returns (bool) {
        return keccak256(get(proof, root, key)) == keccak256(value);
    }

    function _getNibbleKey(
        bytes memory key
    ) private pure returns (bytes memory) {
        bytes memory nibbles = new bytes(key.length * 2);
        for (uint256 i = 0; i < key.length; i++) {
            uint8 b = uint8(key[i]);
            nibbles[i * 2] = bytes1(b >> 4);
            nibbles[i * 2 + 1] = bytes1(b & 0x0F);
        }
        return nibbles;
    }

    function _decodeNodePath(
        bytes memory data
    ) private pure returns (bytes memory path) {
        uint8 prefix = uint8(data[0]);
        if ((prefix & 0x10) == 0x10) {
            // odd length flag
            path = new bytes(data.length * 2 - 1);
            path[0] = bytes1(prefix & 0x0F);
            for (uint256 i = 1; i < data.length; i++) {
                path[i * 2 - 1] = bytes1(uint8(data[i]) >> 4);
                path[i * 2] = bytes1(uint8(data[i]) & 0x0F);
            }
        } else {
            path = new bytes(data.length * 2 - 2);
            for (uint256 i = 1; i < data.length; i++) {
                path[(i - 1) * 2] = bytes1(uint8(data[i]) >> 4);
                path[(i - 1) * 2 + 1] = bytes1(uint8(data[i]) & 0x0F);
            }
        }
    }

    function _isLeafNode(bytes memory data) private pure returns (bool) {
        return (uint8(data[0]) & 0x20) == 0x20;
    }

    function _pathStartsWith(
        bytes memory path,
        bytes memory subpath
    ) private pure returns (bool) {
        if (path.length < subpath.length) return false;
        for (uint256 i = 0; i < subpath.length; i++) {
            if (path[i] != subpath[i]) return false;
        }
        return true;
    }

    function _pathSlice(
        bytes memory path,
        uint256 start
    ) private pure returns (bytes memory) {
        if (start >= path.length) return new bytes(0);
        uint256 len = path.length - start;
        bytes memory subpath = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            subpath[i] = path[i + start];
        }
        return subpath;
    }
}
