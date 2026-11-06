// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Series, SeriesState, UnderlyingConfig} from "../types/DerstarTypes.sol";

interface ISeriesRegistry {
    event UnderlyingSet(uint8 indexed underlying, string symbol, UnderlyingConfig cfg);
    event ExpiryListed(uint8 indexed underlying, uint64 indexed expiry, bool monthly);
    event SeriesCreated(
        uint256 indexed seriesId, uint8 indexed underlying, uint8 optType, uint64 expiry, uint64 strike
    );
    event SeriesSettled(uint256 indexed seriesId);
    event TradingCutoffSet(uint32 cutoff);
    event ClearingSet(address clearing);

    error UnderlyingDisabled(uint8 underlying);
    error InvalidExpiry(uint64 expiry);
    error InvalidStrike(uint64 strike);
    error TooManyStrikes(uint256 count, uint256 max);
    error ExpiryNotListed(uint64 expiry);
    error ConfigLocked(uint8 underlying);
    error InvalidConfig();
    error NotClearing();
    error ClearingAlreadySet();
    error SeriesNotActive(uint256 seriesId);

    // SERIES_ROLE (keeper). Calendar and grid are checked on-chain.
    function createExpiry(uint8 underlying, uint64 expiry, uint64[] calldata strikes) external;
    function addStrikes(uint8 underlying, uint64 expiry, uint64[] calldata strikes) external;

    // Views
    function getSeries(uint256 seriesId) external view returns (Series memory series, SeriesState state);
    function stateOf(uint256 seriesId) external view returns (SeriesState);
    function isTradable(uint256 seriesId) external view returns (bool);
    function config(uint8 underlying) external view returns (UnderlyingConfig memory);
    function symbolOf(uint8 underlying) external view returns (string memory);
    function quoteToken() external view returns (address);
    function isCollateral(address token) external view returns (bool);
    function tradingCutoff() external view returns (uint32);
    function listExpiries(uint8 underlying) external view returns (uint64[] memory);
    function activeExpiries(uint8 underlying) external view returns (uint64[] memory);
    function listSeries(uint8 underlying, uint64 expiry) external view returns (uint256[] memory);
    function isListed(uint8 underlying, uint64 expiry) external view returns (bool);
    function collateralPerLot(uint256 seriesId) external view returns (address token, uint256 amount);
    function premiumForTicks(uint256 seriesId, uint32 priceTicks, uint64 lots) external view returns (uint256);

    // Clearing only
    function markSettled(uint256 seriesId) external;

    // Admin (Timelock)
    function setUnderlying(uint8 underlying, string calldata symbol, UnderlyingConfig calldata cfg) external;
    function setTradingCutoff(uint32 cutoff) external;
    function setClearing(address clearing) external;
}
