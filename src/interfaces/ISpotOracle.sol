// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice Spot price used for fees and vault quotes. Implemented by OracleAdapter.
interface ISpotOracle {
    /// @return price1e8 USD price with 8 decimals, after staleness and sequencer checks
    function spot(uint8 underlying) external view returns (uint256 price1e8, uint256 updatedAt);
}
