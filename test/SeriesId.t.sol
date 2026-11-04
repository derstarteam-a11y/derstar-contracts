// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SeriesId} from "../src/libraries/SeriesId.sol";
import {ExpiryCalendar} from "../src/libraries/ExpiryCalendar.sol";
import {Series, OptionType} from "../src/types/DerstarTypes.sol";

contract SeriesIdHarness {
    function decode(uint256 id) external pure returns (Series memory) {
        return SeriesId.decode(id);
    }
}

contract SeriesIdTest is Test {
    SeriesIdHarness internal h = new SeriesIdHarness();

    function testFuzz_roundTrip(uint8 u, bool isCall, uint64 expiry, uint64 strike) public view {
        Series memory s = Series(u, isCall ? OptionType.Call : OptionType.Put, expiry, strike);
        uint256 id = SeriesId.encode(s);
        Series memory d = h.decode(id);
        assertEq(d.underlying, u);
        assertEq(uint8(d.optType), uint8(s.optType));
        assertEq(d.expiry, expiry);
        assertEq(d.strike, strike);
        assertEq(SeriesId.underlying(id), u);
        assertEq(SeriesId.expiry(id), expiry);
    }

    function test_rejectsGarbageIds() public {
        vm.expectRevert(SeriesId.InvalidSeriesId.selector);
        h.decode(uint256(1) << 200);
        vm.expectRevert(SeriesId.InvalidSeriesId.selector);
        h.decode(uint256(2) << 128); // option type 2 does not exist
    }

    function test_calendar() public pure {
        assertTrue(ExpiryCalendar.isFriday0800(1793347200)); // Fri 2026-10-30 08:00
        assertFalse(ExpiryCalendar.isFriday0800(1793347200 + 1 hours));
        assertFalse(ExpiryCalendar.isFriday0800(1795680000)); // Thu 2026-11-26 08:00
        assertTrue(ExpiryCalendar.isMonthly(1793347200)); // Oct 30 is the last Friday of October
        assertFalse(ExpiryCalendar.isMonthly(1793952000)); // Nov 6 is a plain weekly
        assertTrue(ExpiryCalendar.isMonthly(1795766400)); // Nov 27
    }
}
