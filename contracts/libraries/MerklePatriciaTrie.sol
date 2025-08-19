// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./RLPReader.sol";

library MerklePatriciaTrie {
    using RLPReader for RLPReader.RLPItem;
    using RLPReader for bytes;

    uint8 private constant BRANCH_VALUE_INDEX = 16;
    uint8 private constant HASH_SIZE = 32;

    // -------- Public/Internal API (unchanged) --------

    function get(
        bytes[] memory proof,
        bytes32 root,
        bytes memory key
    ) internal pure returns (bytes memory) {
        (bytes memory result, , ) = _get(proof, root, key);
        return result;
    }

    function getForDebug(
        bytes[] memory proof,
        bytes32 root,
        bytes memory key
    ) internal pure returns (bytes memory, bytes memory, bytes memory) {
        return _get(proof, root, key);
    }

    // Optional: expose the preslice path for quick A/B if needed
    function getForDebugPreslice(
        bytes[] memory proof,
        bytes32 root,
        bytes memory key
    ) internal pure returns (bytes memory, bytes memory, bytes memory) {
        return _getPreslice(proof, root, key);
    }

    function verifyInclusion(
        bytes[] memory proof,
        bytes32 root,
        bytes memory key,
        bytes memory value
    ) internal pure returns (bool) {
        bytes memory result = get(proof, root, key);
        return (keccak256(result) == keccak256(value) &&
            result.length == value.length);
    }

    // -------- Optimized version (no per-step slicing) --------

    function _get(
        bytes[] memory proof,
        bytes32 root,
        bytes memory key
    )
        private
        pure
        returns (
            bytes memory finalValue,
            bytes memory debugRemainingPath,
            bytes memory debugLeafPath
        )
    {
        return _getWithIndex(proof, root, key);
    }

    function _getWithIndex(
        bytes[] memory proof,
        bytes32 root,
        bytes memory key
    )
        private
        pure
        returns (
            bytes memory finalValue,
            bytes memory debugRemainingPath,
            bytes memory debugLeafPath
        )
    {
        require(proof.length > 0, "MPT: proof cannot be empty");
        bytes memory fullPath = _getNibbleKey(key);
        uint256 pathIdx = 0;

        bytes memory currentNodeBytes = proof[0];
        require(keccak256(currentNodeBytes) == root, "MPT: invalid root");
        RLPReader.RLPItem[] memory currentNode = currentNodeBytes
            .toRlpItem()
            .toList();
        uint256 proofIdx = 1;

        while (true) {
            if (currentNode.length == 2) {
                // Leaf or Extension Node
                bytes memory encodedPath = currentNode[0].toBytes();
                bytes memory nodePath = _decodeNodePath(encodedPath);

                if (_isLeafNode(encodedPath)) {
                    // At a leaf: for debug, report remaining and leaf path
                    debugRemainingPath = _subslice(fullPath, pathIdx);
                    debugLeafPath = nodePath;

                    // Match only if remaining path equals the leaf's path
                    if (
                        (fullPath.length - pathIdx) == nodePath.length &&
                        _pathStartsWithAt(fullPath, pathIdx, nodePath)
                    ) {
                        finalValue = currentNode[1].toBytes();
                    }
                    return (finalValue, debugRemainingPath, debugLeafPath);
                } else {
                    // Extension must be a prefix of the remaining path
                    if (!_pathStartsWithAt(fullPath, pathIdx, nodePath)) {
                        return ("", "", "");
                    }
                    // Consume the matched extension path
                    pathIdx += nodePath.length;
                    // Follow the hash pointer
                    RLPReader.RLPItem memory item = currentNode[1];
                    require(
                        item.len == HASH_SIZE,
                        "MPT: Extension must point to hash"
                    );
                    bytes32 nodeHash = bytes32(item.toBytes());
                    require(
                        proofIdx < proof.length,
                        "MPT: proof too short for extension"
                    );
                    currentNodeBytes = proof[proofIdx];
                    require(
                        keccak256(currentNodeBytes) == nodeHash,
                        "MPT: invalid extension proof"
                    );
                    currentNode = currentNodeBytes.toRlpItem().toList();
                    proofIdx++;
                }
            } else if (currentNode.length == 17) {
                // Branch Node
                // If no more nibbles, value is at index 16
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
                    // Embedded node
                    currentNode = item.toList();
                } else {
                    // Hash pointer
                    require(
                        item.len == HASH_SIZE,
                        "MPT: Branch must point to hash"
                    );
                    bytes32 nodeHash = bytes32(item.toBytes());

                    require(
                        proofIdx < proof.length,
                        "MPT: proof too short for branch"
                    );
                    currentNodeBytes = proof[proofIdx];
                    require(
                        keccak256(currentNodeBytes) == nodeHash,
                        "MPT: invalid branch proof"
                    );

                    currentNode = currentNodeBytes.toRlpItem().toList();
                    proofIdx++;
                }
            } else {
                return ("", "", "");
                // Invalid Node
            }
        }
    }

    // -------- Preslice version (kept for quick revert / comparison) --------

    function _getPreslice(
        bytes[] memory proof,
        bytes32 root,
        bytes memory key
    )
        private
        pure
        returns (
            bytes memory finalValue,
            bytes memory debugRemainingPath,
            bytes memory debugLeafPath
        )
    {
        require(proof.length > 0, "MPT: proof cannot be empty");
        bytes memory path = _getNibbleKey(key);

        bytes memory currentNodeBytes = proof[0];
        require(keccak256(currentNodeBytes) == root, "MPT: invalid root");

        RLPReader.RLPItem[] memory currentNode = currentNodeBytes
            .toRlpItem()
            .toList();
        uint256 proofIdx = 1;
        while (true) {
            if (currentNode.length == 2) {
                // Leaf or Extension Node
                bytes memory encodedPath = currentNode[0].toBytes();
                bytes memory nodePath = _decodeNodePath(encodedPath);

                if (_isLeafNode(encodedPath)) {
                    debugRemainingPath = path;
                    debugLeafPath = nodePath;
                    if (
                        path.length == nodePath.length &&
                        _pathStartsWith(path, nodePath)
                    ) {
                        finalValue = currentNode[1].toBytes();
                    }
                    return (finalValue, debugRemainingPath, debugLeafPath);
                } else {
                    // Extension Node
                    if (!_pathStartsWith(path, nodePath)) return ("", "", "");
                    path = _pathSlice(path, nodePath.length);

                    RLPReader.RLPItem memory item = currentNode[1];
                    require(
                        item.len == HASH_SIZE,
                        "MPT: Extension must point to hash"
                    );
                    bytes32 nodeHash = bytes32(item.toBytes());

                    require(
                        proofIdx < proof.length,
                        "MPT: proof too short for extension"
                    );
                    currentNodeBytes = proof[proofIdx];
                    require(
                        keccak256(currentNodeBytes) == nodeHash,
                        "MPT: invalid extension proof"
                    );

                    currentNode = currentNodeBytes.toRlpItem().toList();
                    proofIdx++;
                }
            } else if (currentNode.length == 17) {
                // Branch Node
                if (path.length == 0) {
                    finalValue = currentNode[BRANCH_VALUE_INDEX].toBytes();
                    return (finalValue, debugRemainingPath, debugLeafPath);
                }

                uint8 nibble = uint8(path[0]);
                require(nibble < 16, "MPT: invalid nibble index");
                path = _pathSlice(path, 1);

                RLPReader.RLPItem memory item = currentNode[nibble];
                if (item.len == 0) return ("", "", "");

                if (item.isList()) {
                    // Embedded Node
                    currentNode = item.toList();
                } else {
                    // Hash Pointer
                    require(
                        item.len == HASH_SIZE,
                        "MPT: Branch must point to hash"
                    );
                    bytes32 nodeHash = bytes32(item.toBytes());

                    require(
                        proofIdx < proof.length,
                        "MPT: proof too short for branch"
                    );
                    currentNodeBytes = proof[proofIdx];
                    require(
                        keccak256(currentNodeBytes) == nodeHash,
                        "MPT: invalid branch proof"
                    );

                    currentNode = currentNodeBytes.toRlpItem().toList();
                    proofIdx++;
                }
            } else {
                return ("", "", "");
                // Invalid Node
            }
        }
    }

    // -------- Helpers --------

    function _getNibbleKey(
        bytes memory key
    ) internal pure returns (bytes memory) {
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
    ) internal pure returns (bytes memory) {
        if (data.length == 0) return "";
        uint8 prefix = uint8(data[0]);
        bool isOddLen = ((prefix >> 4) % 2) == 1;
        uint offset = 1;
        uint pathLen = isOddLen
            ? (data.length - 1) * 2 + 1
            : (data.length - 1) * 2;
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
        // Leaf nodes have a prefix nibble of 2 or 3 (per Ethereum Yellow Paper)
        return (uint8(data[0]) >> 4) >= 2;
    }

    // StartsWith check using an index into `path` (no slicing)
    function _pathStartsWithAt(
        bytes memory path,
        uint256 start,
        bytes memory subpath
    ) private pure returns (bool) {
        if (path.length < start || path.length - start < subpath.length)
            return false;
        for (uint256 i = 0; i < subpath.length; i++) {
            if (path[start + i] != subpath[i]) return false;
        }
        return true;
    }

    // Allocate only when returning a debug slice
    function _subslice(
        bytes memory data,
        uint256 start
    ) private pure returns (bytes memory) {
        if (start >= data.length) return "";
        uint256 len = data.length - start;
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = data[start + i];
        }
        return out;
    }

    // Preslice helpers retained (used by _getPreslice)
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
        if (start >= path.length) return "";
        uint256 len = path.length - start;
        bytes memory subpath = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            subpath[i] = path[i + start];
        }
        return subpath;
    }
}
