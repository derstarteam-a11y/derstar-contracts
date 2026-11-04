// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Series, OptionType} from "../types/DerstarTypes.sol";

/// @notice Packs a series into its token id so the id is readable without storage reads:
/// [ underlying:8 | optType:8 | expiry:64 | strike:64 ]
library SeriesId {
    error InvalidSeriesId();

    function encode(Series memory s) internal pure returns (uint256) {
        return (uint256(s.underlying) << 136) | (uint256(uint8(s.optType)) << 128) | (uint256(s.expiry) << 64)
            | uint256(s.strike);
    }

    function decode(uint256 id) internal pure returns (Series memory s) {
        if (id >> 144 != 0) revert InvalidSeriesId();
        // forge-lint: disable-next-line(unsafe-typecast) -- unpacking fixed-width bit fields
        uint8 t = uint8(id >> 128);
        if (t > uint8(OptionType.Put)) revert InvalidSeriesId();
        // forge-lint: disable-next-line(unsafe-typecast) -- unpacking fixed-width bit fields
        s.underlying = uint8(id >> 136);
        s.optType = OptionType(t);
        // forge-lint: disable-next-line(unsafe-typecast) -- unpacking fixed-width bit fields
        s.expiry = uint64(id >> 64);
        // forge-lint: disable-next-line(unsafe-typecast) -- unpacking fixed-width bit fields
        s.strike = uint64(id);
    }

    function underlying(uint256 id) internal pure returns (uint8) {
        // forge-lint: disable-next-line(unsafe-typecast) -- unpacking fixed-width bit fields
        return uint8(id >> 136);
    }

    function expiry(uint256 id) internal pure returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast) -- unpacking fixed-width bit fields
        return uint64(id >> 64);
    }
}
