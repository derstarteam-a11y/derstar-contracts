// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {LibBit} from "solady/utils/LibBit.sol";

/// @notice Two-level bitmap over price ticks 1..65535: 256 words of 256 bits plus a summary
/// word that marks non-empty words. Best price and next price are found in O(1).
library TickBitmap {
    struct Bitmap {
        uint256 top;
        mapping(uint256 => uint256) words;
    }

    function set(Bitmap storage b, uint16 tick) internal {
        uint256 w = tick >> 8;
        b.words[w] |= uint256(1) << (tick & 255);
        b.top |= uint256(1) << w;
    }

    function clear(Bitmap storage b, uint16 tick) internal {
        uint256 w = tick >> 8;
        uint256 word = b.words[w] & ~(uint256(1) << (tick & 255));
        b.words[w] = word;
        if (word == 0) b.top &= ~(uint256(1) << w);
    }

    function lowest(Bitmap storage b) internal view returns (uint16 tick, bool found) {
        uint256 top = b.top;
        if (top == 0) return (0, false);
        uint256 w = LibBit.ffs(top);
        return (_tick(w, LibBit.ffs(b.words[w])), true);
    }

    function highest(Bitmap storage b) internal view returns (uint16 tick, bool found) {
        uint256 top = b.top;
        if (top == 0) return (0, false);
        uint256 w = LibBit.fls(top);
        return (_tick(w, LibBit.fls(b.words[w])), true);
    }

    /// @notice Lowest set tick strictly above `tick`.
    function nextAbove(Bitmap storage b, uint16 tick) internal view returns (uint16, bool) {
        uint256 w = tick >> 8;
        uint256 bit = tick & 255;
        uint256 m = bit == 255 ? 0 : b.words[w] & (type(uint256).max << (bit + 1));
        if (m != 0) return (_tick(w, LibBit.ffs(m)), true);
        uint256 t = w == 255 ? 0 : b.top & (type(uint256).max << (w + 1));
        if (t == 0) return (0, false);
        uint256 w2 = LibBit.ffs(t);
        return (_tick(w2, LibBit.ffs(b.words[w2])), true);
    }

    /// @notice Highest set tick strictly below `tick`.
    function nextBelow(Bitmap storage b, uint16 tick) internal view returns (uint16, bool) {
        uint256 w = tick >> 8;
        uint256 bit = tick & 255;
        uint256 m = b.words[w] & ((uint256(1) << bit) - 1);
        if (m != 0) return (_tick(w, LibBit.fls(m)), true);
        uint256 t = b.top & ((uint256(1) << w) - 1);
        if (t == 0) return (0, false);
        uint256 w2 = LibBit.fls(t);
        return (_tick(w2, LibBit.fls(b.words[w2])), true);
    }

    function _tick(uint256 w, uint256 bit) private pure returns (uint16) {
        // forge-lint: disable-next-line(unsafe-typecast) -- w and bit are both < 256
        return uint16((w << 8) | bit);
    }
}
