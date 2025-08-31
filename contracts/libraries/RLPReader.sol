// contracts/libraries/RLPReader.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

library RLPReader {
    struct RLPItem {
        uint256 len;
        uint256 memPtr;
    }

    function toRlpItem(bytes memory self) internal pure returns (RLPItem memory) {
        uint256 memPtr;
        assembly { memPtr := add(self, 0x20) }
        return RLPItem(self.length, memPtr);
    }

    function toBytes(RLPItem memory item) internal pure returns (bytes memory) {
        bytes memory b = new bytes(item.len);
        uint256 b_ptr;
        assembly { b_ptr := add(b, 0x20) }
        _copy(item.memPtr, b_ptr, item.len);
        return b;
    }

    // NEW FUNCTION: Decodes the payload of an RLP item, stripping the prefix.
    function toData(RLPItem memory item) internal pure returns (bytes memory) {
        (uint256 payloadPtr, uint256 payloadLen) = _payload(item);
        bytes memory b = new bytes(payloadLen);
        uint256 b_ptr;
        assembly { b_ptr := add(b, 0x20) }
        _copy(payloadPtr, b_ptr, payloadLen);
        return b;
    }

    function toList(RLPItem memory item) internal pure returns (RLPItem[] memory) {
        (uint256 payloadPtr, uint256 payloadLen) = _payload(item);
        uint256 itemCount = 0;
        uint256 tempPtr = payloadPtr;
        while (tempPtr < payloadPtr + payloadLen) {
            itemCount++;
            tempPtr += _itemLength(tempPtr);
        }
        RLPItem[] memory result = new RLPItem[](itemCount);
        uint256 currentPtr = payloadPtr;
        for (uint256 i = 0; i < itemCount; i++) {
            uint256 len = _itemLength(currentPtr);
            result[i] = RLPItem(len, currentPtr);
            currentPtr += len;
        }
        return result;
    }

    function _payload(RLPItem memory item) private pure returns (uint256, uint256) {
        uint256 ptr = item.memPtr;
        uint256 len = item.len;
        uint8 firstByte;
        assembly { firstByte := byte(0, mload(ptr)) }
        uint8 lenLen;
        if (firstByte < 0xC0) {
            if (firstByte < 0x80) return (ptr, len);
            if (firstByte < 0xB8) return (ptr + 1, len - 1);
            lenLen = firstByte - 0xB7;
            return (ptr + 1 + lenLen, len - 1 - lenLen);
        } else {
            if (firstByte < 0xF8) return (ptr + 1, len - 1);
            lenLen = firstByte - 0xF7;
            return (ptr + 1 + lenLen, len - 1 - lenLen);
        }
    }

    function _itemLength(uint256 memPtr) private pure returns (uint256) {
        uint8 firstByte;
        assembly { firstByte := byte(0, mload(memPtr)) }
        uint8 lenLen;
        if (firstByte < 0x80) return 1;
        if (firstByte < 0xB8) return uint256(firstByte) - 0x80 + 1;
        if (firstByte < 0xC0) {
            lenLen = firstByte - 0xB7;
            return _toUint(memPtr + 1, lenLen) + 1 + lenLen;
        }
        if (firstByte < 0xF8) return uint256(firstByte) - 0xC0 + 1;
        lenLen = firstByte - 0xF7;
        return _toUint(memPtr + 1, lenLen) + 1 + lenLen;
    }
    
    function _toUint(uint256 memPtr, uint256 len) private pure returns (uint256 result) {
        for (uint256 i = 0; i < len; i++) {
            uint8 b;
            uint256 p = memPtr + i;
            assembly { b := byte(0, mload(p)) }
            result = (result << 8) | b;
        }
    }

    function _copy(uint256 src, uint256 dest, uint256 len) private pure {
        for (uint256 i = 0; i < len; i += 32) {
            assembly { mstore(add(dest, i), mload(add(src, i))) }
        }
    }
}
