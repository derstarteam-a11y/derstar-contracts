// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IIvFeed} from "../interfaces/IIvFeed.sol";

/// @title IvFeed
/// @notice Implied volatility published by our keeper (Deribit/Bybit marks fitted to a smile).
/// This is the protocol's main off-chain trust point, so the contract bounds what the keeper
/// can do: absolute vol limits, bounds on the smile's shape, a cap on how far ATM vol may jump in
/// one update, and staleness. The keeper cross-checks two venues before it publishes.
contract IvFeed is IIvFeed, AccessControl {
    bytes32 public constant PUBLISHER_ROLE = keccak256("PUBLISHER_ROLE");

    uint32 public minVol = 50_000; // 5%
    uint32 public maxVol = 3_000_000; // 300%
    uint32 public maxJumpBps = 3_000; // ATM vol may move at most 30% of itself per update
    uint32 public maxAge = 15 minutes;
    uint32 public maxAbsSkew = 3_000_000; // |skew| <= 3.0 vol per unit of ln(K/S)
    uint32 public maxAbsCurv = 30_000_000; // |curv| <= 30.0

    mapping(uint8 => mapping(uint64 => Smile)) internal _smiles;

    constructor(address admin, address publisher) {
        if (admin == address(0)) revert InvalidConfig();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (publisher != address(0)) _grantRole(PUBLISHER_ROLE, publisher);
    }

    function push(uint8 underlying, uint64[] calldata expiries, Smile[] calldata smiles)
        external
        onlyRole(PUBLISHER_ROLE)
    {
        if (expiries.length != smiles.length) revert LengthMismatch();
        for (uint256 i; i < expiries.length; ++i) {
            uint64 e = expiries[i];
            Smile calldata s = smiles[i];
            if (s.atmVol < minVol || s.atmVol > maxVol) revert VolOutOfBounds(e, s.atmVol);
            if (_abs(s.skew) > maxAbsSkew || _abs(s.curv) > maxAbsCurv) revert ShapeOutOfBounds(e, s.skew, s.curv);

            Smile storage prev = _smiles[underlying][e];
            // The jump cap applies only against a fresh value, so a stalled feed can recover.
            if (prev.updatedAt + maxAge >= block.timestamp && prev.atmVol != 0) {
                uint256 diff = s.atmVol > prev.atmVol ? s.atmVol - prev.atmVol : prev.atmVol - s.atmVol;
                if (diff * 10_000 > uint256(prev.atmVol) * maxJumpBps) revert JumpTooLarge(e, prev.atmVol, s.atmVol);
            }
            // forge-lint: disable-next-line(unsafe-typecast) -- seconds fit in 40 bits for 30k years
            _smiles[underlying][e] = Smile(s.atmVol, s.skew, s.curv, uint40(block.timestamp));
            emit SmileUpdated(underlying, e, s.atmVol, s.skew, s.curv);
        }
    }

    function smile(uint8 underlying, uint64 expiry) external view returns (Smile memory) {
        return _smiles[underlying][expiry];
    }

    /// @notice Volatility for a strike, clamped to [minVol, maxVol]. 0 if no smile exists.
    function iv(uint8 underlying, uint64 expiry, uint64 strike, uint256 spot1e8) external view returns (uint256) {
        Smile memory s = _smiles[underlying][expiry];
        if (s.atmVol == 0 || spot1e8 == 0) return 0;
        // k = ln(K / S) in 1e18
        int256 k = FixedPointMathLib.lnWad(int256(FixedPointMathLib.mulDiv(uint256(strike) * 1e8, 1e18, spot1e8)));
        int256 v = int256(uint256(s.atmVol)) + (int256(s.skew) * k) / 1e18 + int256(s.curv) * k * k / 1e36;
        if (v < int256(uint256(minVol))) return minVol;
        if (v > int256(uint256(maxVol))) return maxVol;
        // forge-lint: disable-next-line(unsafe-typecast) -- v is within [minVol, maxVol] here
        return uint256(v);
    }

    function isFresh(uint8 underlying, uint64 expiry) external view returns (bool) {
        Smile memory s = _smiles[underlying][expiry];
        return s.atmVol != 0 && s.updatedAt + maxAge >= block.timestamp;
    }

    function setBounds(uint32 minVol_, uint32 maxVol_, uint32 maxJumpBps_, uint32 maxAge_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (minVol_ == 0 || maxVol_ <= minVol_ || maxJumpBps_ == 0 || maxAge_ == 0) revert InvalidConfig();
        (minVol, maxVol, maxJumpBps, maxAge) = (minVol_, maxVol_, maxJumpBps_, maxAge_);
        emit BoundsSet(minVol_, maxVol_, maxJumpBps_, maxAge_);
    }

    function setShapeBounds(uint32 maxAbsSkew_, uint32 maxAbsCurv_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            maxAbsSkew_ == 0 || maxAbsCurv_ == 0 || maxAbsSkew_ > uint32(type(int32).max)
                || maxAbsCurv_ > uint32(type(int32).max)
        ) {
            revert InvalidConfig();
        }
        (maxAbsSkew, maxAbsCurv) = (maxAbsSkew_, maxAbsCurv_);
        emit ShapeBoundsSet(maxAbsSkew_, maxAbsCurv_);
    }

    function _abs(int32 x) internal pure returns (uint32) {
        // forge-lint: disable-next-line(unsafe-typecast) -- |int32| fits in uint32
        return x < 0 ? uint32(uint64(-int64(x))) : uint32(x);
    }
}
