// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ISeriesRegistry} from "../interfaces/ISeriesRegistry.sol";
import {Series, SeriesState, OptionType, UnderlyingConfig} from "../types/DerstarTypes.sol";
import {SeriesId} from "../libraries/SeriesId.sol";
import {ExpiryCalendar} from "../libraries/ExpiryCalendar.sol";

/// @title SeriesRegistry
/// @notice Lists underlyings, expiries and strikes. A keeper lists new expiries, but the
/// calendar (daily 08:00 UTC), strike grid and listing horizon are enforced here, so the
/// keeper cannot list anything outside the rules.
contract SeriesRegistry is ISeriesRegistry, AccessControl {
    bytes32 public constant SERIES_ROLE = keccak256("SERIES_ROLE");

    uint32 public constant MAX_TRADING_CUTOFF = 1 days;
    uint256 internal constant USDC_UNIT = 1e6;

    /// @notice Quote and premium token (USDC, 6 decimals). Also backs puts.
    address public immutable quoteToken;

    /// @notice 0 on mainnet. On a testnet, a non-zero value replaces the daily calendar:
    /// any expiry that is a multiple of this many seconds is valid (fast demo cycles).
    uint32 public immutable demoInterval;

    /// @notice How far ahead an expiry may be listed. Two monthlies need ~9 weeks.
    uint32 public immutable maxHorizon;

    address public clearing;
    uint32 public tradingCutoff = 30 minutes;

    mapping(uint8 => UnderlyingConfig) internal _configs;
    mapping(uint8 => string) internal _symbols;
    mapping(uint8 => bool) public hasSeries;
    /// @notice Tokens Clearing accepts as collateral: every underlying's collateral (set once, never removed).
    mapping(address => bool) public isCollateral;

    mapping(uint256 => SeriesState) internal _state;
    mapping(uint8 => uint64[]) internal _expiries;
    mapping(uint8 => mapping(uint64 => bool)) public isListed;
    mapping(uint8 => mapping(uint64 => uint256[])) internal _seriesOf;

    constructor(address admin, address quoteToken_, uint32 demoInterval_, uint32 maxHorizon_) {
        if (admin == address(0) || quoteToken_ == address(0) || maxHorizon_ == 0) revert InvalidConfig();
        quoteToken = quoteToken_;
        demoInterval = demoInterval_;
        maxHorizon = maxHorizon_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ---------------------------------------------------------------- keeper

    function createExpiry(uint8 underlying, uint64 expiry, uint64[] calldata strikes) external onlyRole(SERIES_ROLE) {
        UnderlyingConfig storage cfg = _configs[underlying];
        if (!cfg.enabled) revert UnderlyingDisabled(underlying);
        if (!_isValidNewExpiry(expiry)) revert InvalidExpiry(expiry);

        if (!isListed[underlying][expiry]) {
            isListed[underlying][expiry] = true;
            _expiries[underlying].push(expiry);
            emit ExpiryListed(underlying, expiry, demoInterval == 0 && ExpiryCalendar.isMonthly(expiry));
        }
        _addStrikes(underlying, expiry, strikes, cfg);
    }

    function addStrikes(uint8 underlying, uint64 expiry, uint64[] calldata strikes) external onlyRole(SERIES_ROLE) {
        UnderlyingConfig storage cfg = _configs[underlying];
        if (!cfg.enabled) revert UnderlyingDisabled(underlying);
        if (!isListed[underlying][expiry]) revert ExpiryNotListed(expiry);
        if (block.timestamp + tradingCutoff >= expiry) revert InvalidExpiry(expiry);
        _addStrikes(underlying, expiry, strikes, cfg);
    }

    /// @dev Idempotent: strikes that already exist are skipped, so a keeper can retry safely.
    function _addStrikes(uint8 underlying, uint64 expiry, uint64[] calldata strikes, UnderlyingConfig storage cfg)
        internal
    {
        uint256[] storage ids = _seriesOf[underlying][expiry];
        for (uint256 i; i < strikes.length; ++i) {
            uint64 k = strikes[i];
            if (k == 0 || k % cfg.strikeStep != 0) revert InvalidStrike(k);

            uint256 callId = SeriesId.encode(Series(underlying, OptionType.Call, expiry, k));
            if (_state[callId] != SeriesState.None) continue;
            uint256 putId = SeriesId.encode(Series(underlying, OptionType.Put, expiry, k));

            _state[callId] = SeriesState.Active;
            _state[putId] = SeriesState.Active;
            ids.push(callId);
            ids.push(putId);
            emit SeriesCreated(callId, underlying, uint8(OptionType.Call), expiry, k);
            emit SeriesCreated(putId, underlying, uint8(OptionType.Put), expiry, k);
        }
        uint256 strikeCount = ids.length / 2;
        if (strikeCount > cfg.maxStrikesPerExpiry) revert TooManyStrikes(strikeCount, cfg.maxStrikesPerExpiry);
        if (strikes.length > 0) hasSeries[underlying] = true;
    }

    function _isValidNewExpiry(uint64 expiry) internal view returns (bool) {
        if (expiry <= block.timestamp + tradingCutoff) return false;
        if (expiry > block.timestamp + maxHorizon) return false;
        if (demoInterval != 0) return expiry % demoInterval == 0;
        return ExpiryCalendar.isDaily0800(expiry);
    }

    // ---------------------------------------------------------------- clearing

    function markSettled(uint256 seriesId) external {
        if (msg.sender != clearing) revert NotClearing();
        if (_state[seriesId] != SeriesState.Active) revert SeriesNotActive(seriesId);
        _state[seriesId] = SeriesState.Settled;
        emit SeriesSettled(seriesId);
    }

    // ---------------------------------------------------------------- admin

    /// @notice Sets an underlying. Once it has series, only feed, grid cap and the enabled
    /// flag can change: lot size, tick, step and collateral define existing positions.
    function setUnderlying(uint8 underlying, string calldata symbol, UnderlyingConfig calldata cfg)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _validate(cfg);
        if (hasSeries[underlying]) {
            UnderlyingConfig storage old = _configs[underlying];
            if (
                old.collateral != cfg.collateral || old.collateralDecimals != cfg.collateralDecimals
                    || old.lotsPerContract != cfg.lotsPerContract || old.tickSize != cfg.tickSize
                    || old.strikeStep != cfg.strikeStep
                    || keccak256(bytes(_symbols[underlying])) != keccak256(bytes(symbol))
            ) revert ConfigLocked(underlying);
        }
        _configs[underlying] = cfg;
        _symbols[underlying] = symbol;
        isCollateral[cfg.collateral] = true;
        emit UnderlyingSet(underlying, symbol, cfg);
    }

    function _validate(UnderlyingConfig calldata cfg) internal pure {
        if (cfg.collateral == address(0) || cfg.feed == address(0)) revert InvalidConfig();
        if (cfg.lotsPerContract == 0 || cfg.tickSize == 0 || cfg.strikeStep == 0) revert InvalidConfig();
        if (cfg.collateralDecimals > 30 || cfg.maxStrikesPerExpiry == 0) revert InvalidConfig();
        // Every per-lot amount must be exact, so positions never carry rounding dust.
        if ((10 ** uint256(cfg.collateralDecimals)) % cfg.lotsPerContract != 0) revert InvalidConfig();
        if (cfg.tickSize % cfg.lotsPerContract != 0) revert InvalidConfig();
        if ((uint256(cfg.strikeStep) * USDC_UNIT) % cfg.lotsPerContract != 0) revert InvalidConfig();
    }

    function setTradingCutoff(uint32 cutoff) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cutoff > MAX_TRADING_CUTOFF) revert InvalidConfig();
        tradingCutoff = cutoff;
        emit TradingCutoffSet(cutoff);
    }

    /// @notice One-time wiring: Clearing is deployed after the registry.
    function setClearing(address clearing_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (clearing != address(0)) revert ClearingAlreadySet();
        if (clearing_ == address(0)) revert InvalidConfig();
        clearing = clearing_;
        emit ClearingSet(clearing_);
    }

    // ---------------------------------------------------------------- views

    function getSeries(uint256 seriesId) external view returns (Series memory series, SeriesState state) {
        state = _state[seriesId];
        if (state != SeriesState.None) series = SeriesId.decode(seriesId);
    }

    function stateOf(uint256 seriesId) external view returns (SeriesState) {
        return _state[seriesId];
    }

    function isTradable(uint256 seriesId) external view returns (bool) {
        if (_state[seriesId] != SeriesState.Active) return false;
        if (!_configs[SeriesId.underlying(seriesId)].enabled) return false;
        return block.timestamp + tradingCutoff < SeriesId.expiry(seriesId);
    }

    function config(uint8 underlying) external view returns (UnderlyingConfig memory) {
        return _configs[underlying];
    }

    function symbolOf(uint8 underlying) external view returns (string memory) {
        return _symbols[underlying];
    }

    function listExpiries(uint8 underlying) external view returns (uint64[] memory) {
        return _expiries[underlying];
    }

    function activeExpiries(uint8 underlying) external view returns (uint64[] memory out) {
        uint64[] storage all = _expiries[underlying];
        uint256 n;
        for (uint256 i; i < all.length; ++i) {
            if (all[i] > block.timestamp) ++n;
        }
        out = new uint64[](n);
        n = 0;
        for (uint256 i; i < all.length; ++i) {
            if (all[i] > block.timestamp) out[n++] = all[i];
        }
    }

    function listSeries(uint8 underlying, uint64 expiry) external view returns (uint256[] memory) {
        return _seriesOf[underlying][expiry];
    }

    /// @notice Collateral that backs one short lot: underlying for calls, strike in USDC for puts.
    function collateralPerLot(uint256 seriesId) external view returns (address token, uint256 amount) {
        if (_state[seriesId] == SeriesState.None) revert SeriesNotActive(seriesId);
        Series memory s = SeriesId.decode(seriesId);
        UnderlyingConfig storage cfg = _configs[s.underlying];
        if (s.optType == OptionType.Call) {
            return (cfg.collateral, 10 ** uint256(cfg.collateralDecimals) / cfg.lotsPerContract);
        }
        return (quoteToken, uint256(s.strike) * USDC_UNIT / cfg.lotsPerContract);
    }

    /// @notice USDC premium for `lots` at `priceTicks` per contract. Exact by construction.
    function premiumForTicks(uint256 seriesId, uint32 priceTicks, uint64 lots) external view returns (uint256) {
        UnderlyingConfig storage cfg = _configs[SeriesId.underlying(seriesId)];
        return uint256(priceTicks) * (cfg.tickSize / cfg.lotsPerContract) * lots;
    }
}
