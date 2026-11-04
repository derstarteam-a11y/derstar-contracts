// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Side} from "../types/DerstarTypes.sol";

/// @notice A vault that quotes virtually: the order book asks for its price during matching.
interface IQuoteVault {
    /// @param vaultSide Sell = the vault sells (taker buys), Buy = the vault buys back (taker sells)
    /// @return priceTicks price per contract in ticks; 0 or availableLots == 0 means no quote
    function quote(uint256 seriesId, Side vaultSide, uint64 lots)
        external
        view
        returns (uint32 priceTicks, uint64 availableLots);
}
