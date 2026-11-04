// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BlackScholes} from "../src/libraries/BlackScholes.sol";

contract BlackScholesHarness {
    function price(uint256 s, uint256 k, uint256 t, uint256 v, bool c) external pure returns (uint256, int256) {
        return BlackScholes.price(s, k, t, v, c);
    }
}

/// @dev Reference values computed in Python with math.erf (exact normal CDF).
contract BlackScholesTest is Test {
    BlackScholesHarness internal h = new BlackScholesHarness();

    function _check(uint256 s, uint256 k, uint256 t, uint256 v, bool c, uint256 want, int256 wantDelta) internal view {
        (uint256 p, int256 d) = h.price(s, k, t, v, c);
        // The CDF approximation errs by < 7.5e-8 per term, so allow 2e-7 of (S + K), at least 1 cent.
        // For BTC that is about 4 cents, far below the 5 USDC price tick.
        uint256 tol = (s + k * 1e8) * 2 / 1e7;
        if (tol < 1e6) tol = 1e6;
        assertApproxEqAbs(p, want, tol, "premium");
        assertApproxEqAbs(d, wantDelta, 2, "delta");
    }

    function test_matchesReference() public view {
        _check(104000e8, 110000, 1454400, 550000, true, 259587310273, 338771);
        _check(104000e8, 110000, 1454400, 550000, false, 859587310273, -661229);
        _check(104000e8, 100000, 604800, 450000, false, 102141569923, -254460);
        _check(104000e8, 104000, 604800, 500000, true, 287229633734, 513809);
        _check(104000e8, 80000, 3600, 600000, true, 2400000000000, 1000000);
        _check(104000e8, 140000, 5184000, 800000, true, 378285156994, 225345);
        _check(3100e8, 3000, 172800, 700000, false, 2525509772, -255039);
        _check(3100e8, 4000, 3888000, 650000, true, 5311081142, 158001);
        _check(104000e8, 104000, 600, 500000, false, 9048688649, -499565);
        _check(104000e8, 60000, 2592000, 1500000, false, 159122668782, -67576);
        _check(50000e8, 200000, 31536000, 1000000, true, 346094329792, 187729);
        _check(104000e8, 106000, 86400, 50000, true, 0, 0);
    }

    function test_putCallParity(uint256 spot, uint256 strike, uint256 t, uint256 vol) public view {
        spot = bound(spot, 1_000e8, 500_000e8);
        strike = bound(strike, 500, 1_000_000);
        t = bound(t, 60, 120 days);
        vol = bound(vol, 50_000, 2_000_000);
        (uint256 c,) = h.price(spot, strike, t, vol, true);
        (uint256 p,) = h.price(spot, strike, t, vol, false);
        // C - P = S - K with zero rates
        int256 lhs = int256(c) - int256(p);
        int256 rhs = int256(spot) - int256(strike * 1e8);
        assertApproxEqAbs(lhs, rhs, 2, "parity");
    }

    function test_expiredIsIntrinsic() public view {
        (uint256 p, int256 d) = h.price(104_000e8, 100_000, 0, 500_000, true);
        assertEq(p, 4_000e8);
        assertEq(d, 1e6);
        (p, d) = h.price(104_000e8, 100_000, 0, 500_000, false);
        assertEq(p, 0);
        assertEq(d, 0);
    }

    function test_gas() public {
        uint256 g = gasleft();
        h.price(104_000e8, 110_000, 7 days, 550_000, true);
        emit log_named_uint("BlackScholes.price gas (incl. external call)", g - gasleft());
    }
}
