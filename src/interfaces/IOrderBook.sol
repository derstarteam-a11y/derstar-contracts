// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Side} from "../types/DerstarTypes.sol";

interface IOrderBook {
    struct OrderParams {
        uint256 seriesId;
        Side side;
        uint32 priceTicks;
        uint64 lots;
    }

    /// @notice One leg of a strategy. `limit` is the worst price in ticks (max for a buy, min for a
    /// sell). `pledgeFrom` != 0: before this sell, that many long tokens of `pledgeFrom` (bought in
    /// an earlier leg or held) are pledged as cover, so the leg is written without collateral.
    struct Leg {
        uint256 seriesId;
        Side side;
        uint64 lots;
        uint32 limit;
        uint256 pledgeFrom;
    }

    event OrderPlaced(
        uint64 indexed orderId,
        address indexed maker,
        uint256 indexed seriesId,
        Side side,
        uint32 priceTicks,
        uint64 lots
    );
    event OrderCancelled(uint64 indexed orderId, uint64 lotsLeft);
    event OrderFilled(uint64 indexed orderId, address indexed taker, uint64 lots, uint64 lotsLeft);
    event VaultFilled(
        address indexed vault,
        address indexed taker,
        uint256 indexed seriesId,
        Side vaultSide,
        uint32 priceTicks,
        uint64 lots
    );
    event Taken(address indexed taker, uint256 indexed seriesId, Side side, uint64 lots, uint256 premium, uint256 fee);
    event VaultForSet(uint8 indexed underlying, uint8 indexed optType, address vault);
    event MaxFillsSet(uint16 maxFills);
    event VolOrderPlaced(
        uint64 indexed orderId,
        address indexed maker,
        uint256 indexed seriesId,
        Side side,
        uint32 vol,
        uint32 limitTicks,
        uint64 lots
    );
    event VolPricingSet(address oracle, uint32 maxSpotAge, uint16 maxVolOrdersPerSide);

    error SeriesNotTradable(uint256 seriesId);
    error InvalidPrice(uint32 priceTicks);
    error InvalidSize();
    error WouldCross(uint32 priceTicks, uint32 bestOpposite);
    error NotOrderOwner(uint64 orderId);
    error UnknownOrder(uint64 orderId);
    error Expired(uint64 deadline);
    error BelowMinLots(uint64 filled, uint64 minLots);
    error StillTradable(uint256 seriesId);
    error InvalidConfig();
    error InvalidVol(uint32 vol);
    error TooManyVolOrders(uint256 seriesId, Side side);
    error VolOrdersDisabled();

    // Makers. Every limit order is post-only: crossing the other side reverts.
    function placeOrder(uint256 seriesId, Side side, uint32 priceTicks, uint64 lots) external returns (uint64 orderId);
    function placeOrders(OrderParams[] calldata orders) external returns (uint64[] memory orderIds);
    function cancel(uint64 orderId) external;
    function cancelMany(uint64[] calldata orderIds) external;
    function replace(uint64 orderId, uint32 newPriceTicks, uint64 newLots) external returns (uint64 newOrderId);
    function purgeExpired(uint256 seriesId, uint32 maxOrders) external returns (uint32 purged);

    // Volatility orders: quoted in implied vol (1e6 = 100%), priced by Black-Scholes from spot at
    // match time. limitTicks caps a bid's price (and sizes its reserve) and floors an ask's.
    function placeVolOrder(uint256 seriesId, Side side, uint32 vol, uint32 limitTicks, uint64 lots)
        external
        returns (uint64 orderId);

    // Takers: fill now up to `lots`, never worse than the limit.
    function buy(uint256 seriesId, uint64 lots, uint32 maxPriceTicks, uint64 minLots, uint64 deadline)
        external
        returns (uint64 filled, uint256 premium, uint256 fee);
    function sell(uint256 seriesId, uint64 lots, uint32 minPriceTicks, uint64 minLots, uint64 deadline)
        external
        returns (uint64 filled, uint256 premium, uint256 fee);
    /// @notice Up to 4 legs in one transaction, each filled in full or the whole call reverts.
    function takeLegs(Leg[] calldata legs, uint64 deadline) external;

    // Views
    function preview(uint256 seriesId, Side side, uint64 lots, uint32 limitTicks, address taker)
        external
        view
        returns (
            uint64 filled,
            uint256 premium,
            uint256 fee,
            uint32 worstTicks,
            uint256 collateralNeeded,
            uint256 collateralFreed
        );
    function best(uint256 seriesId)
        external
        view
        returns (uint32 bidTicks, uint64 bidLots, uint32 askTicks, uint64 askLots);
    function depth(uint256 seriesId, Side side, uint8 levels)
        external
        view
        returns (uint32[] memory prices, uint64[] memory lots);
    function getOrder(uint64 orderId)
        external
        view
        returns (address maker, uint256 seriesId, Side side, uint32 priceTicks, uint64 lotsLeft);
    function getVolOrder(uint64 orderId)
        external
        view
        returns (address maker, uint256 seriesId, Side side, uint32 vol, uint32 limitTicks, uint64 lotsLeft);
    function volBook(uint256 seriesId, Side side, uint16 maxOrders)
        external
        view
        returns (uint64[] memory ids, uint32[] memory vols, uint64[] memory lots, uint32[] memory priceTicks);
}
