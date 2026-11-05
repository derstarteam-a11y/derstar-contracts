// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOrderBook} from "../interfaces/IOrderBook.sol";
import {IClearing} from "../interfaces/IClearing.sol";
import {ISeriesRegistry} from "../interfaces/ISeriesRegistry.sol";
import {IQuoteVault} from "../interfaces/IQuoteVault.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {Side, Fill, SeriesState, Series, OptionType, UnderlyingConfig} from "../types/DerstarTypes.sol";
import {TickBitmap} from "../libraries/TickBitmap.sol";
import {SeriesId} from "../libraries/SeriesId.sol";
import {BlackScholes} from "../libraries/BlackScholes.sol";

/// @title OrderBook
/// @notice Fully on-chain limit order book with price-time priority, one book per series with
/// a bid side and an ask side. It holds no funds: Clearing reserves collateral when an order is
/// placed and executes every fill.
///
/// Takers also see the protocol vault's virtual quote for the series. The vault fills only when
/// strictly better than the best resting order, so at equal prices real makers go first.
///
/// Next to the price book each series has a volatility book: orders quoted in implied vol,
/// repriced with Black-Scholes from Chainlink spot whenever a taker arrives, so a maker's quote
/// follows the underlying without updates. They queue by vol and fill only when strictly better
/// than the price book at that moment.
contract OrderBook is IOrderBook, AccessControl, ReentrancyGuard {
    using TickBitmap for TickBitmap.Bitmap;

    uint32 public constant MAX_TICK = type(uint16).max;

    ISeriesRegistry public immutable registry;
    IClearing public immutable clearing;

    uint16 public maxFillsPerTx = 32;
    uint64 public nextOrderId;

    struct Order {
        address maker;
        uint64 prev;
        uint64 next;
        uint64 lots;
        uint16 tick;
        Side side;
        uint256 seriesId;
    }

    struct Level {
        uint64 head;
        uint64 tail;
        uint64 totalLots;
    }

    mapping(uint64 => Order) internal _orders;
    mapping(bytes32 => TickBitmap.Bitmap) internal _bitmaps;
    mapping(bytes32 => mapping(uint16 => Level)) internal _levels;

    /// @notice Vault quoting each (underlying, option type): key = underlying << 8 | optType.
    mapping(uint16 => address) public vaultFor;

    uint32 public constant MIN_VOL = 10_000; // 1%
    uint32 public constant MAX_VOL = 10_000_000; // 1000%
    uint256 internal constant MAX_VOL_SCANS = 16;

    struct VolOrder {
        address maker;
        uint64 prev;
        uint64 next;
        uint64 lots;
        uint32 vol;
        uint16 limitTick;
        Side side;
        uint256 seriesId;
    }

    /// @notice Spot source for vol orders. Unset: vol orders are off.
    IOracleAdapter public oracle;
    uint32 public maxSpotAge = 2 hours;
    uint16 public maxVolOrdersPerSide = 64;

    mapping(uint64 => VolOrder) internal _volOrders;
    /// @dev Bids sorted by vol descending, asks ascending; equal vols keep arrival order.
    mapping(bytes32 => uint64) internal _volHead;
    mapping(bytes32 => uint16) public volOrderCount;

    constructor(address admin, ISeriesRegistry registry_, IClearing clearing_) {
        if (admin == address(0)) revert InvalidConfig();
        registry = registry_;
        clearing = clearing_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ================================================================ makers

    function placeOrder(uint256 seriesId, Side side, uint32 priceTicks, uint64 lots)
        external
        nonReentrant
        returns (uint64 orderId)
    {
        return _place(msg.sender, seriesId, side, priceTicks, lots);
    }

    function placeOrders(OrderParams[] calldata orders) external nonReentrant returns (uint64[] memory orderIds) {
        orderIds = new uint64[](orders.length);
        for (uint256 i; i < orders.length; ++i) {
            OrderParams calldata o = orders[i];
            orderIds[i] = _place(msg.sender, o.seriesId, o.side, o.priceTicks, o.lots);
        }
    }

    /// @notice Always allowed, also after the trading cutoff.
    function cancel(uint64 orderId) external nonReentrant {
        _cancelOwn(orderId);
    }

    function cancelMany(uint64[] calldata orderIds) external nonReentrant {
        for (uint256 i; i < orderIds.length; ++i) {
            _cancelOwn(orderIds[i]);
        }
    }

    /// @notice Cancel and re-place in one transaction. The new order goes to the back of its queue.
    function replace(uint64 orderId, uint32 newPriceTicks, uint64 newLots)
        external
        nonReentrant
        returns (uint64 newOrderId)
    {
        Order storage o = _orders[orderId];
        (uint256 seriesId, Side side) = (o.seriesId, o.side);
        _cancelOwn(orderId);
        return _place(msg.sender, seriesId, side, newPriceTicks, newLots);
    }

    /// @notice After the cutoff anyone can clear a series' book so makers get their reserves back.
    function purgeExpired(uint256 seriesId, uint32 maxOrders) external nonReentrant returns (uint32 purged) {
        if (registry.stateOf(seriesId) == SeriesState.None || registry.isTradable(seriesId)) {
            revert StillTradable(seriesId);
        }
        for (uint256 s; s < 2 && purged < maxOrders; ++s) {
            Side side = Side(s);
            TickBitmap.Bitmap storage bm = _bitmaps[_key(seriesId, side)];
            while (purged < maxOrders) {
                (uint16 tick, bool has) = bm.lowest();
                if (!has) break;
                _remove(_levels[_key(seriesId, side)][tick].head);
                ++purged;
            }
            bytes32 key = _key(seriesId, side);
            while (purged < maxOrders && _volHead[key] != 0) {
                _removeVol(_volHead[key]);
                ++purged;
            }
        }
    }

    function _place(address maker, uint256 seriesId, Side side, uint32 priceTicks, uint64 lots)
        internal
        returns (uint64 orderId)
    {
        if (!registry.isTradable(seriesId)) revert SeriesNotTradable(seriesId);
        if (priceTicks == 0 || priceTicks > MAX_TICK) revert InvalidPrice(priceTicks);
        if (lots == 0) revert InvalidSize();
        // forge-lint: disable-next-line(unsafe-typecast) -- bounded by MAX_TICK above
        uint16 tick = uint16(priceTicks);

        // Post-only: a bid must stay below the best ask, an ask above the best bid.
        if (side == Side.Buy) {
            (uint16 bestAsk, bool has) = _bitmaps[_key(seriesId, Side.Sell)].lowest();
            if (has && tick >= bestAsk) revert WouldCross(priceTicks, bestAsk);
        } else {
            (uint16 bestBid, bool has) = _bitmaps[_key(seriesId, Side.Buy)].highest();
            if (has && tick <= bestBid) revert WouldCross(priceTicks, bestBid);
        }

        orderId = ++nextOrderId;
        if (side == Side.Buy) clearing.reserveBid(maker, orderId, seriesId, lots, priceTicks);
        else clearing.reserveAsk(maker, orderId, seriesId, lots);

        bytes32 key = _key(seriesId, side);
        Level storage lvl = _levels[key][tick];
        _orders[orderId] = Order(maker, lvl.tail, 0, lots, tick, side, seriesId);
        if (lvl.tail != 0) _orders[lvl.tail].next = orderId;
        else lvl.head = orderId;
        lvl.tail = orderId;
        lvl.totalLots += lots;
        _bitmaps[key].set(tick);

        emit OrderPlaced(orderId, maker, seriesId, side, priceTicks, lots);
    }

    // ================================================================ vol orders

    function placeVolOrder(uint256 seriesId, Side side, uint32 vol, uint32 limitTicks, uint64 lots)
        external
        nonReentrant
        returns (uint64 orderId)
    {
        if (address(oracle) == address(0)) revert VolOrdersDisabled();
        if (!registry.isTradable(seriesId)) revert SeriesNotTradable(seriesId);
        if (vol < MIN_VOL || vol > MAX_VOL) revert InvalidVol(vol);
        if (limitTicks == 0 || limitTicks > MAX_TICK) revert InvalidPrice(limitTicks);
        if (lots == 0) revert InvalidSize();
        bytes32 key = _key(seriesId, side);
        if (volOrderCount[key] >= maxVolOrdersPerSide) revert TooManyVolOrders(seriesId, side);

        orderId = ++nextOrderId;
        // A bid reserves at its price cap, an ask its tokens or collateral, as for price orders.
        if (side == Side.Buy) clearing.reserveBid(msg.sender, orderId, seriesId, lots, limitTicks);
        else clearing.reserveAsk(msg.sender, orderId, seriesId, lots);

        // Find the first order this one ranks ahead of.
        uint64 prev;
        uint64 cur = _volHead[key];
        while (cur != 0) {
            uint32 v = _volOrders[cur].vol;
            if (side == Side.Buy ? vol > v : vol < v) break;
            prev = cur;
            cur = _volOrders[cur].next;
        }
        // forge-lint: disable-next-line(unsafe-typecast) -- bounded by MAX_TICK above
        _volOrders[orderId] = VolOrder(msg.sender, prev, cur, lots, vol, uint16(limitTicks), side, seriesId);
        if (prev != 0) _volOrders[prev].next = orderId;
        else _volHead[key] = orderId;
        if (cur != 0) _volOrders[cur].prev = orderId;
        ++volOrderCount[key];

        emit VolOrderPlaced(orderId, msg.sender, seriesId, side, vol, limitTicks, lots);
    }

    function _removeVol(uint64 orderId) internal {
        uint64 left = _volOrders[orderId].lots;
        _unlinkVol(orderId);
        clearing.release(orderId);
        emit OrderCancelled(orderId, left);
    }

    function _unlinkVol(uint64 orderId) internal {
        VolOrder storage o = _volOrders[orderId];
        bytes32 key = _key(o.seriesId, o.side);
        if (o.prev != 0) _volOrders[o.prev].next = o.next;
        else _volHead[key] = o.next;
        if (o.next != 0) _volOrders[o.next].prev = o.prev;
        --volOrderCount[key];
        delete _volOrders[orderId];
    }

    function _cancelOwn(uint64 orderId) internal {
        address maker = _orders[orderId].maker;
        bool vol = maker == address(0);
        if (vol) maker = _volOrders[orderId].maker;
        if (maker == address(0)) revert UnknownOrder(orderId);
        if (maker != msg.sender) revert NotOrderOwner(orderId);
        if (vol) _removeVol(orderId);
        else _remove(orderId);
    }

    function _remove(uint64 orderId) internal {
        uint64 left = _orders[orderId].lots;
        _unlink(orderId);
        clearing.release(orderId);
        emit OrderCancelled(orderId, left);
    }

    function _unlink(uint64 orderId) internal {
        Order storage o = _orders[orderId];
        bytes32 key = _key(o.seriesId, o.side);
        Level storage lvl = _levels[key][o.tick];
        if (o.prev != 0) _orders[o.prev].next = o.next;
        else lvl.head = o.next;
        if (o.next != 0) _orders[o.next].prev = o.prev;
        else lvl.tail = o.prev;
        lvl.totalLots -= o.lots;
        if (lvl.head == 0) _bitmaps[key].clear(o.tick);
        delete _orders[orderId];
    }

    // ================================================================ takers

    function buy(uint256 seriesId, uint64 lots, uint32 maxPriceTicks, uint64 minLots, uint64 deadline)
        external
        nonReentrant
        returns (uint64 filled, uint256 premium, uint256 fee)
    {
        return _take(seriesId, Side.Buy, lots, maxPriceTicks, minLots, deadline);
    }

    function sell(uint256 seriesId, uint64 lots, uint32 minPriceTicks, uint64 minLots, uint64 deadline)
        external
        nonReentrant
        returns (uint64 filled, uint256 premium, uint256 fee)
    {
        return _take(seriesId, Side.Sell, lots, minPriceTicks, minLots, deadline);
    }

    function takeLegs(Leg[] calldata legs, uint64 deadline) external nonReentrant {
        if (legs.length == 0 || legs.length > 4) revert InvalidSize();
        for (uint256 i; i < legs.length; ++i) {
            Leg calldata l = legs[i];
            if (l.pledgeFrom != 0) clearing.pledgeFor(msg.sender, l.pledgeFrom, l.seriesId, l.lots);
            _take(l.seriesId, l.side, l.lots, l.limit, l.lots, deadline);
        }
    }

    function _take(uint256 seriesId, Side side, uint64 lots, uint32 limit, uint64 minLots, uint64 deadline)
        internal
        returns (uint64 filled, uint256 premium, uint256 fee)
    {
        if (block.timestamp > deadline) revert Expired(deadline);
        if (lots == 0) revert InvalidSize();
        if (!registry.isTradable(seriesId)) revert SeriesNotTradable(seriesId);

        Fill[] memory fills;
        (fills, filled) = _collect(seriesId, side, lots, limit, msg.sender);
        if (filled == 0 || filled < minLots) revert BelowMinLots(filled, minLots);

        // Consume the resting orders first, then let Clearing move the money.
        uint64[] memory done = _consume(fills);
        (premium, fee) = clearing.settleFills(msg.sender, side, seriesId, fills);

        // Fully filled orders hand back what is left of their reserve (a bid's fee buffer).
        for (uint256 i; i < done.length; ++i) {
            clearing.release(done[i]);
        }
        _emitVaultFills(fills, seriesId, side);
        emit Taken(msg.sender, seriesId, side, filled, premium, fee);
    }

    /// @return done orders that were filled completely and left the book
    function _consume(Fill[] memory fills) internal returns (uint64[] memory done) {
        done = new uint64[](fills.length);
        uint256 nDone;
        for (uint256 i; i < fills.length; ++i) {
            if (fills[i].fromVault) continue;
            uint64 id = fills[i].orderId;
            uint64 q = fills[i].lots;
            VolOrder storage vo = _volOrders[id];
            if (vo.maker != address(0)) {
                vo.lots -= q;
                emit OrderFilled(id, msg.sender, q, vo.lots);
                if (vo.lots == 0) {
                    _unlinkVol(id);
                    done[nDone++] = id;
                }
                continue;
            }
            Order storage o = _orders[id];
            o.lots -= q;
            _levels[_key(o.seriesId, o.side)][o.tick].totalLots -= q;
            emit OrderFilled(id, msg.sender, q, o.lots);
            if (o.lots == 0) {
                _unlink(id);
                done[nDone++] = id;
            }
        }
        assembly {
            mstore(done, nDone)
        }
    }

    function _emitVaultFills(Fill[] memory fills, uint256 seriesId, Side side) internal {
        for (uint256 i; i < fills.length; ++i) {
            if (fills[i].fromVault) {
                emit VaultFilled(
                    fills[i].maker, msg.sender, seriesId, _opposite(side), fills[i].priceTicks, fills[i].lots
                );
            }
        }
    }

    /// @dev Matching cursor, kept in memory to stay clear of stack limits.
    struct Walk {
        bool takerBuys;
        uint32 limit;
        address taker;
        address vault;
        uint32 vPrice;
        uint64 vAvail;
        uint64 remaining;
        bytes32 key;
        uint16 tick;
        bool has;
        uint64 orderId;
        uint256 n;
        // Vol book: current candidate and pricing inputs
        uint64 volId;
        uint32 volPrice;
        uint256 volScans;
        uint256 spot;
        uint256 strike;
        uint256 tte;
        bool isCall;
        uint256 tickSize;
    }

    /// @dev Walks the opposite side in price-time order, merging in the vault quote.
    /// Read-only, so `preview` and `_take` share exactly the same matching.
    function _collect(uint256 seriesId, Side side, uint64 lots, uint32 limit, address taker)
        internal
        view
        returns (Fill[] memory fills, uint64 filled)
    {
        Walk memory w;
        w.takerBuys = side == Side.Buy;
        w.limit = limit;
        w.taker = taker;
        w.remaining = lots;
        fills = new Fill[](maxFillsPerTx);

        Side opp = _opposite(side);
        w.vault = vaultFor[_vaultKey(seriesId)];
        if (w.vault != address(0)) {
            (w.vPrice, w.vAvail) = IQuoteVault(w.vault).quote(seriesId, opp, lots);
            if (w.vPrice == 0 || w.vPrice > MAX_TICK) w.vAvail = 0;
        }

        w.key = _key(seriesId, opp);
        TickBitmap.Bitmap storage bm = _bitmaps[w.key];
        (w.tick, w.has) = w.takerBuys ? bm.lowest() : bm.highest();
        w.orderId = w.has ? _levels[w.key][w.tick].head : 0;

        uint64 volHead = _volHead[w.key];
        if (volHead != 0 && _volContext(w, seriesId)) _advanceVol(w, volHead);

        uint256 maxSteps = uint256(maxFillsPerTx) * 4;
        for (uint256 steps; w.remaining > 0 && w.n < fills.length && steps < maxSteps; ++steps) {
            if (!_step(w, fills, bm)) break;
        }

        uint256 n = w.n;
        assembly {
            mstore(fills, n)
        }
        filled = lots - w.remaining;
    }

    /// @dev One matching step. Returns false when nothing within the limit is left.
    function _step(Walk memory w, Fill[] memory fills, TickBitmap.Bitmap storage bm) internal view returns (bool) {
        if (
            w.vAvail > 0 && _within(w.takerBuys, w.vPrice, w.limit)
                && (!w.has || _better(w.takerBuys, w.vPrice, w.tick))
                && (w.volId == 0 || _better(w.takerBuys, w.vPrice, w.volPrice))
        ) {
            uint64 q = w.remaining < w.vAvail ? w.remaining : w.vAvail;
            fills[w.n++] = Fill(w.vault, 0, w.vPrice, q, true);
            w.remaining -= q;
            w.vAvail = 0;
            return true;
        }
        if (w.volId != 0 && (!w.has || _better(w.takerBuys, w.volPrice, w.tick))) {
            VolOrder storage vo = _volOrders[w.volId];
            uint64 q = w.remaining < vo.lots ? w.remaining : vo.lots;
            fills[w.n++] = Fill(vo.maker, w.volId, w.volPrice, q, false);
            w.remaining -= q;
            _advanceVol(w, vo.next);
            return true;
        }
        if (!w.has || !_within(w.takerBuys, w.tick, w.limit)) return false;
        if (w.orderId == 0) {
            (w.tick, w.has) = w.takerBuys ? bm.nextAbove(w.tick) : bm.nextBelow(w.tick);
            w.orderId = w.has ? _levels[w.key][w.tick].head : 0;
            return true;
        }
        Order storage o = _orders[w.orderId];
        // Self-trades are skipped, not filled: the taker's own order stays in the book.
        if (o.maker != w.taker) {
            uint64 q = w.remaining < o.lots ? w.remaining : o.lots;
            fills[w.n++] = Fill(o.maker, w.orderId, w.tick, q, false);
            w.remaining -= q;
        }
        w.orderId = o.next;
        return true;
    }

    /// @dev Loads spot and series terms for pricing vol orders. False if spot is unusable.
    function _volContext(Walk memory w, uint256 seriesId) internal view returns (bool) {
        if (address(oracle) == address(0)) return false;
        Series memory s = SeriesId.decode(seriesId);
        try oracle.spot(s.underlying) returns (uint256 p, uint256 at) {
            if (p == 0 || at + maxSpotAge < block.timestamp) return false;
            w.spot = p;
        } catch {
            return false;
        }
        w.strike = s.strike;
        w.tte = s.expiry > block.timestamp ? s.expiry - block.timestamp : 0;
        w.isCall = s.optType == OptionType.Call;
        w.tickSize = registry.config(s.underlying).tickSize;
        return true;
    }

    /// @dev Moves the vol cursor to the first order from `id` that is not the taker's own and
    /// prices within the taker's limit. Bounded, since each look costs a Black-Scholes run.
    function _advanceVol(Walk memory w, uint64 id) internal view {
        while (id != 0 && w.volScans < MAX_VOL_SCANS) {
            ++w.volScans;
            VolOrder storage o = _volOrders[id];
            if (o.maker != w.taker) {
                uint32 p = _volPrice(w, o.vol, o.limitTick, o.side);
                if (p != 0 && _within(w.takerBuys, p, w.limit)) {
                    (w.volId, w.volPrice) = (id, p);
                    return;
                }
            }
            id = o.next;
        }
        w.volId = 0;
    }

    /// @dev Ticks for a vol order now: bids round down and are capped, asks round up and floored.
    function _volPrice(Walk memory w, uint32 vol, uint16 limitTick, Side side) internal pure returns (uint32) {
        (uint256 fair1e8,) = BlackScholes.price(w.spot, w.strike, w.tte, vol, w.isCall);
        uint256 usdc = fair1e8 / 100; // per contract, 6 decimals
        uint256 ticks;
        if (side == Side.Buy) {
            ticks = usdc / w.tickSize;
            if (ticks > limitTick) ticks = limitTick;
        } else {
            ticks = (usdc + w.tickSize - 1) / w.tickSize;
            if (ticks < limitTick) ticks = limitTick;
            if (ticks > MAX_TICK) return 0;
        }
        // forge-lint: disable-next-line(unsafe-typecast) -- at most MAX_TICK here
        return uint32(ticks);
    }

    // ================================================================ views

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
        )
    {
        if (lots == 0 || !registry.isTradable(seriesId)) return (0, 0, 0, 0, 0, 0);
        Fill[] memory fills;
        (fills, filled) = _collect(seriesId, side, lots, limitTicks, taker);
        if (filled == 0) return (0, 0, 0, 0, 0, 0);
        for (uint256 i; i < fills.length; ++i) {
            uint32 p = fills[i].priceTicks;
            if (worstTicks == 0 || _better(side == Side.Buy, worstTicks, p)) worstTicks = p;
        }
        (premium, fee, collateralNeeded, collateralFreed) = _previewCost(taker, side, seriesId, fills);
    }

    /// @dev Running state of _previewCost (a struct keeps the stack shallow).
    struct Cost {
        uint256 lpc;
        uint256 tickUnit;
        uint256 perLot;
        uint256 feeNum;
        uint256 cap;
        uint256 tokens;
        uint256 plainShort;
        uint256 credit;
    }

    /// @dev What the taker would pay or receive for these fills (mirrors Clearing.settleFills).
    /// collateralIn: collateral the taker must bring for written lots; collateralOut: freed by covering.
    function _previewCost(address taker, Side side, uint256 seriesId, Fill[] memory fills)
        internal
        view
        returns (uint256 premium, uint256 fee, uint256 collateralIn, uint256 collateralOut)
    {
        Cost memory k;
        {
            uint8 u = SeriesId.underlying(seriesId);
            UnderlyingConfig memory cfg = registry.config(u);
            k.lpc = cfg.lotsPerContract;
            k.tickUnit = cfg.tickSize / cfg.lotsPerContract;
            (, k.perLot) = registry.collateralPerLot(seriesId);
            (uint256 spot,) = clearing.oracle().spot(u);
            k.feeNum = spot * clearing.notionalFeePpm();
            k.cap = clearing.premiumCapPpm();
            k.tokens = clearing.token().balanceOf(taker, seriesId);
            k.plainShort = clearing.shortOf(taker, seriesId) - clearing.coveredShort(taker, seriesId);
            k.credit = clearing.coverCredit(taker, seriesId);
        }
        for (uint256 i; i < fills.length; ++i) {
            uint256 lots = fills[i].lots;
            uint256 p = uint256(fills[i].priceTicks) * k.tickUnit * lots;
            premium += p;
            fee += _min256(k.feeNum * lots / (k.lpc * 1e8), p * k.cap / 1e6);
            if (side == Side.Sell) {
                uint256 use = _min256(k.tokens, lots);
                k.tokens -= use;
                uint256 cr = _min256(k.credit, lots - use);
                k.credit -= cr;
                collateralIn += (lots - use - cr) * k.perLot;
            } else {
                uint256 n = _min256(k.plainShort, lots);
                k.plainShort -= n;
                collateralOut += n * k.perLot;
            }
        }
    }

    function _min256(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function best(uint256 seriesId)
        external
        view
        returns (uint32 bidTicks, uint64 bidLots, uint32 askTicks, uint64 askLots)
    {
        bytes32 bk = _key(seriesId, Side.Buy);
        bytes32 ak = _key(seriesId, Side.Sell);
        (uint16 b, bool hb) = _bitmaps[bk].highest();
        (uint16 a, bool ha) = _bitmaps[ak].lowest();
        if (hb) (bidTicks, bidLots) = (b, _levels[bk][b].totalLots);
        if (ha) (askTicks, askLots) = (a, _levels[ak][a].totalLots);
    }

    function depth(uint256 seriesId, Side side, uint8 levels)
        external
        view
        returns (uint32[] memory prices, uint64[] memory lots)
    {
        prices = new uint32[](levels);
        lots = new uint64[](levels);
        bytes32 key = _key(seriesId, side);
        TickBitmap.Bitmap storage bm = _bitmaps[key];
        bool asks = side == Side.Sell;
        (uint16 tick, bool has) = asks ? bm.lowest() : bm.highest();
        uint256 n;
        while (has && n < levels) {
            prices[n] = tick;
            lots[n] = _levels[key][tick].totalLots;
            ++n;
            (tick, has) = asks ? bm.nextAbove(tick) : bm.nextBelow(tick);
        }
        assembly {
            mstore(prices, n)
            mstore(lots, n)
        }
    }

    function getOrder(uint64 orderId)
        external
        view
        returns (address maker, uint256 seriesId, Side side, uint32 priceTicks, uint64 lotsLeft)
    {
        Order storage o = _orders[orderId];
        return (o.maker, o.seriesId, o.side, o.tick, o.lots);
    }

    function getVolOrder(uint64 orderId)
        external
        view
        returns (address maker, uint256 seriesId, Side side, uint32 vol, uint32 limitTicks, uint64 lotsLeft)
    {
        VolOrder storage o = _volOrders[orderId];
        return (o.maker, o.seriesId, o.side, o.vol, o.limitTick, o.lots);
    }

    /// @notice Vol orders of one side in queue order, with their price in ticks right now
    /// (0 when spot is unavailable or the ask would exceed the tick range).
    function volBook(uint256 seriesId, Side side, uint16 maxOrders)
        external
        view
        returns (uint64[] memory ids, uint32[] memory vols, uint64[] memory lots, uint32[] memory priceTicks)
    {
        bytes32 key = _key(seriesId, side);
        uint256 n = volOrderCount[key];
        if (n > maxOrders) n = maxOrders;
        ids = new uint64[](n);
        vols = new uint32[](n);
        lots = new uint64[](n);
        priceTicks = new uint32[](n);
        Walk memory w;
        if (!_volContext(w, seriesId)) w.spot = 0;
        uint64 id = _volHead[key];
        for (uint256 i; i < n; ++i) {
            id = _volRow(w, id, i, ids, vols, lots, priceTicks);
        }
    }

    function _volRow(
        Walk memory w,
        uint64 id,
        uint256 i,
        uint64[] memory ids,
        uint32[] memory vols,
        uint64[] memory lots,
        uint32[] memory priceTicks
    ) internal view returns (uint64) {
        VolOrder storage o = _volOrders[id];
        ids[i] = id;
        vols[i] = o.vol;
        lots[i] = o.lots;
        if (w.spot != 0) priceTicks[i] = _volPrice(w, o.vol, o.limitTick, o.side);
        return o.next;
    }

    // ================================================================ admin

    function setVolPricing(IOracleAdapter oracle_, uint32 maxSpotAge_, uint16 maxPerSide)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (maxSpotAge_ == 0 || maxPerSide == 0) revert InvalidConfig();
        (oracle, maxSpotAge, maxVolOrdersPerSide) = (oracle_, maxSpotAge_, maxPerSide);
        emit VolPricingSet(address(oracle_), maxSpotAge_, maxPerSide);
    }

    function setVaultFor(uint8 underlying, uint8 optType, address vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        vaultFor[(uint16(underlying) << 8) | optType] = vault;
        emit VaultForSet(underlying, optType, vault);
    }

    function setMaxFillsPerTx(uint16 n) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (n == 0 || n > 256) revert InvalidConfig();
        maxFillsPerTx = n;
        emit MaxFillsSet(n);
    }

    // ================================================================ helpers

    function _key(uint256 seriesId, Side side) internal pure returns (bytes32) {
        return keccak256(abi.encode(seriesId, side));
    }

    /// @dev Series id layout: [underlying:8 | optType:8 | ...:128]; bits 128..143 are the key.
    function _vaultKey(uint256 seriesId) internal pure returns (uint16) {
        // forge-lint: disable-next-line(unsafe-typecast) -- takes exactly the two packed bytes
        return uint16(seriesId >> 128);
    }

    function _opposite(Side side) internal pure returns (Side) {
        return side == Side.Buy ? Side.Sell : Side.Buy;
    }

    /// @dev Buyer wants prices at or below the limit, seller at or above.
    function _within(bool takerBuys, uint32 price, uint32 limit) internal pure returns (bool) {
        return takerBuys ? price <= limit : price >= limit;
    }

    function _better(bool takerBuys, uint32 a, uint32 b) internal pure returns (bool) {
        return takerBuys ? a < b : a > b;
    }
}
