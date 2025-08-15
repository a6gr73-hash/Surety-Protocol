// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title RLPReader
 * @dev A library for decoding RLP-encoded data.
 */
library RLPReader {
    
    // --- Constants for RLP decoding ---
    uint8 constant STRING_SHORT_START = 0x80;
    uint8 constant STRING_LONG_START  = 0xb8;
    uint8 constant LIST_SHORT_START   = 0xc0;
    uint8 constant LIST_LONG_START    = 0xf8;

    /**
     * @dev Represents a single RLP-encoded item.
     */
    struct RLPItem {
        uint256 memPtr;
        uint256 len;
    }
    
    function toRlpItem(bytes memory rlpData) internal pure returns (RLPItem memory) {
        if (rlpData.length == 0) {
            revert("RLPReader: Empty data");
        }
        
        uint8 byte0;
        uint256 memPtr;
        uint256 len;
        
        assembly {
            memPtr := add(rlpData, 32)
            byte0 := byte(0, mload(memPtr))
        }

        if (byte0 < STRING_SHORT_START) {
            revert("RLPReader: Not a list");
        } else if (byte0 < STRING_LONG_START) {
            revert("RLPReader: Not a list");
        } else if (byte0 < LIST_SHORT_START) {
            revert("RLPReader: Not a list");
        } else if (byte0 < LIST_LONG_START) {
            len = byte0 - LIST_SHORT_START;
            memPtr = memPtr + 1;
        } else {
            uint256 lenOfLen = byte0 - LIST_LONG_START;
            uint256 listLen;
            uint256 rlpDataPtr;
            
            assembly {
                rlpDataPtr := add(memPtr, 1)
            }

            for (uint256 i = 0; i < lenOfLen; i++) {
                uint8 currentByte;
                assembly {
                    currentByte := byte(i, mload(rlpDataPtr))
                    listLen := shl(8, listLen)
                    listLen := or(listLen, currentByte)
                }
            }
            len = listLen;
            assembly {
                memPtr := add(rlpDataPtr, lenOfLen)
            }
        }
        
        return RLPItem(memPtr, len);
    }
    
    function toBytes(RLPItem memory item) internal pure returns (bytes memory) {
        bytes memory result = new bytes(item.len);
        if (item.len == 0) {
            return result;
        }

        uint256 destPtr;
        uint256 srcPtr = item.memPtr;
        
        assembly {
            destPtr := add(result, 32)
            let bytesLength := mload(item) // Correctly load length from RLPItem struct
            for { let i := 0 } lt(i, bytesLength) { i := add(i, 32) } {
                mstore(destPtr, mload(srcPtr))
                destPtr := add(destPtr, 32)
                srcPtr := add(srcPtr, 32)
            }
        }
        
        return result;
    }
}
