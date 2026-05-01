// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RLPReader} from "./RLPReader.sol";

/**
 * @title MerklePatricia
 * @notice Verifies Ethereum Merkle Patricia Trie inclusion proofs.
 *         Proof = [node0_rlp, node1_rlp, ...] from root to leaf.
 *
 *         Hex prefix nibble flags:
 *           0x0 = extension even  0x1 = extension odd
 *           0x2 = leaf even       0x3 = leaf odd
 */
library MerklePatricia {
    struct TraversalState {
        bytes path;        // full nibble path
        uint256 offset;    // nibble offset consumed so far
        bytes nextHash;    // expected hash/inline of next node
    }

    /**
     * @notice Verify receipt inclusion.
     * @param root       Expected trie root hash
     * @param key        RLP-encoded tx index (from RLPReader.encodeIndex)
     * @param value      RLP-encoded receipt bytes expected at leaf
     * @param proof      RLP-encoded trie nodes from root to leaf
     */
    function verify(
        bytes32 root,
        bytes memory key,
        bytes memory value,
        bytes[] memory proof
    ) internal pure returns (bool) {
        if (proof.length == 0) return false;

        TraversalState memory state;
        state.path   = _toNibbles(key);
        state.offset = 0;
        state.nextHash = abi.encodePacked(root);

        for (uint256 i = 0; i < proof.length; i++) {
            bytes memory node = proof[i];

            // Verify node matches expected
            if (i == 0) {
                if (keccak256(node) != root) return false;
            } else {
                if (!_matchesExpected(state.nextHash, node)) return false;
            }

            // Count items to determine node type
            (uint256 listStart, uint256 listEnd) = RLPReader.decodeListBoundsAt(node, 0);
            uint256 itemCount = _countItems(node, listStart, listEnd);

            if (itemCount == 17) {
                bool done = _processBranch(node, listStart, state, value);
                if (done) return true;
                // state.nextHash updated, continue
            } else if (itemCount == 2) {
                (bool terminal, bool matched) = _processTwoItem(node, listStart, state, value);
                if (terminal) return matched;
                // extension: state updated, continue
            } else {
                return false;
            }
        }
        return false;
    }

    // ── Node processors ───────────────────────────────────────────────────────

    function _processBranch(
        bytes memory node,
        uint256 listStart,
        TraversalState memory state,
        bytes memory value
    ) internal pure returns (bool terminal) {
        if (state.offset >= state.path.length) {
            // Value at branch node index 16
            uint256 valOff = _nthItemOffset(node, listStart, 16);
            (uint256 vs, uint256 ve) = RLPReader.decodeItemBounds(node, valOff);
            return _equalSlice(node, vs, ve, value);
        }
        uint8 nibble = uint8(state.path[state.offset]);
        state.offset++;
        uint256 childOff = _nthItemOffset(node, listStart, nibble);
        (uint256 cs, uint256 ce) = RLPReader.decodeItemBounds(node, childOff);
        state.nextHash = _slice(node, cs, ce);
        return false;
    }

    function _processTwoItem(
        bytes memory node,
        uint256 listStart,
        TraversalState memory state,
        bytes memory value
    ) internal pure returns (bool terminal, bool matched) {
        (bool isLeaf, bytes memory nodePath) = _getNodePath(node, listStart);

        uint256 remaining = state.path.length - state.offset;
        if (nodePath.length > remaining) return (true, false);

        for (uint256 j = 0; j < nodePath.length; j++) {
            if (nodePath[j] != state.path[state.offset + j]) return (true, false);
        }
        state.offset += nodePath.length;

        uint256 vOff = _nthItemOffset(node, listStart, 1);
        if (isLeaf) {
            return (true, _checkLeaf(node, vOff, state, value));
        } else {
            (uint256 vs2, uint256 ve2) = RLPReader.decodeItemBounds(node, vOff);
            state.nextHash = _slice(node, vs2, ve2);
            return (false, false);
        }
    }

    function _getNodePath(bytes memory node, uint256 listStart)
        internal pure returns (bool isLeaf, bytes memory nodePath)
    {
        uint256 epOff = _nthItemOffset(node, listStart, 0);
        (uint256 eps, uint256 epe) = RLPReader.decodeItemBounds(node, epOff);
        bytes memory encodedPath = _slice(node, eps, epe);
        return _decodeHexPrefix(encodedPath);
    }

    function _checkLeaf(
        bytes memory node,
        uint256 vOff,
        TraversalState memory state,
        bytes memory value
    ) internal pure returns (bool) {
        if (state.offset != state.path.length) return false;
        (uint256 vs, uint256 ve) = RLPReader.decodeItemBounds(node, vOff);
        return _equalSlice(node, vs, ve, value);
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    function _matchesExpected(bytes memory expected, bytes memory node) internal pure returns (bool) {
        if (expected.length == 32) {
            bytes32 h;
            assembly { h := mload(add(expected, 32)) }
            return keccak256(node) == h;
        }
        return keccak256(expected) == keccak256(node);
    }

    function _toNibbles(bytes memory key) internal pure returns (bytes memory nibbles) {
        nibbles = new bytes(key.length * 2);
        for (uint256 i = 0; i < key.length; i++) {
            nibbles[i * 2]     = bytes1(uint8(key[i]) >> 4);
            nibbles[i * 2 + 1] = bytes1(uint8(key[i]) & 0x0f);
        }
    }

    function _decodeHexPrefix(bytes memory encoded)
        internal pure returns (bool isLeaf, bytes memory path)
    {
        if (encoded.length == 0) return (false, new bytes(0));
        uint8 firstNibble = uint8(encoded[0]) >> 4;
        isLeaf = (firstNibble >= 2);
        bool odd = (firstNibble & 0x1) == 1;
        uint256 startNibble = odd ? 1 : 2;
        uint256 totalNibbles = encoded.length * 2;
        uint256 pathLen = totalNibbles > startNibble ? totalNibbles - startNibble : 0;
        path = new bytes(pathLen);
        uint256 idx = 0;
        for (uint256 i = startNibble; i < totalNibbles; i++) {
            uint8 b = uint8(encoded[i / 2]);
            path[idx++] = bytes1(i % 2 == 0 ? b >> 4 : b & 0x0f);
        }
    }

    function _countItems(bytes memory node, uint256 start, uint256 end)
        internal pure returns (uint256 count)
    {
        uint256 pos = start;
        while (pos < end) {
            (, uint256 itemEnd) = RLPReader.decodeItemBounds(node, pos);
            pos = itemEnd;
            count++;
        }
    }

    function _nthItemOffset(bytes memory node, uint256 start, uint256 n)
        internal pure returns (uint256 offset)
    {
        offset = start;
        for (uint256 i = 0; i < n; i++) {
            (, uint256 end) = RLPReader.decodeItemBounds(node, offset);
            offset = end;
        }
    }

    function _slice(bytes memory data, uint256 from, uint256 to)
        internal pure returns (bytes memory result)
    {
        result = new bytes(to - from);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = data[from + i];
        }
    }

    function _equalSlice(bytes memory data, uint256 from, uint256 to, bytes memory other)
        internal pure returns (bool)
    {
        if (to - from != other.length) return false;
        for (uint256 i = 0; i < other.length; i++) {
            if (data[from + i] != other[i]) return false;
        }
        return true;
    }
}
