// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DateTimeLib} from "solady/utils/DateTimeLib.sol";

/// @notice Expiry rules: every expiry is at 08:00 UTC. Dailies on any day, weeklies on Fridays,
/// monthlies on the last Friday of the month.
library ExpiryCalendar {
    uint256 internal constant DAY = 86400;
    uint256 internal constant EXPIRY_TIME_OF_DAY = 8 hours;

    function isDaily0800(uint256 ts) internal pure returns (bool) {
        return ts % DAY == EXPIRY_TIME_OF_DAY;
    }

    function isFriday0800(uint256 ts) internal pure returns (bool) {
        return ts % DAY == EXPIRY_TIME_OF_DAY && DateTimeLib.weekday(ts) == DateTimeLib.FRI;
    }

    /// @dev Last Friday of its month: one week later falls in another month.
    function isMonthly(uint256 ts) internal pure returns (bool) {
        if (!isFriday0800(ts)) return false;
        (, uint256 m,) = DateTimeLib.timestampToDate(ts);
        (, uint256 m2,) = DateTimeLib.timestampToDate(ts + 7 * DAY);
        return m != m2;
    }
}
