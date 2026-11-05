// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOrderBook} from "../interfaces/IOrderBook.sol";
import {IClearing} from "../interfaces/IClearing.sol";
import {ISeriesRegistry} from "../interfaces/ISeriesRegistry.sol";
import {IIvFeed} from "../interfaces/IIvFeed.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {Side, Series, OptionType} from "../types/DerstarTypes.sol";
import {SeriesId} from "../libraries/SeriesId.sol";
import {BlackScholes} from "../libraries/BlackScholes.sol";

/// @title StopOrders
/// @notice Stop-loss orders that close a position at market once its mark price crosses a trigger.
///
/// A stop sells a long when the mark falls to `triggerTicks` or below, or buys back a short when the
/// mark rises to `triggerTicks` or above. The mark is the protocol's model price: Black-Scholes from
/// the oracle spot and the IvFeed smile, the same inputs the vaults quote from. Anyone may trigger a
/// stop whose condition holds (a keeper does it in practice); the close then takes the book through
/// OrderBook.takeFor, no worse than the owner's `limitTicks`.
///
/// The stop never opens a position: it closes at most what the owner holds when it fires, so a long
/// already sold or a short already bought back simply ends the stop. Nothing is reserved while a stop
/// waits; a buy-back pays from the owner's wallet like any market buy (USDC allowance to Clearing).
contract StopOrders is ReentrancyGuard {
    struct Stop {
        address owner;
        uint64 lots;
        uint32 triggerTicks;
        uint32 limitTicks;
        Side side; // the closing trade: Sell closes a long, Buy closes a short
        uint256 seriesId;
    }

    uint16 public constant MAX_STOPS_PER_ACCOUNT = 32;

    IOrderBook public immutable book;
    IClearing public immutable clearing;
    ISeriesRegistry public immutable registry;
    IIvFeed public immutable ivFeed;

    uint64 public nextStopId;
    mapping(uint64 => Stop) internal _stops;
    mapping(address => uint16) public stopCount;

    event StopPlaced(
        uint64 indexed stopId,
        address indexed owner,
        uint256 indexed seriesId,
        Side side,
        uint64 lots,
        uint32 triggerTicks,
        uint32 limitTicks
    );
    event StopRemoved(uint64 indexed stopId);
    event StopTriggered(uint64 indexed stopId, address indexed owner, uint64 filled, uint32 markTicks, uint64 lotsLeft);

    error InvalidSize();
    error InvalidPrice();
    error NoPosition(uint256 seriesId);
    error TooManyStops();
    error NotStopOwner(uint64 stopId);
    error UnknownStop(uint64 stopId);
    error SeriesNotTradable(uint256 seriesId);
    error MarkUnavailable(uint256 seriesId);
    error NotTriggered(uint64 stopId, uint32 markTicks);

    constructor(IOrderBook book_, IClearing clearing_, ISeriesRegistry registry_, IIvFeed ivFeed_) {
        (book, clearing, registry, ivFeed) = (book_, clearing_, registry_, ivFeed_);
    }

    // ================================================================ owners

    /// @param side Sell to protect a long, Buy to protect a short.
    /// @param triggerTicks mark price per contract, in ticks, that fires the stop
    /// @param limitTicks worst price per contract the close may fill at (Sell: at least, Buy: at most)
    function place(uint256 seriesId, Side side, uint64 lots, uint32 triggerTicks, uint32 limitTicks)
        external
        nonReentrant
        returns (uint64 stopId)
    {
        if (lots == 0) revert InvalidSize();
        // A sell limit above its trigger (or a buy limit below it) could never fill when it fires.
        if (
            triggerTicks == 0 || limitTicks == 0
                || (side == Side.Sell ? limitTicks > triggerTicks : limitTicks < triggerTicks)
        ) {
            revert InvalidPrice();
        }
        if (!registry.isTradable(seriesId)) revert SeriesNotTradable(seriesId);
        if (_held(msg.sender, seriesId, side) == 0) revert NoPosition(seriesId);
        if (stopCount[msg.sender] >= MAX_STOPS_PER_ACCOUNT) revert TooManyStops();

        stopId = ++nextStopId;
        _stops[stopId] = Stop(msg.sender, lots, triggerTicks, limitTicks, side, seriesId);
        ++stopCount[msg.sender];
        emit StopPlaced(stopId, msg.sender, seriesId, side, lots, triggerTicks, limitTicks);
    }

    function cancel(uint64 stopId) external nonReentrant {
        Stop storage s = _stops[stopId];
        if (s.owner == address(0)) revert UnknownStop(stopId);
        if (s.owner != msg.sender) revert NotStopOwner(stopId);
        _delete(stopId, s.owner);
    }

    // ================================================================ keepers

    /// @notice Fires a stop whose condition holds. Reverts if it does not, or if the book has nothing
    /// within the owner's limit (the stop stays and can be tried again). A stop on a position that is
    /// already gone, or on a series past its trading cutoff, is removed instead.
    function trigger(uint64 stopId) external nonReentrant returns (uint64 filled) {
        Stop memory s = _stops[stopId];
        if (s.owner == address(0)) revert UnknownStop(stopId);

        uint256 held = _held(s.owner, s.seriesId, s.side);
        if (held == 0 || !registry.isTradable(s.seriesId)) {
            _delete(stopId, s.owner);
            return 0;
        }

        uint32 mark = markTicks(s.seriesId);
        if (s.side == Side.Sell ? mark > s.triggerTicks : mark < s.triggerTicks) revert NotTriggered(stopId, mark);

        // forge-lint: disable-next-line(unsafe-typecast) -- held is below s.lots (a uint64) here
        uint64 lots = held < s.lots ? uint64(held) : s.lots;
        filled = book.takeFor(s.owner, s.seriesId, s.side, lots, s.limitTicks);

        // The position is closed (or the stop is used up): the stop ends. Otherwise the rest waits.
        uint64 left = filled >= lots ? 0 : s.lots - filled;
        if (left == 0) _delete(stopId, s.owner);
        else _stops[stopId].lots = left;
        emit StopTriggered(stopId, s.owner, filled, mark, left);
    }

    // ================================================================ views

    /// @notice Model price per contract in ticks, rounded down. Reverts if spot or vol is stale.
    function markTicks(uint256 seriesId) public view returns (uint32) {
        Series memory s = SeriesId.decode(seriesId);
        if (!ivFeed.isFresh(s.underlying, s.expiry)) revert MarkUnavailable(seriesId);
        (uint256 spot,) = clearing.oracle().spot(s.underlying);
        uint256 tte = s.expiry > block.timestamp ? s.expiry - block.timestamp : 0;
        uint256 vol = tte == 0 ? 0 : ivFeed.iv(s.underlying, s.expiry, s.strike, spot);
        (uint256 fair1e8,) = BlackScholes.price(spot, s.strike, tte, vol, s.optType == OptionType.Call);
        uint256 ticks = fair1e8 / 100 / registry.config(s.underlying).tickSize;
        // forge-lint: disable-next-line(unsafe-typecast) -- capped just below
        return ticks > type(uint32).max ? type(uint32).max : uint32(ticks);
    }

    /// @notice Whether trigger() would fire now (ignores the book's depth).
    function isTriggered(uint64 stopId) external view returns (bool) {
        Stop memory s = _stops[stopId];
        if (s.owner == address(0)) return false;
        try this.markTicks(s.seriesId) returns (uint32 mark) {
            return s.side == Side.Sell ? mark <= s.triggerTicks : mark >= s.triggerTicks;
        } catch {
            return false;
        }
    }

    function getStop(uint64 stopId) external view returns (Stop memory) {
        return _stops[stopId];
    }

    // ================================================================ internal

    /// @dev What the closing trade may take: free long tokens for a sell, the open short for a buy.
    /// Longs held in the owner's own resting sell orders or pledged under a spread are not free.
    function _held(address owner, uint256 seriesId, Side side) internal view returns (uint256) {
        return side == Side.Sell ? clearing.token().balanceOf(owner, seriesId) : clearing.shortOf(owner, seriesId);
    }

    function _delete(uint64 stopId, address owner) internal {
        delete _stops[stopId];
        --stopCount[owner];
        emit StopRemoved(stopId);
    }
}
