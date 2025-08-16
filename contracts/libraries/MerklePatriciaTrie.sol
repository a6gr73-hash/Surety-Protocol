// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./RLPReader.sol";

library MerklePatriciaTrie {
    using RLPReader for RLPReader.RLPItem;
    using RLPReader for bytes;

    function get(bytes[] memory proof, bytes32 root, bytes memory key) internal pure returns (bytes memory) {
        RLPReader.RLPItem memory item;
        bytes memory path = _getNibbleKey(key);
        uint256 proof_idx = 0;
        
        bytes memory first_node_bytes = proof[proof_idx];
        RLPReader.RLPItem[] memory node = first_node_bytes.toRlpItem().toList();
        
        bytes32 node_hash = keccak256(first_node_bytes);
        require(node_hash == root, "MerklePatriciaTrie: invalid root");
        
        while (true) {
            require(proof_idx < proof.length, "MerklePatriciaTrie: proof is too short");
            if (path.length == 0) {
                if (node.length == 17) return node[16].toBytes();
                return "";
            }
            
            if (node.length == 2) {
                bytes memory node_path = _decodeNodePath(node[0].toBytes());
                if (_pathStartsWith(path, node_path)) {
                    path = _pathSlice(path, node_path.length);
                    if (_isLeafNode(node[0].toBytes())) {
                        if (path.length == 0) return node[1].toBytes();
                        return "";
                    }
                    item = node[1];
                    node_hash = bytes32(item.toBytes());
                } else {
                    return "";
                }
            } else if (node.length == 17) {
                uint8 nibble = uint8(path[0]);
                path = _pathSlice(path, 1);
                item = node[nibble];
                if (item.len == 0) return "";
                
                bytes memory item_bytes = item.toBytes();
                if (item.len >= 32) {
                    node_hash = bytes32(item_bytes);
                } else {
                    node_hash = keccak256(item_bytes);
                }
            } else {
                return "";
            }
            
            proof_idx++;
            node = proof[proof_idx].toRlpItem().toList();
            require(keccak256(proof[proof_idx]) == node_hash, "MerklePatriciaTrie: invalid proof");
        }
        
        revert("MerklePatriciaTrie: Should not be reached");
    }

    function verifyInclusion(bytes[] memory proof, bytes32 root, bytes memory key, bytes memory value) internal pure returns (bool) {
        bytes memory result = get(proof, root, key);
        return keccak256(result) == keccak256(value);
    }

    function _getNibbleKey(bytes memory key) private pure returns (bytes memory) {
        bytes memory nibbles = new bytes(key.length * 2);
        for (uint256 i = 0; i < key.length; i++) {
            uint8 b = uint8(key[i]);
            nibbles[i * 2] = bytes1(b / 16);
            nibbles[i * 2 + 1] = bytes1(b % 16);
        }
        return nibbles;
    }

    function _decodeNodePath(bytes memory data) private pure returns (bytes memory) {
        uint256 path_len;
        uint256 path_ptr;
        if (uint8(data[0]) % 2 == 1) {
            path_len = data.length * 2 - 1;
        } else {
            path_len = data.length * 2 - 2;
        }
        bytes memory path = new bytes(path_len);
        
        assembly {
            path_ptr := add(path, 0x20)
        }
        
        if (uint8(data[0]) % 2 == 1) {
            assembly {
                mstore8(path_ptr, and(byte(0, mload(add(data, 0x20))), 0x0F))
            }
            path_ptr++;
        }
        
        for (uint256 i = 1; i < data.length; i++) {
            uint8 b;
            assembly {
                b := byte(0, mload(add(data, add(0x20, i))))
            }
            assembly {
                mstore8(path_ptr, div(b, 16))
                mstore8(add(path_ptr, 1), and(b, 0x0F))
            }
            path_ptr += 2;
        }
        return path;
    }

    function _isLeafNode(bytes memory data) private pure returns (bool) {
        return uint8(data[0]) >= 0x20;
    }

    function _pathStartsWith(bytes memory path, bytes memory subpath) private pure returns (bool) {
        if (path.length < subpath.length) return false;
        for (uint256 i = 0; i < subpath.length; i++) {
            if (path[i] != subpath[i]) return false;
        }
        return true;
    }

    function _pathSlice(bytes memory path, uint256 start) private pure returns (bytes memory) {
        uint256 len = path.length - start;
        bytes memory subpath = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            subpath[i] = path[i + start];
        }
        return subpath;
    }
}
