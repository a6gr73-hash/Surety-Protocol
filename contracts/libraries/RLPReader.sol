// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title RLPReader
 * @dev A library for decoding RLP-encoded data.
 */
library RLPReader {
    using SafeMath for uint256;
    using SafeMath for uint8;
    using RLPReader for RLPItem;
    using RLPReader for bytes; // Added this line

    // --- Constants for RLP decoding ---
    uint8 constant STRING_SHORT_START = 0x80;
    uint8 constant STRING_LONG_START = 0xb8;
    uint8 constant LIST_SHORT_START = 0xc0;
    uint8 constant LIST_LONG_START = 0xf8;

    /**
     * @dev Represents a single RLP-encoded item.
     */
    struct RLPItem {
        uint256 memPtr;
        uint256 len;
    }

    function toRlpItem(
        bytes memory rlpData
    ) internal pure returns (RLPItem memory) {
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
            len = byte0.sub(LIST_SHORT_START);
            memPtr = memPtr.add(1);
        } else {
            uint256 lenOfLen = byte0.sub(LIST_LONG_START);
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
            let bytesLength := mload(item)
            for {
                let i := 0
            } lt(i, bytesLength) {
                i := add(i, 32)
            } {
                mstore(destPtr, mload(srcPtr))
                destPtr := add(destPtr, 32)
                srcPtr := add(srcPtr, 32)
            }
        }

        return result;
    }

    /**
     * @notice Decodes an RLP-encoded list into an array of RLPItems.
     * @dev This is a crucial helper for traversing MPT branch nodes.
     * @param rlpList The RLPItem representing the list.
     * @return An array of RLPItem structs for each element in the list.
     */
    function toList(
        RLPItem memory rlpList
    ) internal pure returns (RLPItem[] memory) {
        uint256 listLen = rlpList.len;
        uint256 memPtr = rlpList.memPtr;
        uint256 itemCount;

        uint256 currentItemStart = 0;
        uint256 totalLength = 0;
        bytes memory rlpData = rlpList.toBytes();

        while (totalLength < listLen) {
            uint256 start;
            uint256 len;
            (start, len) = rlpData._findNextItem(currentItemStart);
            if (len == 0) {
                break;
            }
            totalLength = totalLength.add(len);
            currentItemStart = start.add(len);
            itemCount++;
        }

        RLPItem[] memory result = new RLPItem[](itemCount);
        currentItemStart = 0;

        for (uint256 i = 0; i < itemCount; i++) {
            uint256 start;
            uint256 len;
            (start, len) = rlpData._findNextItem(currentItemStart);
            if (len == 0) {
                revert("Invalid RLP list format.");
            }

            result[i] = RLPItem(memPtr.add(start), len);
            currentItemStart = start.add(len);
        }

        return result;
    }

    /**
     * @dev Finds the start and length of the next RLP item in a byte array.
     * @param _bytes The RLP-encoded data.
     * @param _index The starting index to search from.
     * @return start The starting index of the next RLP item.
     * @return len The length of the next RLP item.
     */
    function _findNextItem(
        bytes memory _bytes,
        uint256 _index
    ) internal pure returns (uint256 start, uint256 len) {
        if (_index >= _bytes.length) {
            return (0, 0);
        }

        uint8 firstByte = uint8(_bytes[_index]);
        if (firstByte <= 0x7f) {
            start = _index;
            len = 1;
        } else if (firstByte <= 0xb7) {
            start = _index;
            len = firstByte.sub(0x80).add(1);
        } else if (firstByte <= 0xbf) {
            uint256 lenOfLen = firstByte.sub(0xb7);
            start = _index.add(1);
            len = _bytesToUint(_bytes, start, lenOfLen);
            start = start.add(lenOfLen);
        } else if (firstByte <= 0xf7) {
            start = _index;
            len = firstByte.sub(0xc0).add(1);
        } else {
            uint256 lenOfLen = firstByte.sub(0xf7);
            start = _index.add(1);
            len = _bytesToUint(_bytes, start, lenOfLen);
            start = start.add(lenOfLen);
        }
        return (start, len);
    }

    /**
     * @dev Converts a byte array to a uint256.
     * @param _bytes The byte array to convert.
     * @param _start The starting index.
     * @param _len The length of the byte array to convert.
     * @return The resulting uint256.
     */
    function _bytesToUint(
        bytes memory _bytes,
        uint256 _start,
        uint256 _len
    ) internal pure returns (uint256) {
        uint256 number;
        for (uint256 i = 0; i < _len; i++) {
            number = number.mul(256).add(uint8(_bytes[_start.add(i)]));
        }
        return number;
    }
}