// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {ISeriesRegistry} from "../interfaces/ISeriesRegistry.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IApi3ReaderProxy} from "../interfaces/IApi3ReaderProxy.sol";

/// @title OracleAdapter
/// @notice Spot prices and expiry settlement prices from Chainlink.
///
/// Chainlink has no TWAP, so we compute one from the feed's own round history: starting at the
/// round that was live at expiry, walk back to the start of the window and weight each price by
/// how long it was live. Anyone can call it; the result does not depend on who calls or when.
///
/// Price ladder: Chainlink TWAP; if Chainlink stopped updating, the average of API3 samples taken
/// during the window; if the sequencer was down, the first Chainlink price after recovery; and as
/// a last resort a governance price through the Timelock.
contract OracleAdapter is IOracleAdapter, AccessControl {
    uint256 public constant MAX_ROUNDS = 256;

    ISeriesRegistry public immutable registry;
    /// @notice Chainlink L2 Sequencer Uptime feed (answer 0 = up). Zero address disables checks.
    AggregatorV3Interface public immutable sequencerFeed;

    uint32 public twapWindow = 30 minutes;
    uint32 public maxSpotAge = 26 hours; // BTC/USD heartbeat on Arbitrum is 24 h
    uint32 public sequencerGrace = 1 hours;
    uint32 public governanceDelay = 72 hours;
    uint32 public backupDelay = 1 hours; // after expiry, before the backup may be used
    uint32 public backupMinGap = 1 minutes; // between two API3 samples
    uint16 public backupMinSamples = 5;

    /// @notice API3 dAPI proxy per underlying (BTC/USD, ETH/USD). Zero: no backup.
    mapping(uint8 => IApi3ReaderProxy) public backupFeed;

    struct Samples {
        uint192 sum; // 1e8 prices
        uint32 count;
        uint32 lastAt;
    }

    mapping(uint8 => mapping(uint64 => Samples)) public backupSamples;

    struct Final {
        uint128 price;
        PriceSource source;
    }

    mapping(uint8 => mapping(uint64 => Final)) internal _final;

    constructor(address admin, ISeriesRegistry registry_, AggregatorV3Interface sequencerFeed_) {
        if (admin == address(0)) revert InvalidConfig();
        registry = registry_;
        sequencerFeed = sequencerFeed_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ================================================================ spot

    function spot(uint8 underlying) external view returns (uint256 price1e8, uint256 updatedAt) {
        _requireSequencerUp();
        AggregatorV3Interface feed = _feed(underlying);
        (, int256 answer,, uint256 at,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (at + maxSpotAge < block.timestamp) revert StalePrice(at);
        // forge-lint: disable-next-line(unsafe-typecast) -- answer > 0 checked above
        return (_to1e8(feed, uint256(answer)), at);
    }

    // ================================================================ settlement

    function finalize(uint8 underlying, uint64 expiry, uint80 roundHint) external returns (uint256 price1e8) {
        _requireOpen(underlying, expiry);
        uint256 start = uint256(expiry) - twapWindow;
        if (address(sequencerFeed) != address(0)) {
            (, int256 status, uint256 since,,) = sequencerFeed.latestRoundData();
            // Any status change after the window opened means the window may be missing rounds.
            if (status != 0 || since > start) revert SequencerIncident();
        }

        AggregatorV3Interface feed = _feed(underlying);
        (uint256 price, uint256 at) = _round(feed, roundHint);
        if (at == 0 || at > expiry) revert BadRoundHint(roundHint);
        (bool hasNext, uint256 nextAt) = _nextRound(feed, roundHint);
        if (hasNext && nextAt <= expiry) revert BadRoundHint(roundHint);
        if (!hasNext) {
            // The hint must be the feed's latest round, otherwise a later phase may hold the answer.
            (uint80 latest,,,,) = feed.latestRoundData();
            if (latest != roundHint) revert BadRoundHint(roundHint);
        }

        uint256 weighted;
        uint256 end = expiry;
        uint80 id = roundHint;
        for (uint256 i;; ++i) {
            if (i == MAX_ROUNDS) revert TooManyRounds();
            if (price == 0) revert InvalidPrice();
            uint256 from = at > start ? at : start;
            weighted += price * (end - from);
            if (at <= start) break;
            end = at;
            // First round of a phase: it stands in for the rest of the window.
            if (_aggregatorRound(id) == 1) {
                weighted += price * (end - start);
                break;
            }
            --id;
            (price, at) = _round(feed, id);
        }
        price1e8 = _to1e8(feed, weighted / twapWindow);
        _set(underlying, expiry, price1e8, PriceSource.Twap);
    }

    function finalizeAfterRecovery(uint8 underlying, uint64 expiry, uint80 roundId)
        external
        returns (uint256 price1e8)
    {
        _requireOpen(underlying, expiry);
        if (address(sequencerFeed) == address(0)) revert NoSequencerIncident();
        (, int256 status, uint256 since,,) = sequencerFeed.latestRoundData();
        if (status != 0) revert SequencerDown();
        if (since <= uint256(expiry) - twapWindow) revert NoSequencerIncident();

        uint256 threshold = since + sequencerGrace;
        if (threshold < expiry) threshold = expiry;
        AggregatorV3Interface feed = _feed(underlying);
        (uint256 price, uint256 at) = _round(feed, roundId);
        if (at < threshold || price == 0) revert BadRoundHint(roundId);
        // Must be the first round at or after the threshold.
        if (_aggregatorRound(roundId) > 1) {
            (, uint256 prevAt) = _round(feed, roundId - 1);
            if (prevAt >= threshold) revert BadRoundHint(roundId);
        }
        price1e8 = _to1e8(feed, price);
        _set(underlying, expiry, price1e8, PriceSource.PostRecovery);
    }

    // ================================================================ backup (API3)

    function recordBackup(uint8 underlying, uint64 expiry) external {
        IApi3ReaderProxy proxy = backupFeed[underlying];
        if (address(proxy) == address(0)) revert NoBackupFeed(underlying);
        if (block.timestamp < uint256(expiry) - twapWindow || block.timestamp > expiry) revert OutsideWindow();
        _requireSequencerUp();
        Samples storage s = backupSamples[underlying][expiry];
        if (s.count > 0 && block.timestamp < uint256(s.lastAt) + backupMinGap) revert TooSoon();
        (int224 value, uint32 at) = proxy.read();
        if (value <= 0) revert InvalidPrice();
        if (uint256(at) + maxSpotAge < block.timestamp) revert StalePrice(at);
        // forge-lint: disable-next-line(unsafe-typecast) -- value > 0 checked above
        uint256 price1e8 = uint256(int256(value)) / 1e10;
        s.sum += uint192(price1e8);
        s.count += 1;
        s.lastAt = uint32(block.timestamp);
        emit BackupSampled(underlying, expiry, price1e8, s.count);
    }

    function finalizeBackup(uint8 underlying, uint64 expiry) external returns (uint256 price1e8) {
        _requireOpen(underlying, expiry);
        if (block.timestamp < uint256(expiry) + backupDelay) revert TooSoon();
        uint256 start = uint256(expiry) - twapWindow;
        if (address(sequencerFeed) != address(0)) {
            (, int256 status, uint256 since,,) = sequencerFeed.latestRoundData();
            if (status != 0 || since > start) revert SequencerIncident();
        }
        // Chainlink counts as failed when it has not posted a single round since the window opened.
        try _feed(underlying).latestRoundData() returns (uint80, int256 answer, uint256, uint256 at, uint80) {
            if (answer > 0 && at >= start) revert ChainlinkHealthy();
        } catch {}
        Samples memory s = backupSamples[underlying][expiry];
        if (s.count < backupMinSamples) revert NotEnoughSamples(s.count);
        price1e8 = s.sum / s.count;
        _set(underlying, expiry, price1e8, PriceSource.Backup);
    }

    /// @dev Called through the 48 h Timelock, so the price is public two days before it applies.
    function setGovernancePrice(uint8 underlying, uint64 expiry, uint256 price1e8)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _requireOpen(underlying, expiry);
        uint256 allowedAt = uint256(expiry) + governanceDelay;
        if (block.timestamp < allowedAt) revert TooEarlyForGovernance(allowedAt);
        if (price1e8 == 0) revert InvalidPrice();
        _set(underlying, expiry, price1e8, PriceSource.Governance);
    }

    function settlementPrice(uint8 underlying, uint64 expiry)
        external
        view
        returns (uint256 price1e8, bool isFinal, PriceSource source)
    {
        Final memory f = _final[underlying][expiry];
        return (f.price, f.source != PriceSource.None, f.source);
    }

    function setParams(uint32 window, uint32 spotAge, uint32 grace, uint32 govDelay)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (window == 0 || window > 2 hours || spotAge == 0 || govDelay < 24 hours) revert InvalidConfig();
        (twapWindow, maxSpotAge, sequencerGrace, governanceDelay) = (window, spotAge, grace, govDelay);
        emit ParamsSet(window, spotAge, grace, govDelay);
    }

    function setBackupFeed(uint8 underlying, IApi3ReaderProxy proxy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        backupFeed[underlying] = proxy;
        emit BackupFeedSet(underlying, address(proxy));
    }

    function setBackupParams(uint32 delay, uint32 minGap, uint16 minSamples) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (minSamples == 0 || minGap == 0) revert InvalidConfig();
        (backupDelay, backupMinGap, backupMinSamples) = (delay, minGap, minSamples);
        emit BackupParamsSet(delay, minGap, minSamples);
    }

    // ================================================================ internals

    function _requireOpen(uint8 underlying, uint64 expiry) internal view {
        if (block.timestamp < expiry) revert NotExpired(expiry);
        if (_final[underlying][expiry].source != PriceSource.None) revert AlreadyFinal(underlying, expiry);
    }

    function _set(uint8 underlying, uint64 expiry, uint256 price1e8, PriceSource source) internal {
        // forge-lint: disable-next-line(unsafe-typecast) -- USD prices with 8 decimals fit easily
        _final[underlying][expiry] = Final(uint128(price1e8), source);
        emit SettlementPriceSet(underlying, expiry, price1e8, source);
    }

    function _requireSequencerUp() internal view {
        if (address(sequencerFeed) == address(0)) return;
        (, int256 status, uint256 since,,) = sequencerFeed.latestRoundData();
        if (status != 0 || since + sequencerGrace > block.timestamp) revert SequencerDown();
    }

    function _feed(uint8 underlying) internal view returns (AggregatorV3Interface) {
        return AggregatorV3Interface(registry.config(underlying).feed);
    }

    /// @return price 0 when the round is missing or its answer is not positive
    function _round(AggregatorV3Interface feed, uint80 id) internal view returns (uint256 price, uint256 at) {
        try feed.getRoundData(id) returns (uint80, int256 a, uint256, uint256 t, uint80) {
            // forge-lint: disable-next-line(unsafe-typecast) -- only positive answers are cast
            return (a > 0 ? uint256(a) : 0, t);
        } catch {
            return (0, 0);
        }
    }

    /// @dev Chainlink round id = (phaseId << 64) | aggregatorRoundId.
    function _aggregatorRound(uint80 id) internal pure returns (uint256) {
        return uint256(id) & type(uint64).max;
    }

    function _nextRound(AggregatorV3Interface feed, uint80 id) internal view returns (bool, uint256) {
        (, uint256 at) = _round(feed, id + 1);
        return (at != 0, at);
    }

    function _to1e8(AggregatorV3Interface feed, uint256 a) internal view returns (uint256) {
        uint8 d = feed.decimals();
        if (d == 8) return a;
        return d > 8 ? a / 10 ** (d - 8) : a * 10 ** (8 - d);
    }
}
