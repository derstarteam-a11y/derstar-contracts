// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {FixedPointMathLib as M} from "solady/utils/FixedPointMathLib.sol";

/// @title BlackScholes
/// @notice European option price and delta with zero rates, in 18-decimal fixed point.
/// The normal CDF uses Zelen & Severo (Abramowitz-Stegun 26.2.17), |error| < 7.5e-8.
library BlackScholes {
    int256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;
    int256 internal constant INV_SQRT_2PI = 398942280401432678; // 1/sqrt(2*pi)

    error InvalidInput();

    /// @param spot1e8 spot in USD, 8 decimals
    /// @param strike strike in whole USD
    /// @param secondsToExpiry time left
    /// @param vol1e6 annualised volatility, 6 decimals
    /// @return premium1e8 option price per contract in USD, 8 decimals
    /// @return delta1e6 delta, 6 decimals (negative for puts)
    function price(uint256 spot1e8, uint256 strike, uint256 secondsToExpiry, uint256 vol1e6, bool isCall)
        external
        pure
        returns (uint256 premium1e8, int256 delta1e6)
    {
        // Bounds keep every int cast below exact; real inputs are many orders of magnitude smaller.
        if (spot1e8 == 0 || strike == 0 || spot1e8 > 1e20 || strike > 1e12 || vol1e6 > 1e8) revert InvalidInput();
        if (secondsToExpiry > 10 * YEAR) revert InvalidInput();
        // forge-lint: disable-start(unsafe-typecast)
        uint256 s = spot1e8 * 1e10; // wad
        uint256 k = strike * 1e18; // wad
        if (secondsToExpiry == 0 || vol1e6 == 0) {
            uint256 intrinsic = isCall ? (s > k ? s - k : 0) : (k > s ? k - s : 0);
            int256 d = isCall ? (s > k ? int256(1e6) : int256(0)) : (k > s ? -1e6 : int256(0));
            return (intrinsic / 1e10, d);
        }

        // sigma * sqrt(T) in wad
        uint256 sqrtT = M.sqrt(secondsToExpiry * 1e36 / YEAR); // sqrt(T years) in wad
        int256 sigSqrtT = int256(vol1e6 * 1e12 * sqrtT / 1e18);
        // d1 = (ln(S/K) + sigma^2 T / 2) / (sigma sqrt T)
        int256 lnSK = M.lnWad(int256(s * 1e18 / k));
        int256 d1 = (lnSK + sigSqrtT * sigSqrtT / (2 * WAD)) * WAD / sigSqrtT;
        int256 d2 = d1 - sigSqrtT;

        int256 nd1 = cdf(d1);
        int256 nd2 = cdf(d2);
        int256 p;
        if (isCall) {
            p = int256(s) * nd1 / WAD - int256(k) * nd2 / WAD;
            delta1e6 = nd1 / 1e12;
        } else {
            p = int256(k) * (WAD - nd2) / WAD - int256(s) * (WAD - nd1) / WAD;
            delta1e6 = (nd1 - WAD) / 1e12;
        }
        premium1e8 = p > 0 ? uint256(p) / 1e10 : 0;
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @notice Standard normal CDF of a wad value, returned in wad.
    function cdf(int256 x) internal pure returns (int256) {
        if (x > 8 * WAD) return WAD;
        if (x < -8 * WAD) return 0;
        int256 ax = x < 0 ? -x : x;
        // t = 1 / (1 + p * |x|)
        int256 t = WAD * WAD / (WAD + 231641900000000000 * ax / WAD);
        int256 poly = t
            * (319381530000000000
                + t
                * (-356563782000000000
                    + t
                    * (1781477937000000000 + t * (-1821255978000000000 + t * 1330274429000000000 / WAD) / WAD)
                    / WAD)
                / WAD) / WAD;
        int256 pdf = INV_SQRT_2PI * M.expWad(-(ax * ax / WAD) / 2) / WAD;
        int256 upper = WAD - pdf * poly / WAD; // N(|x|)
        return x < 0 ? WAD - upper : upper;
    }
}
