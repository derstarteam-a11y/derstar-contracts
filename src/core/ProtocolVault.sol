// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IQuoteVault} from "../interfaces/IQuoteVault.sol";
import {IClearing} from "../interfaces/IClearing.sol";
import {ISeriesRegistry} from "../interfaces/ISeriesRegistry.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {IIvFeed} from "../interfaces/IIvFeed.sol";
import {Series, Side, OptionType, SeriesState, UnderlyingConfig} from "../types/DerstarTypes.sol";
import {SeriesId} from "../libraries/SeriesId.sol";
import {BlackScholes} from "../libraries/BlackScholes.sol";

/// @title ProtocolVault
/// @notice The protocol's liquidity pool, in the spirit of Hyperliquid's HLP. It never posts
/// orders: the order book asks it for a price during matching. It sells options at
/// Black-Scholes fair value (spot from Chainlink, vol from IvFeed) plus a spread that grows with
/// open interest, and buys at fair value minus the spread: first back what it sold, then up to
/// `maxOIPerSeries` lots long, so spreads always find a buyer for their short leg.
///
/// One vault per collateral: BTC calls (WBTC), ETH calls (WETH), puts on both (USDC).
/// LP deposits and redemptions are queued and executed weekly, after an expiry settles, at the
/// vault's net asset value. Shares are worth USD (1 share = $1 at launch).
contract ProtocolVault is IQuoteVault, ERC20, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    uint32 internal constant MAX_TICK = type(uint16).max;
    uint256 internal constant BPS = 10_000;

    IClearing public immutable clearing;
    ISeriesRegistry public immutable registry;
    IOracleAdapter public immutable oracle;
    IIvFeed public immutable ivFeed;
    address public immutable asset; // collateral this vault writes against
    address public immutable usdc;
    OptionType public immutable optType;
    /// @notice For a call vault: the underlying whose price values `asset`. Unused for puts.
    uint8 public immutable assetUnderlying;

    mapping(uint8 => bool) public serves;
    uint8[] internal _underlyings;

    // Risk parameters
    uint16 public spreadBps = 500; // 5% each side of fair value
    uint16 public utilBps = 2_000; // ask premium at full OI: +20% (quadratic in utilisation)
    uint64 public maxOIPerSeries = 1_000; // lots
    uint64 public maxLotsPerTrade = 200;
    /// @notice Share of the collateral not committed to other expiries that one expiry may lock.
    uint16 public maxExpiryBps = 5_000;
    uint32 public minTimeToExpiry = 1 hours;
    uint32 public maxSpotAge = 2 hours;
    bool public paused;

    // Epochs
    struct Request {
        uint128 amount; // assets for deposits, shares for redemptions
        uint32 epoch;
    }

    struct EpochResult {
        uint128 depositAssets;
        uint128 depositShares;
        uint128 redeemRequested;
        uint128 redeemFilled;
        uint128 redeemAsset;
        uint128 redeemUsdc;
        uint256 navPerShare; // USD 1e18 per share
    }

    uint32 public epoch;
    uint64 public lastRolledExpiry;
    uint256 public pendingDeposits;
    uint256 public pendingRedeems;
    mapping(address => Request) public depositRequest;
    mapping(address => Request) public redeemRequest;
    mapping(uint32 => EpochResult) public epochs;
    /// @notice Index into registry.listExpiries(u) before which every expiry is collected.
    /// Keeps NAV and rolls proportional to open expiries, not to the whole history.
    mapping(uint8 => uint256) public scanFrom;

    event DepositRequested(address indexed user, uint256 assets, uint32 epoch);
    event RedeemRequested(address indexed user, uint256 shares, uint32 epoch);
    event RequestCancelled(address indexed user, uint256 assets, uint256 shares);
    event Claimed(address indexed user, uint256 shares, uint256 assetOut, uint256 usdcOut, uint256 sharesReturned);
    event EpochRolled(uint32 indexed epoch, uint64 expiry, uint256 nav, uint256 navPerShare);
    event RiskSet(
        uint16 spreadBps,
        uint16 utilBps,
        uint64 maxOIPerSeries,
        uint64 maxLotsPerTrade,
        uint32 minTte,
        uint16 maxExpiryBps
    );
    event Paused(bool paused);

    error InvalidConfig();
    error InvalidAmount();
    error NothingToCancel();
    error EpochNotReady(uint64 expiry);
    error StaleVol(uint256 seriesId);

    constructor(
        string memory name_,
        string memory symbol_,
        address admin,
        IClearing clearing_,
        ISeriesRegistry registry_,
        IOracleAdapter oracle_,
        IIvFeed ivFeed_,
        address asset_,
        OptionType optType_,
        uint8 assetUnderlying_
    ) ERC20(name_, symbol_) {
        if (admin == address(0) || asset_ == address(0)) revert InvalidConfig();
        clearing = clearing_;
        registry = registry_;
        oracle = oracle_;
        ivFeed = ivFeed_;
        asset = asset_;
        usdc = registry_.quoteToken();
        optType = optType_;
        assetUnderlying = assetUnderlying_;
        if ((optType_ == OptionType.Put) != (asset_ == usdc)) revert InvalidConfig();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);
        IERC20(asset_).forceApprove(address(clearing_), type(uint256).max);
    }

    // ================================================================ quoting

    function quote(uint256 seriesId, Side vaultSide, uint64 lots) external view returns (uint32, uint64) {
        if (paused || lots == 0) return (0, 0);
        Series memory s = SeriesId.decode(seriesId);
        if (s.optType != optType || !serves[s.underlying]) return (0, 0);
        if (block.timestamp + minTimeToExpiry > s.expiry) return (0, 0);
        if (!ivFeed.isFresh(s.underlying, s.expiry)) return (0, 0);
        (bool ok, uint256 spot) = _freshSpot(s.underlying);
        if (!ok) return (0, 0);

        uint256 fairUsdc = _fairUsdc(s, spot); // per contract, 6 decimals
        UnderlyingConfig memory cfg = registry.config(s.underlying);
        uint64 oi = clearing.shortOf(address(this), seriesId);
        if (vaultSide == Side.Sell) return _ask(seriesId, cfg, fairUsdc, oi, lots);
        uint256 held = clearing.token().balanceOf(address(this), seriesId);
        uint64 room = oi + (held < maxOIPerSeries ? maxOIPerSeries - uint64(held) : 0);
        return _bid(cfg, fairUsdc, room, lots);
    }

    function _ask(uint256 seriesId, UnderlyingConfig memory cfg, uint256 fairUsdc, uint64 oi, uint64 lots)
        internal
        view
        returns (uint32, uint64)
    {
        uint64 avail = _min(lots, maxLotsPerTrade);
        avail = _min(avail, maxOIPerSeries > oi ? maxOIPerSeries - oi : 0);
        uint256 byCollateral = _writable(seriesId);
        // forge-lint: disable-next-line(unsafe-typecast) -- below avail, a uint64
        if (byCollateral < avail) avail = uint64(byCollateral);
        if (avail == 0) return (0, 0);

        // Spread grows with utilisation after this trade: spread + utilBps * util^2
        uint256 util = uint256(oi + avail) * BPS / maxOIPerSeries;
        uint256 markup = BPS + spreadBps + uint256(utilBps) * util * util / (BPS * BPS);
        uint256 ticks = _ceilDiv(fairUsdc * markup, BPS * cfg.tickSize);
        if (ticks == 0) ticks = 1;
        if (ticks > MAX_TICK) return (0, 0);
        // forge-lint: disable-next-line(unsafe-typecast) -- bounded by MAX_TICK
        return (uint32(ticks), avail);
    }

    /// @dev Lots of `seriesId` the vault can still write. Concentration cap: one expiry may lock at
    /// most maxExpiryBps of the free collateral plus what is already locked in that expiry.
    function _writable(uint256 seriesId) internal view returns (uint256) {
        (, uint256 perLot) = registry.collateralPerLot(seriesId);
        uint256 free = clearing.freeBalance(address(this), asset);
        uint256 here = _lockedIn(seriesId);
        uint256 cap = (free + here) * maxExpiryBps / BPS;
        if (cap <= here) return 0;
        cap -= here;
        return (cap < free ? cap : free) / perLot;
    }

    /// @dev Collateral this vault has locked in the expiry of `seriesId`, in `asset`.
    function _lockedIn(uint256 seriesId) internal view returns (uint256 sum) {
        Series memory s = SeriesId.decode(seriesId);
        uint256[] memory ids = registry.listSeries(s.underlying, s.expiry);
        for (uint256 j; j < ids.length; ++j) {
            uint64 lots = clearing.shortOf(address(this), ids[j]);
            if (lots == 0) continue;
            (, uint256 perLot) = registry.collateralPerLot(ids[j]);
            sum += lots * perLot;
        }
    }

    function _bid(UnderlyingConfig memory cfg, uint256 fairUsdc, uint64 room, uint64 lots)
        internal
        view
        returns (uint32, uint64)
    {
        uint256 ticks = fairUsdc * (BPS - spreadBps) / (BPS * cfg.tickSize);
        if (ticks == 0 || ticks > MAX_TICK) return (0, 0);
        uint64 avail = _min(_min(lots, maxLotsPerTrade), room);
        // Pay premium plus the maker fee (at most 6.25% of premium) from free USDC.
        uint256 costPerLot = ticks * (cfg.tickSize / cfg.lotsPerContract) * 10_625 / BPS + 1;
        uint256 byUsdc = clearing.freeBalance(address(this), usdc) / costPerLot;
        // forge-lint: disable-next-line(unsafe-typecast) -- below avail, a uint64
        if (byUsdc < avail) avail = uint64(byUsdc);
        if (avail == 0) return (0, 0);
        // forge-lint: disable-next-line(unsafe-typecast) -- bounded by MAX_TICK
        return (uint32(ticks), avail);
    }

    /// @dev Black-Scholes fair value per contract in USDC (6 decimals).
    function _fairUsdc(Series memory s, uint256 spot) internal view returns (uint256) {
        uint256 tte = s.expiry > block.timestamp ? s.expiry - block.timestamp : 0;
        uint256 vol = tte == 0 ? 0 : ivFeed.iv(s.underlying, s.expiry, s.strike, spot);
        (uint256 fair1e8,) = BlackScholes.price(spot, s.strike, tte, vol, s.optType == OptionType.Call);
        return fair1e8 / 100;
    }

    function _freshSpot(uint8 u) internal view returns (bool, uint256) {
        try oracle.spot(u) returns (uint256 p, uint256 at) {
            return (at + maxSpotAge >= block.timestamp, p);
        } catch {
            return (false, 0);
        }
    }

    // ================================================================ LP requests

    function requestDeposit(uint256 assets) external nonReentrant {
        if (assets == 0) revert InvalidAmount();
        _claim(msg.sender);
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        Request storage r = depositRequest[msg.sender];
        r.amount += SafeCast.toUint128(assets);
        r.epoch = epoch;
        pendingDeposits += assets;
        emit DepositRequested(msg.sender, assets, epoch);
    }

    function requestRedeem(uint256 shares) external nonReentrant {
        if (shares == 0) revert InvalidAmount();
        _claim(msg.sender);
        _transfer(msg.sender, address(this), shares);
        Request storage r = redeemRequest[msg.sender];
        r.amount += SafeCast.toUint128(shares);
        r.epoch = epoch;
        pendingRedeems += shares;
        emit RedeemRequested(msg.sender, shares, epoch);
    }

    /// @notice Withdraws requests of the current epoch before it is rolled.
    function cancelRequest() external nonReentrant {
        Request memory d = depositRequest[msg.sender];
        Request memory r = redeemRequest[msg.sender];
        uint256 assets = d.epoch == epoch ? d.amount : 0;
        uint256 shares = r.epoch == epoch ? r.amount : 0;
        if (assets == 0 && shares == 0) revert NothingToCancel();
        if (assets > 0) {
            delete depositRequest[msg.sender];
            pendingDeposits -= assets;
            IERC20(asset).safeTransfer(msg.sender, assets);
        }
        if (shares > 0) {
            delete redeemRequest[msg.sender];
            pendingRedeems -= shares;
            _transfer(address(this), msg.sender, shares);
        }
        emit RequestCancelled(msg.sender, assets, shares);
    }

    function claim() external nonReentrant {
        _claim(msg.sender);
    }

    function _claim(address user) internal {
        uint256 sharesOut;
        uint256 assetOut;
        uint256 usdcOut;
        uint256 sharesBack;

        Request memory d = depositRequest[user];
        if (d.amount > 0 && d.epoch < epoch) {
            EpochResult memory e = epochs[d.epoch];
            sharesOut = uint256(d.amount) * e.depositShares / e.depositAssets;
            delete depositRequest[user];
        }
        Request memory r = redeemRequest[user];
        if (r.amount > 0 && r.epoch < epoch) {
            EpochResult memory e = epochs[r.epoch];
            uint256 filled = uint256(r.amount) * e.redeemFilled / e.redeemRequested;
            assetOut = uint256(r.amount) * e.redeemAsset / e.redeemRequested;
            usdcOut = uint256(r.amount) * e.redeemUsdc / e.redeemRequested;
            sharesBack = r.amount - filled; // not filled this epoch: returned, can be requested again
            delete redeemRequest[user];
        }
        if (sharesOut + sharesBack > 0) _transfer(address(this), user, sharesOut + sharesBack);
        if (assetOut > 0) IERC20(asset).safeTransfer(user, assetOut);
        if (usdcOut > 0) IERC20(usdc).safeTransfer(user, usdcOut);
        if (sharesOut + assetOut + usdcOut + sharesBack > 0) {
            emit Claimed(user, sharesOut, assetOut, usdcOut, sharesBack);
        }
    }

    // ================================================================ epochs

    /// @notice Anyone can roll once a weekly expiry has settled: collects the vault's leftover
    /// collateral from every expiry up to it, values the vault, then executes the queued
    /// redemptions and deposits at that value. An empty vault (no shares) can roll at any time,
    /// which is how it takes its first deposits; pass 0 then.
    function rollEpoch(uint64 settledExpiry) external nonReentrant {
        if (totalSupply() > 0) {
            if (settledExpiry > block.timestamp || settledExpiry <= lastRolledExpiry) {
                revert EpochNotReady(settledExpiry);
            }
            bool listed;
            for (uint256 i; i < _underlyings.length; ++i) {
                if (registry.isListed(_underlyings[i], settledExpiry)) listed = true;
                _collectUpTo(_underlyings[i], settledExpiry);
            }
            if (!listed) revert EpochNotReady(settledExpiry);
            lastRolledExpiry = settledExpiry;
        }

        uint256 assetPx = _assetPrice();
        uint256 nav = navUsd(); // USD 1e18
        uint256 supply = totalSupply();
        uint256 navPerShare = supply == 0 ? 1e18 : nav * 1e18 / supply;
        // Full collateral keeps NAV positive while shares exist; zero would mean a broken oracle.
        if (navPerShare == 0) revert InvalidConfig();

        EpochResult storage e = epochs[epoch];
        e.navPerShare = navPerShare;
        _processRedeems(e, navPerShare, assetPx);
        _processDeposits(e, navPerShare, assetPx);

        emit EpochRolled(epoch, settledExpiry, nav, navPerShare);
        ++epoch;
    }

    /// @dev Claims leftover collateral of every expiry up to `upTo` in the scan window, then moves
    /// the cursor past the collected prefix. Each such series must be settled already.
    function _collectUpTo(uint8 u, uint64 upTo) internal {
        uint64[] memory expiries = registry.listExpiries(u);
        uint256 cursor = scanFrom[u];
        bool prefix = true;
        for (uint256 x = cursor; x < expiries.length; ++x) {
            if (expiries[x] > upTo) {
                prefix = false;
                continue;
            }
            uint256[] memory ids = registry.listSeries(u, expiries[x]);
            for (uint256 j; j < ids.length; ++j) {
                uint256 held = clearing.token().balanceOf(address(this), ids[j]);
                if (clearing.shortOf(address(this), ids[j]) == 0 && held == 0) continue;
                if (registry.stateOf(ids[j]) != SeriesState.Settled) revert EpochNotReady(expiries[x]);
                clearing.claimShortFor(address(this), ids[j]);
                if (held > 0) {
                    // Longs pay out to this contract's wallet: put the payoff back to work in Clearing.
                    uint256 got = held * clearing.payoffPerLot(ids[j]);
                    clearing.redeem(ids[j], SafeCast.toUint64(held));
                    if (got > 0) clearing.deposit(asset, got);
                }
            }
            if (prefix) cursor = x + 1;
        }
        scanFrom[u] = cursor;
    }

    function _processRedeems(EpochResult storage e, uint256 navPerShare, uint256 assetPx) internal {
        uint256 shares = pendingRedeems;
        if (shares == 0) return;
        uint256 freeAsset = clearing.freeBalance(address(this), asset);
        uint256 freeUsdc = asset == usdc ? 0 : clearing.freeBalance(address(this), usdc);
        uint256 freeValue = _usd(freeAsset, assetPx) + freeUsdc * 1e12;
        uint256 owed = shares * navPerShare / 1e18;
        // Only free (unlocked) funds can leave; the rest waits for later expiries.
        uint256 paidValue = owed < freeValue ? owed : freeValue;
        uint256 filled = owed == 0 ? shares : shares * paidValue / owed;
        uint256 assetOut = freeValue == 0 ? 0 : freeAsset * paidValue / freeValue;
        uint256 usdcOut = freeValue == 0 ? 0 : freeUsdc * paidValue / freeValue;

        if (assetOut > 0) clearing.withdraw(asset, assetOut);
        if (usdcOut > 0) clearing.withdraw(usdc, usdcOut);
        _burn(address(this), filled);
        (e.redeemRequested, e.redeemFilled) = (SafeCast.toUint128(shares), SafeCast.toUint128(filled));
        (e.redeemAsset, e.redeemUsdc) = (SafeCast.toUint128(assetOut), SafeCast.toUint128(usdcOut));
        pendingRedeems = 0;
    }

    function _processDeposits(EpochResult storage e, uint256 navPerShare, uint256 assetPx) internal {
        uint256 assets = pendingDeposits;
        if (assets == 0) return;
        uint256 shares = _usd(assets, assetPx) * 1e18 / navPerShare;
        clearing.deposit(asset, assets);
        _mint(address(this), shares);
        (e.depositAssets, e.depositShares) = (SafeCast.toUint128(assets), SafeCast.toUint128(shares));
        pendingDeposits = 0;
    }

    /// @notice Net asset value in USD (18 decimals): free funds and locked collateral in Clearing,
    /// plus the Black-Scholes value of options the vault holds, minus that of options it is short.
    function navUsd() public view returns (uint256) {
        uint256 assetPx = _assetPrice();
        int256 nav = int256(_usd(clearing.freeBalance(address(this), asset), assetPx));
        if (asset != usdc) nav += int256(clearing.freeBalance(address(this), usdc) * 1e12);

        for (uint256 i; i < _underlyings.length; ++i) {
            uint8 u = _underlyings[i];
            (, uint256 spot) = _freshSpot(u);
            uint64[] memory expiries = registry.listExpiries(u);
            for (uint256 x = scanFrom[u]; x < expiries.length; ++x) {
                nav += _expiryValue(u, expiries[x], spot, assetPx);
            }
        }
        // forge-lint: disable-next-line(unsafe-typecast) -- clamped at zero
        return nav > 0 ? uint256(nav) : 0;
    }

    /// @dev Locked collateral minus option value for one expiry, USD 1e18.
    function _expiryValue(uint8 u, uint64 expiry, uint256 spot, uint256 assetPx) internal view returns (int256 v) {
        uint256[] memory ids = registry.listSeries(u, expiry);
        uint256 lpc = registry.config(u).lotsPerContract;
        for (uint256 j; j < ids.length; ++j) {
            uint64 lots = clearing.shortOf(address(this), ids[j]);
            uint256 held = clearing.token().balanceOf(address(this), ids[j]);
            if (lots == 0 && held == 0) continue;
            Series memory s = SeriesId.decode(ids[j]);
            (, uint256 perLot) = registry.collateralPerLot(ids[j]);
            uint256 locked = _usd(lots * perLot, assetPx);
            // Shorts owe this per lot, longs are worth it: one value, signed by the side.
            uint256 value;
            if (registry.stateOf(ids[j]) == SeriesState.Settled) {
                value = _usd(clearing.payoffPerLot(ids[j]), assetPx);
            } else {
                if (expiry > block.timestamp && !ivFeed.isFresh(u, expiry)) revert StaleVol(ids[j]);
                value = _fairUsdc(s, spot) * 1e12 / lpc;
            }
            v += SafeCast.toInt256(locked + held * value) - SafeCast.toInt256(lots * value);
        }
    }

    /// @dev USD price of one whole `asset` unit, 8 decimals.
    function _assetPrice() internal view returns (uint256) {
        if (asset == usdc) return 1e8;
        (uint256 p,) = oracle.spot(assetUnderlying);
        return p;
    }

    /// @dev Token amount to USD 1e18.
    function _usd(uint256 amount, uint256 px1e8) internal view returns (uint256) {
        if (asset == usdc) return amount * 1e12;
        uint8 dec = registry.config(assetUnderlying).collateralDecimals;
        return amount * px1e8 * 1e10 / 10 ** dec;
    }

    // ================================================================ admin

    /// @notice Adds USDC to the vault's Clearing balance as a gift to its LPs. A call vault earns
    /// USDC only by selling; this lets it bid (buy options) from the start.
    function donateUsdc(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(usdc).forceApprove(address(clearing), amount);
        clearing.deposit(usdc, amount);
    }

    function setServes(uint8 underlying, bool on) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (on && !serves[underlying]) _underlyings.push(underlying);
        if (!on && serves[underlying]) {
            for (uint256 i; i < _underlyings.length; ++i) {
                if (_underlyings[i] == underlying) {
                    _underlyings[i] = _underlyings[_underlyings.length - 1];
                    _underlyings.pop();
                    break;
                }
            }
        }
        serves[underlying] = on;
    }

    function setRisk(
        uint16 spread,
        uint16 util,
        uint64 maxOI,
        uint64 maxPerTrade,
        uint32 minTte,
        uint32 spotAge,
        uint16 expiryBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (spread >= BPS || maxOI == 0 || maxPerTrade == 0 || spotAge == 0 || expiryBps == 0 || expiryBps > BPS) {
            revert InvalidConfig();
        }
        (spreadBps, utilBps, maxOIPerSeries, maxLotsPerTrade, minTimeToExpiry, maxSpotAge, maxExpiryBps) =
        (spread, util, maxOI, maxPerTrade, minTte, spotAge, expiryBps);
        emit RiskSet(spread, util, maxOI, maxPerTrade, minTte, expiryBps);
    }

    /// @notice Stops new sales and buybacks. Deposits, redemptions and settlement keep working.
    function pause(bool p) external onlyRole(GUARDIAN_ROLE) {
        paused = p;
        emit Paused(p);
    }

    function underlyings() external view returns (uint8[] memory) {
        return _underlyings;
    }

    function _min(uint64 a, uint64 b) internal pure returns (uint64) {
        return a < b ? a : b;
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
