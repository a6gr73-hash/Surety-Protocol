// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

library RLPReader {
    struct RLPItem {
        uint256 len;
        uint256 memPtr;
    }

    function toBytes(RLPItem memory item) internal pure returns (bytes memory) {
        bytes memory b = new bytes(item.len);
        uint256 b_ptr;
        assembly {
            b_ptr := add(b, 0x20)
        }
        _copy(item.memPtr, b_ptr, item.len);
        return b;
    }

    function toList(RLPItem memory item) internal pure returns (RLPItem[] memory) {
        (uint256 payload_mem_ptr, uint256 payload_len) = _payload(item);
        
        RLPItem[] memory result = new RLPItem[](20);
        uint256 items = 0;
        uint256 curr_ptr = payload_mem_ptr;
        while (curr_ptr < payload_mem_ptr + payload_len) {
            uint256 item_len = _itemLength(curr_ptr);
            if (items == result.length) {
                // Resize array
                RLPItem[] memory newResult = new RLPItem[](items * 2);
                for(uint i=0; i < items; i++){
                    newResult[i] = result[i];
                }
                result = newResult;
            }
            result[items] = RLPItem(item_len, curr_ptr);
            items++;
            curr_ptr += item_len;
        }
        
        RLPItem[] memory trimmed_result = new RLPItem[](items);
        for (uint256 i = 0; i < items; i++) {
            trimmed_result[i] = result[i];
        }
        return trimmed_result;
    }
    
    function toRlpItem(bytes memory self) internal pure returns (RLPItem memory) {
        uint256 memPtr;
        assembly {
            memPtr := add(self, 0x20)
        }
        return RLPItem(self.length, memPtr);
    }

    function _payload(RLPItem memory item) private pure returns (uint256, uint256) {
        uint256 ptr = item.memPtr;
        uint256 len = item.len;
        uint8 first_byte;
        assembly {
            first_byte := byte(0, mload(ptr))
        }

        if (first_byte < 0x80) {
            revert("RLPReader: invalid single-byte");
        } else if (first_byte < 0xB8) {
            return (ptr + 1, len - 1);
        } else if (first_byte < 0xC0) {
            uint8 len_len = first_byte - 0xB7;
            return (ptr + 1 + len_len, len - 1 - len_len);
        } else if (first_byte < 0xF8) {
            return (ptr + 1, len - 1);
        } else {
            uint8 len_len = first_byte - 0xF7;
            return (ptr + 1 + len_len, len - 1 - len_len);
        }
    }

    function _itemLength(uint256 mem_ptr) private pure returns (uint256) {
        uint8 first_byte;
        assembly {
            first_byte := byte(0, mload(mem_ptr))
        }
        if (first_byte < 0x80) {
            return 1;
        } else if (first_byte < 0xB8) {
            return uint256(first_byte) - 0x80 + 1;
        } else if (first_byte < 0xC0) {
            uint8 len_len = first_byte - 0xB7;
            uint256 len = _toUint(mem_ptr + 1, len_len);
            return len + uint256(len_len) + 1;
        } else if (first_byte < 0xF8) {
            return uint256(first_byte) - 0xC0 + 1;
        } else {
            uint8 len_len = first_byte - 0xF7;
            uint256 len = _toUint(mem_ptr + 1, len_len);
            return len + uint256(len_len) + 1;
        }
    }
    
    function _toUint(uint256 memPtr, uint256 len) private pure returns (uint256) {
        uint256 result = 0;
        for (uint256 i = 0; i < len; i++) {
            uint8 b;
            uint256 p = memPtr + i;
            assembly { b := byte(0, mload(p)) }
            result = (result << 8) | b;
        }
        return result;
    }

    function _copy(uint256 src, uint256 dest, uint256 len) private pure {
        for (uint256 i = 0; i < len; i += 32) {
            assembly {
                mstore(add(dest, i), mload(add(src, i)))
            }
        }
    }
}

