// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface IIvFeed {
    /// @notice Volatility smile of one expiry: sigma(k) = atm + skew*k + curv*k^2, k = ln(K/S).
    /// All values are annualised volatility scaled by 1e6 (0.55 = 550 000). One storage slot.
    struct Smile {
        uint32 atmVol;
        int32 skew;
        int32 curv;
        uint40 updatedAt;
    }

    event SmileUpdated(uint8 indexed underlying, uint64 indexed expiry, uint32 atmVol, int32 skew, int32 curv);
    event BoundsSet(uint32 minVol, uint32 maxVol, uint32 maxJumpBps, uint32 maxAge);
    event ShapeBoundsSet(uint32 maxAbsSkew, uint32 maxAbsCurv);

    error LengthMismatch();
    error VolOutOfBounds(uint64 expiry, uint32 atmVol);
    error JumpTooLarge(uint64 expiry, uint32 previous, uint32 next);
    error ShapeOutOfBounds(uint64 expiry, int32 skew, int32 curv);
    error InvalidConfig();

    function push(uint8 underlying, uint64[] calldata expiries, Smile[] calldata smiles) external;

    function smile(uint8 underlying, uint64 expiry) external view returns (Smile memory);
    function iv(uint8 underlying, uint64 expiry, uint64 strike, uint256 spot1e8) external view returns (uint256 vol1e6);
    function isFresh(uint8 underlying, uint64 expiry) external view returns (bool);
}
