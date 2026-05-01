// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title RLPReader
 * @notice Minimal RLP decoder for Ethereum block headers and receipts.
 *         All functions operate on (bytes memory, offset) pairs to avoid unsafe pointer arithmetic.
 */
library RLPReader {
    struct Log {
        address addr;
        bytes32[] topics;
        bytes data;
    }

    // ── Public API ───────────────────────────────────────────────────────────

    /**
     * @notice Extract receiptsRoot (field index 5) from an RLP block header.
     */
    function receiptsRoot(bytes memory rlpHeader) internal pure returns (bytes32 root) {
        // Skip outer list prefix, then iterate to field 5
        (uint256 listStart, uint256 listEnd) = decodeListBounds(rlpHeader, 0);
        uint256 pos = listStart;
        for (uint256 i = 0; i < 5; i++) {
            (, uint256 end) = decodeItemBounds(rlpHeader, pos);
            pos = end;
        }
        (uint256 dataStart, uint256 dataEnd) = decodeItemBounds(rlpHeader, pos);
        require(dataEnd - dataStart == 32, "RLP: receiptsRoot length");
        assembly {
            root := mload(add(add(rlpHeader, 32), dataStart))
        }
        // suppress unused warning
        listEnd;
    }

    /**
     * @notice Decode log at logIndex from an RLP-encoded receipt.
     *         Handles EIP-2718 typed receipts (strips 1-byte type prefix).
     */
    function decodeLog(bytes calldata rlpReceiptCalldata, uint256 logIndex)
        internal pure returns (Log memory log)
    {
        bytes memory receipt = _stripTypeByte(rlpReceiptCalldata);
        uint256 logOffset = _findLogOffset(receipt, logIndex);
        log = _decodeLogAt(receipt, logOffset);
    }

    function _findLogOffset(bytes memory receipt, uint256 logIndex)
        internal pure returns (uint256 logOffset)
    {
        // Skip to field 3 (logs) of receipt: [status, gas, bloom, logs]
        (uint256 receiptStart, ) = decodeListBounds(receipt, 0);
        uint256 pos = receiptStart;
        for (uint256 i = 0; i < 3; i++) {
            (, uint256 end) = decodeItemBounds(receipt, pos);
            pos = end;
        }
        (uint256 logsStart, uint256 logsEnd) = decodeListBoundsAt(receipt, pos);
        uint256 lpos = logsStart;
        for (uint256 i = 0; i < logIndex; i++) {
            require(lpos < logsEnd, "RLP: logIndex range");
            (, uint256 logEnd) = decodeListBoundsAt(receipt, lpos);
            lpos = logEnd;
        }
        require(lpos < logsEnd, "RLP: logIndex range");
        return lpos;
    }

    function _decodeLogAt(bytes memory receipt, uint256 lpos)
        internal pure returns (Log memory log)
    {
        (uint256 logStart, ) = decodeListBoundsAt(receipt, lpos);
        uint256 p = logStart;

        // address field
        (uint256 addrStart, uint256 addrEnd) = decodeItemBounds(receipt, p);
        require(addrEnd - addrStart == 20, "RLP: addr length");
        bytes20 addrBytes;
        assembly { addrBytes := mload(add(add(receipt, 32), addrStart)) }
        log.addr = address(addrBytes);
        p = addrEnd;

        // topics
        (log.topics, p) = _decodeTopics(receipt, p);

        // data
        (uint256 dataStart, uint256 dataEnd) = decodeItemBounds(receipt, p);
        log.data = _copyBytes(receipt, dataStart, dataEnd);
    }

    function _decodeTopics(bytes memory receipt, uint256 p)
        internal pure returns (bytes32[] memory topics, uint256 nextP)
    {
        (uint256 topicsStart, uint256 topicsEnd) = decodeListBoundsAt(receipt, p);
        nextP = topicsEnd;
        uint256 count = 0;
        uint256 tpos = topicsStart;
        while (tpos < topicsEnd) {
            (, uint256 te) = decodeItemBounds(receipt, tpos);
            tpos = te;
            count++;
        }
        topics = new bytes32[](count);
        tpos = topicsStart;
        for (uint256 i = 0; i < count; i++) {
            (uint256 ts, uint256 te) = decodeItemBounds(receipt, tpos);
            require(te - ts == 32, "RLP: topic length");
            bytes32 topic;
            assembly { topic := mload(add(add(receipt, 32), ts)) }
            topics[i] = topic;
            tpos = te;
        }
    }

    function _copyBytes(bytes memory data, uint256 from, uint256 to)
        internal pure returns (bytes memory result)
    {
        result = new bytes(to - from);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = data[from + i];
        }
    }

    /**
     * @notice RLP-encode a tx index as the MPT trie key.
     */
    function encodeIndex(uint256 index) internal pure returns (bytes memory) {
        if (index == 0) return hex"80";
        uint256 tmp = index;
        uint256 byteLen = 0;
        while (tmp > 0) { tmp >>= 8; byteLen++; }
        if (byteLen == 1 && index < 0x80) {
            bytes memory single = new bytes(1);
            single[0] = bytes1(uint8(index));
            return single;
        }
        bytes memory result = new bytes(1 + byteLen);
        result[0] = bytes1(uint8(0x80 + byteLen));
        tmp = index;
        for (uint256 i = byteLen; i > 0; i--) {
            result[i] = bytes1(uint8(tmp & 0xff));
            tmp >>= 8;
        }
        return result;
    }

    // ── RLP Bounds Helpers ───────────────────────────────────────────────────

    /**
     * @notice Decode item at offset. Returns (dataStart, dataEnd) byte offsets into `data`.
     *         For string/bytes items: dataStart points to value bytes.
     *         For list items: dataStart points to first child byte.
     */
    function decodeItemBounds(bytes memory data, uint256 offset)
        internal pure returns (uint256 dataStart, uint256 dataEnd)
    {
        uint8 prefix = uint8(data[offset]);

        if (prefix < 0x80) {
            // Single byte, value is the byte itself
            return (offset, offset + 1);
        } else if (prefix < 0xb8) {
            // Short string
            uint256 len = prefix - 0x80;
            return (offset + 1, offset + 1 + len);
        } else if (prefix < 0xc0) {
            // Long string
            uint256 lenOfLen = prefix - 0xb7;
            uint256 len = _readUint(data, offset + 1, lenOfLen);
            return (offset + 1 + lenOfLen, offset + 1 + lenOfLen + len);
        } else if (prefix < 0xf8) {
            // Short list
            uint256 len = prefix - 0xc0;
            return (offset + 1, offset + 1 + len);
        } else {
            // Long list
            uint256 lenOfLen = prefix - 0xf7;
            uint256 len = _readUint(data, offset + 1, lenOfLen);
            return (offset + 1 + lenOfLen, offset + 1 + lenOfLen + len);
        }
    }

    /**
     * @notice For a list item at `offset`, return (innerStart, totalEnd).
     *         innerStart = first child byte; totalEnd = byte after last child.
     */
    function decodeListBounds(bytes memory data, uint256 offset)
        internal pure returns (uint256 innerStart, uint256 totalEnd)
    {
        return decodeListBoundsAt(data, offset);
    }

    function decodeListBoundsAt(bytes memory data, uint256 offset)
        internal pure returns (uint256 innerStart, uint256 totalEnd)
    {
        uint8 prefix = uint8(data[offset]);
        require(prefix >= 0xc0, "RLP: not a list");
        if (prefix < 0xf8) {
            uint256 len = prefix - 0xc0;
            innerStart = offset + 1;
            totalEnd = offset + 1 + len;
        } else {
            uint256 lenOfLen = prefix - 0xf7;
            uint256 len = _readUint(data, offset + 1, lenOfLen);
            innerStart = offset + 1 + lenOfLen;
            totalEnd = offset + 1 + lenOfLen + len;
        }
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    function _readUint(bytes memory data, uint256 offset, uint256 len)
        internal pure returns (uint256 result)
    {
        for (uint256 i = 0; i < len; i++) {
            result = (result << 8) | uint8(data[offset + i]);
        }
    }

    function _stripTypeByte(bytes calldata data) internal pure returns (bytes memory) {
        if (data.length > 0 && uint8(data[0]) < 0x80) {
            return bytes(data[1:]);
        }
        return bytes(data);
    }
}
