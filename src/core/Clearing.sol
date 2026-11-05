// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IClearing} from "../interfaces/IClearing.sol";
import {ISeriesRegistry} from "../interfaces/ISeriesRegistry.sol";
import {IOptionToken} from "../interfaces/IOptionToken.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {Side, Fill, UnderlyingConfig, Series, SeriesState, OptionType} from "../types/DerstarTypes.sol";
import {SeriesId} from "../libraries/SeriesId.sol";

/// @title Clearing
/// @notice Holds every token of the protocol. The order book only tells Clearing who traded
/// with whom; Clearing moves premiums, fees, collateral and option tokens.
///
/// Positions: a long is an OptionToken balance, a short is `shortOf` with its collateral locked
/// here. On every fill the seller delivers lots from option tokens it holds first (closing a
/// long) and writes the rest against collateral; the buyer covers its own short first and keeps
/// the rest as tokens. So `token.totalSupply(s) == totalShort[s]` holds until pledged tokens
/// are cashed in at settlement. Vaults may hold longs too: their bids carry their own limits.
contract Clearing is IClearing, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint32 public constant MAX_NOTIONAL_FEE_PPM = 2_000; // 0.2%
    uint32 public constant MAX_PREMIUM_CAP_PPM = 250_000; // 25%
    /// @notice Settlement fee reserve per contract, in ppm of the strike: 0.03% of twice the strike.
    /// Every long lot carries this reserve; the fee at expiry is capped by it.
    uint32 public constant SETTLEMENT_RESERVE_PPM = 600;
    uint32 public constant MAX_SETTLEMENT_FEE_PPM = 300; // 0.03%

    ISeriesRegistry public immutable registry;
    IOptionToken public immutable token;
    IOracleAdapter public immutable oracle;
    address public immutable usdc;

    /// @notice Set once. The book tells Clearing whose funds to move, so it must never change.
    address public orderBook;
    address public feeRecipient;
    uint32 public notionalFeePpm = 300; // taker: 0.03% of notional
    uint32 public makerFeePpm = 150; // maker: 0.015% of notional
    uint32 public premiumCapPpm = 125_000; // either side: at most 12.5% of premium
    uint32 public settlementFeePpm = 150; // each side at expiry: 0.015% of notional at the settlement price
    bool public tradingPaused;

    mapping(address => bool) public isVault;
    mapping(address => mapping(address => uint256)) public freeBalance;
    mapping(address => mapping(address => uint256)) public reservedBalance;
    mapping(address => mapping(uint256 => uint64)) public shortOf;
    mapping(uint256 => uint64) public totalShort;

    /// @dev What backs one resting order. Option tokens of an ask sit at this contract.
    struct Reserve {
        address maker;
        uint64 tokenLots; // ask lots backed by option tokens
        uint64 collateralLots; // ask lots backed by collateral
        uint256 seriesId;
        uint256 usdc; // bid: premium plus the worst-case maker fee
    }

    mapping(uint64 => Reserve) public reserves;

    /// @notice Covered shorts (spreads): long tokens of `coverOf[a][s]` pledged here back shorts of
    /// series `s` instead of collateral. A cover always pays at least what the short owes: same
    /// underlying, expiry and type, a call with a lower strike or a put with a higher one.
    /// `coverCredit` is pledged but not yet written; `coveredShort` is the part of `shortOf` it backs.
    mapping(address => mapping(uint256 => uint256)) public coverOf;
    mapping(address => mapping(uint256 => uint64)) public coverCredit;
    mapping(address => mapping(uint256 => uint64)) public coveredShort;

    /// @notice Set at settlement: what one long lot receives, in the series' collateral token.
    mapping(uint256 => uint256) public payoffPerLot;

    /// @notice Set at settlement: settlement fee of one lot. USDC for the long side (taken from the
    /// lot's reserve); for the short side the same value in the collateral token (taken from collateral).
    mapping(uint256 => uint256) public settleFeePerLot;
    mapping(uint256 => uint256) public shortSettleFeePerLot;

    /// @dev Per-transaction context, kept in memory to stay clear of stack limits.
    struct Ctx {
        uint256 seriesId;
        address taker;
        Side takerSide;
        address collateral;
        uint256 perLot;
        uint256 tickUnit;
        uint256 lotsPerContract;
        uint256 spot;
        uint256 takerUsdcIn;
        uint256 takerUsdcOut;
        uint256 takerCollIn;
        uint256 takerCollOut;
        uint256 premium;
        uint256 takerFee;
        uint256 reserve; // settlement fee reserve per lot, USDC
    }

    modifier onlyBook() {
        if (msg.sender != orderBook) revert NotOrderBook();
        _;
    }

    constructor(
        address admin,
        ISeriesRegistry registry_,
        IOptionToken token_,
        IOracleAdapter oracle_,
        address feeRecipient_
    ) {
        if (admin == address(0) || feeRecipient_ == address(0)) revert InvalidConfig();
        registry = registry_;
        token = token_;
        oracle = oracle_;
        usdc = registry_.quoteToken();
        feeRecipient = feeRecipient_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);
    }

    // ================================================================ balances

    function deposit(address tkn, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        IERC20(tkn).safeTransferFrom(msg.sender, address(this), amount);
        freeBalance[msg.sender][tkn] += amount;
        emit Deposited(msg.sender, tkn, amount);
    }

    /// @notice Never paused: free funds can always leave.
    function withdraw(address tkn, uint256 amount) external nonReentrant {
        _debitFree(msg.sender, tkn, amount);
        IERC20(tkn).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, tkn, amount);
    }

    /// @notice Burns option tokens against the caller's own short in the same series and frees
    /// the collateral. Needed because tokens can arrive by plain ERC-1155 transfer.
    function netPositions(uint256 seriesId) external nonReentrant {
        uint64 shortLots = shortOf[msg.sender][seriesId];
        uint256 held = token.balanceOf(msg.sender, seriesId);
        // forge-lint: disable-next-line(unsafe-typecast) -- held is below a uint64 here
        uint64 n = held < shortLots ? uint64(held) : shortLots;
        if (n == 0) return;
        (address coll, uint256 perLot) = registry.collateralPerLot(seriesId);
        token.burn(msg.sender, seriesId, n);
        freeBalance[msg.sender][coll] += _reduceShort(msg.sender, seriesId, n, perLot);
        freeBalance[msg.sender][usdc] += n * reservePerLot(seriesId);
    }

    // ================================================================ spreads

    /// @notice Pledges long tokens of `coverId` so that up to `lots` of `shortId` can be written
    /// without collateral. One cover series per short series and account.
    function pledge(uint256 coverId, uint256 shortId, uint64 lots) external nonReentrant {
        _pledge(msg.sender, coverId, shortId, lots);
    }

    /// @notice The order book pledges for a taker inside one strategy transaction (takeLegs).
    function pledgeFor(address account, uint256 coverId, uint256 shortId, uint64 lots) external onlyBook nonReentrant {
        _pledge(account, coverId, shortId, lots);
    }

    function _pledge(address account, uint256 coverId, uint256 shortId, uint64 lots) internal {
        if (lots == 0) revert InvalidAmount();
        _requireTradable(shortId);
        uint256 prev = coverOf[account][shortId];
        if ((prev != 0 && prev != coverId) || !_covers(coverId, shortId)) revert InvalidCover(coverId, shortId);
        token.clearingMove(account, address(this), coverId, lots);
        coverOf[account][shortId] = coverId;
        coverCredit[account][shortId] += lots;
        emit Pledged(account, coverId, shortId, coverCredit[account][shortId]);
    }

    /// @notice Takes back pledged tokens that back no short.
    function unpledge(uint256 shortId, uint64 lots) external nonReentrant {
        uint64 credit = coverCredit[msg.sender][shortId];
        if (lots == 0 || lots > credit) revert InvalidAmount();
        coverCredit[msg.sender][shortId] = credit - lots;
        token.clearingMove(address(this), msg.sender, coverOf[msg.sender][shortId], lots);
        emit Pledged(msg.sender, coverOf[msg.sender][shortId], shortId, credit - lots);
    }

    /// @dev Payoff of `a` is at least the payoff of `b` at every settlement price.
    function _covers(uint256 a, uint256 b) internal pure returns (bool) {
        Series memory x = SeriesId.decode(a);
        Series memory y = SeriesId.decode(b);
        if (a == b || x.underlying != y.underlying || x.expiry != y.expiry || x.optType != y.optType) return false;
        return x.optType == OptionType.Call ? x.strike <= y.strike : x.strike >= y.strike;
    }

    /// @dev Closes `n` lots of a short: collateral-backed lots first (returned as the amount to
    /// free), then covered lots, whose pledged tokens go back to the credit.
    function _reduceShort(address account, uint256 seriesId, uint64 n, uint256 perLot)
        internal
        returns (uint256 freed)
    {
        uint64 shortLots = shortOf[account][seriesId];
        uint64 covered = coveredShort[account][seriesId];
        uint64 plain = shortLots - covered;
        uint64 fromPlain = n < plain ? n : plain;
        if (n > fromPlain) {
            coveredShort[account][seriesId] = covered - (n - fromPlain);
            coverCredit[account][seriesId] += n - fromPlain;
            // A covered short paid the settlement reserve when written: it comes back with the lot.
            freeBalance[account][usdc] += (n - fromPlain) * reservePerLot(seriesId);
        }
        shortOf[account][seriesId] = shortLots - n;
        totalShort[seriesId] -= n;
        emit PositionChanged(account, seriesId, shortLots - n);
        return uint256(fromPlain) * perLot;
    }

    // ================================================================ order reserves

    function reserveAsk(address maker, uint64 orderId, uint256 seriesId, uint64 lots)
        external
        onlyBook
        returns (uint64 tokenLots)
    {
        _requireTradable(seriesId);
        uint256 held = token.balanceOf(maker, seriesId);
        // forge-lint: disable-next-line(unsafe-typecast) -- held is below a uint64 here
        tokenLots = held < lots ? uint64(held) : lots;
        if (tokenLots > 0) token.clearingMove(maker, address(this), seriesId, tokenLots);

        uint64 collLots = lots - tokenLots;
        uint256 amount;
        if (collLots > 0) {
            (address coll, uint256 perLot) = registry.collateralPerLot(seriesId);
            amount = collLots * perLot;
            _debitFree(maker, coll, amount);
            reservedBalance[maker][coll] += amount;
        }
        reserves[orderId] = Reserve(maker, tokenLots, collLots, seriesId, 0);
        emit Reserved(orderId, maker, seriesId, tokenLots, amount);
    }

    function reserveBid(address maker, uint64 orderId, uint256 seriesId, uint64 lots, uint32 priceTicks)
        external
        onlyBook
    {
        _requireTradable(seriesId);
        uint256 premium = registry.premiumForTicks(seriesId, priceTicks, lots);
        // premium + worst-case maker fee + settlement reserve of the lots it will receive
        uint256 amount = premium + _ceilDiv(premium * premiumCapPpm, 1e6) + lots * reservePerLot(seriesId);
        _debitFree(maker, usdc, amount);
        reservedBalance[maker][usdc] += amount;
        reserves[orderId] = Reserve(maker, 0, 0, seriesId, amount);
        emit Reserved(orderId, maker, seriesId, 0, amount);
    }

    /// @notice Returns whatever is left of an order's reserve. Allowed after expiry too.
    function release(uint64 orderId) external onlyBook nonReentrant {
        Reserve memory r = reserves[orderId];
        if (r.maker == address(0)) revert UnknownReserve(orderId);
        delete reserves[orderId];

        if (r.tokenLots > 0) token.clearingMove(address(this), r.maker, r.seriesId, r.tokenLots);
        uint256 amount = r.usdc;
        if (amount > 0) _unreserve(r.maker, usdc, amount);
        if (r.collateralLots > 0) {
            (address coll, uint256 perLot) = registry.collateralPerLot(r.seriesId);
            uint256 c = r.collateralLots * perLot;
            _unreserve(r.maker, coll, c);
            amount += c;
        }
        emit Released(orderId, r.maker, r.tokenLots, amount);
    }

    // ================================================================ trades

    function settleFills(address taker, Side takerSide, uint256 seriesId, Fill[] calldata fills)
        external
        onlyBook
        nonReentrant
        returns (uint256 premium, uint256 takerFee)
    {
        if (tradingPaused) revert TradingIsPaused();
        _requireTradable(seriesId);
        Ctx memory c = _context(taker, takerSide, seriesId);

        for (uint256 i; i < fills.length; ++i) {
            _fill(c, fills[i]);
        }
        _settleTaker(c);
        return (c.premium, c.takerFee);
    }

    function _fill(Ctx memory c, Fill calldata f) internal {
        if (f.fromVault && (!isVault[f.maker] || f.orderId != 0)) revert NotAVault(f.maker);

        uint256 premium = uint256(f.priceTicks) * c.tickUnit * f.lots;
        uint256 takerFee = _fee(c, premium, f.lots, notionalFeePpm);

        bool takerBuys = c.takerSide == Side.Buy;
        address buyer = takerBuys ? c.taker : f.maker;
        address seller = takerBuys ? f.maker : c.taker;
        uint256 buyerFee = takerBuys ? takerFee : _fee(c, premium, f.lots, makerFeePpm);
        uint256 sellerFee = takerBuys ? _fee(c, premium, f.lots, makerFeePpm) : takerFee;

        // Premium: buyer pays premium + fee, seller gets premium - fee, the protocol keeps both fees.
        // The buyer also pays the settlement reserve of every lot it receives.
        if (takerBuys) {
            c.takerUsdcIn += premium + buyerFee + c.reserve * f.lots;
            freeBalance[seller][usdc] += premium - sellerFee;
        } else {
            if (f.fromVault) _debitFree(buyer, usdc, premium + buyerFee + c.reserve * f.lots);
            else _consumeBidReserve(f.orderId, buyer, premium + buyerFee + c.reserve * f.lots);
            c.takerUsdcOut += premium - sellerFee;
        }
        freeBalance[feeRecipient][usdc] += buyerFee + sellerFee;

        _deliver(c, f, seller, buyer);
        _cover(c, f, buyer);

        c.premium += premium;
        c.takerFee += takerFee;
        emit Trade(
            c.seriesId, buyer, seller, f.orderId, c.takerSide, f.priceTicks, f.lots, premium, buyerFee, sellerFee
        );
    }

    /// @dev Seller hands over `lots`: option tokens it holds first, then newly written lots.
    function _deliver(Ctx memory c, Fill calldata f, address seller, address buyer) internal {
        uint64 lots = f.lots;
        uint64 tokenUse;
        if (seller == c.taker) {
            uint256 held = token.balanceOf(seller, c.seriesId);
            // forge-lint: disable-next-line(unsafe-typecast) -- held is below a uint64 here
            tokenUse = held < lots ? uint64(held) : lots;
            if (tokenUse > 0) token.clearingMove(seller, buyer, c.seriesId, tokenUse);
            uint64 credit = coverCredit[seller][c.seriesId];
            if (credit > lots - tokenUse) credit = lots - tokenUse;
            if (credit > 0) {
                coverCredit[seller][c.seriesId] -= credit;
                coveredShort[seller][c.seriesId] += credit;
            }
            c.takerCollIn += (lots - tokenUse - credit) * c.perLot;
            // Delivered tokens hand their reserve back; covered lots pay one (collateral covers the rest).
            c.takerUsdcOut += tokenUse * c.reserve;
            c.takerUsdcIn += credit * c.reserve;
        } else if (f.fromVault) {
            _debitFree(seller, c.collateral, uint256(lots) * c.perLot);
        } else {
            Reserve storage r = _reserveOf(f.orderId, seller);
            tokenUse = r.tokenLots < lots ? r.tokenLots : lots;
            uint64 collUse = lots - tokenUse;
            if (collUse > r.collateralLots) revert ReserveExceeded(f.orderId);
            r.tokenLots -= tokenUse;
            r.collateralLots -= collUse;
            if (tokenUse > 0) token.clearingMove(address(this), buyer, c.seriesId, tokenUse);
            reservedBalance[seller][c.collateral] -= uint256(collUse) * c.perLot;
            freeBalance[seller][usdc] += tokenUse * c.reserve;
        }

        uint64 written = lots - tokenUse;
        if (written > 0) {
            uint64 s = shortOf[seller][c.seriesId] + written;
            shortOf[seller][c.seriesId] = s;
            totalShort[c.seriesId] += written;
            token.mint(buyer, c.seriesId, written);
            emit PositionChanged(seller, c.seriesId, s);
        }
    }

    /// @dev Buyer closes its own short first: tokens are burned and collateral is freed.
    function _cover(Ctx memory c, Fill calldata f, address buyer) internal {
        uint64 shortLots = shortOf[buyer][c.seriesId];
        if (shortLots == 0) return;
        uint64 n = shortLots < f.lots ? shortLots : f.lots;

        token.burn(buyer, c.seriesId, n);
        uint256 freed = _reduceShort(buyer, c.seriesId, n, c.perLot);
        if (buyer == c.taker) {
            c.takerCollOut += freed;
            c.takerUsdcOut += n * c.reserve;
        } else {
            freeBalance[buyer][c.collateral] += freed;
            freeBalance[buyer][usdc] += n * c.reserve;
        }
    }

    /// @dev One net transfer per token with the taker's wallet.
    function _settleTaker(Ctx memory c) internal {
        if (c.collateral == usdc) {
            _netTransfer(c.taker, usdc, c.takerUsdcIn + c.takerCollIn, c.takerUsdcOut + c.takerCollOut);
        } else {
            _netTransfer(c.taker, usdc, c.takerUsdcIn, c.takerUsdcOut);
            _netTransfer(c.taker, c.collateral, c.takerCollIn, c.takerCollOut);
        }
    }

    function _netTransfer(address taker, address tkn, uint256 inAmt, uint256 outAmt) internal {
        if (inAmt > outAmt) IERC20(tkn).safeTransferFrom(taker, address(this), inAmt - outAmt);
        else if (outAmt > inAmt) IERC20(tkn).safeTransfer(taker, outAmt - inAmt);
    }

    function _consumeBidReserve(uint64 orderId, address maker, uint256 amount) internal {
        Reserve storage r = _reserveOf(orderId, maker);
        if (amount > r.usdc) revert ReserveExceeded(orderId);
        r.usdc -= amount;
        reservedBalance[maker][usdc] -= amount;
    }

    // ================================================================ settlement

    /// @notice Fixes the payoff of an expired series from the oracle's settlement price.
    function settleSeries(uint256 seriesId) public nonReentrant {
        if (registry.stateOf(seriesId) != SeriesState.Active) revert NotSettled(seriesId);
        _settle(seriesId);
    }

    /// @notice Settles every still-active series of one expiry. Returns how many were settled.
    function settleExpiry(uint8 underlying, uint64 expiry) external nonReentrant returns (uint256 settled) {
        uint256[] memory ids = registry.listSeries(underlying, expiry);
        for (uint256 i; i < ids.length; ++i) {
            if (registry.stateOf(ids[i]) != SeriesState.Active) continue;
            _settle(ids[i]);
            ++settled;
        }
    }

    function _settle(uint256 seriesId) internal {
        Series memory s = SeriesId.decode(seriesId);
        if (block.timestamp < s.expiry) revert NotExpired(seriesId);
        (uint256 price, bool isFinal,) = oracle.settlementPrice(s.underlying, s.expiry);
        if (!isFinal) revert PriceNotFinal(seriesId);

        uint256 strike1e8 = uint256(s.strike) * 1e8;
        uint256 payoff;
        if (s.optType == OptionType.Call) {
            // (S - K) / S of the underlying per contract, rounded down in the writer's favour
            if (price > strike1e8) {
                (, uint256 perLot) = registry.collateralPerLot(seriesId);
                payoff = perLot * (price - strike1e8) / price;
            }
        } else if (strike1e8 > price) {
            // (K - S) USDC per contract, divided into lots
            payoff = (strike1e8 - price) / (100 * uint256(registry.config(s.underlying).lotsPerContract));
        }
        payoffPerLot[seriesId] = payoff;

        // Settlement fee on the notional at the settlement price, capped by the lot's reserve.
        uint256 lpc = registry.config(s.underlying).lotsPerContract;
        uint256 fee = price * settlementFeePpm / (1e8 * lpc);
        uint256 cap = reservePerLot(seriesId);
        if (fee > cap) fee = cap;
        settleFeePerLot[seriesId] = fee;
        // Writers pay it from collateral: calls in the underlying (USDC value / price), puts in USDC.
        if (s.optType == OptionType.Call) {
            fee = fee * 10 ** uint256(registry.config(s.underlying).collateralDecimals) * 100 / price;
        }
        shortSettleFeePerLot[seriesId] = fee;
        registry.markSettled(seriesId);
        emit SeriesSettled(seriesId, price, payoff);
    }

    function redeem(uint256 seriesId, uint64 lots) external nonReentrant {
        _redeem(msg.sender, seriesId, lots);
    }

    /// @notice Keeper helper: pays out every listed holder's full balance to that holder.
    function redeemFor(address[] calldata holders, uint256 seriesId) external nonReentrant {
        for (uint256 i; i < holders.length; ++i) {
            address h = holders[i];
            // Tokens here back resting asks or spreads; vaults cash in their own longs when they roll.
            if (h == address(this) || isVault[h]) continue;
            uint256 bal = token.balanceOf(h, seriesId);
            // forge-lint: disable-next-line(unsafe-typecast) -- balances are lot counts minted as uint64
            if (bal > 0) _redeem(h, seriesId, uint64(bal));
        }
    }

    function _redeem(address holder, uint256 seriesId, uint64 lots) internal {
        if (registry.stateOf(seriesId) != SeriesState.Settled) revert NotSettled(seriesId);
        if (lots == 0) revert InvalidAmount();
        token.burn(holder, seriesId, lots);
        (address coll,) = registry.collateralPerLot(seriesId);
        uint256 amount = uint256(lots) * payoffPerLot[seriesId];
        if (amount > 0) IERC20(coll).safeTransfer(holder, amount);
        _payReserve(holder, lots, seriesId);
        emit Redeemed(holder, seriesId, lots, coll, amount);
    }

    function claimShort(uint256 seriesId) external nonReentrant {
        _claimShort(msg.sender, seriesId);
    }

    /// @notice Keeper helper: credits a writer's leftover collateral to its free balance.
    function claimShortFor(address seller, uint256 seriesId) external nonReentrant {
        _claimShort(seller, seriesId);
    }

    function _claimShort(address seller, uint256 seriesId) internal {
        if (registry.stateOf(seriesId) != SeriesState.Settled) revert NotSettled(seriesId);
        uint64 lots = shortOf[seller][seriesId];
        uint64 covered = coveredShort[seller][seriesId];
        uint64 credit = coverCredit[seller][seriesId];
        if (lots == 0 && credit == 0) return;
        (address coll, uint256 perLot) = registry.collateralPerLot(seriesId);
        uint256 owed = payoffPerLot[seriesId];
        uint256 amount = uint256(lots - covered) * (perLot - owed - shortSettleFeePerLot[seriesId]);
        freeBalance[feeRecipient][coll] += uint256(lots - covered) * shortSettleFeePerLot[seriesId];
        if (covered + credit > 0) {
            // Pledged tokens are cashed in here: they pay the covered lots' payoff and the rest is the writer's.
            uint256 coverId = coverOf[seller][seriesId];
            if (registry.stateOf(coverId) != SeriesState.Settled) revert NotSettled(coverId);
            uint256 paid = payoffPerLot[coverId];
            amount += uint256(covered) * (paid - owed) + uint256(credit) * paid;
            token.burn(address(this), coverId, covered + credit);
            coveredShort[seller][seriesId] = 0;
            coverCredit[seller][seriesId] = 0;
            // Covered shorts pay their fee from their own reserve, the pledged longs from theirs.
            _payReserve(seller, covered, seriesId);
            _payReserve(seller, covered + credit, coverId);
        }
        shortOf[seller][seriesId] = 0;
        totalShort[seriesId] -= lots;
        // Leftover collateral goes back to the writer's wallet; vaults keep it in Clearing to trade.
        if (isVault[seller]) freeBalance[seller][coll] += amount;
        else if (amount > 0) IERC20(coll).safeTransfer(seller, amount);
        emit ShortClaimed(seller, seriesId, lots, coll, amount);
        emit PositionChanged(seller, seriesId, 0);
    }

    // ================================================================ views

    // ================================================================ admin

    function setOrderBook(address book) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (orderBook != address(0)) revert OrderBookAlreadySet();
        if (book == address(0)) revert InvalidConfig();
        orderBook = book;
        emit OrderBookSet(book);
    }

    function setVault(address vault, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isVault[vault] = allowed;
        emit VaultSet(vault, allowed);
    }

    function setFees(uint32 takerPpm, uint32 makerPpm, uint32 capPpm, uint32 settlePpm, address recipient)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (
            takerPpm > MAX_NOTIONAL_FEE_PPM || makerPpm > MAX_NOTIONAL_FEE_PPM || capPpm > MAX_PREMIUM_CAP_PPM
                || settlePpm > MAX_SETTLEMENT_FEE_PPM || recipient == address(0)
        ) revert InvalidConfig();
        (notionalFeePpm, makerFeePpm, premiumCapPpm, settlementFeePpm) = (takerPpm, makerPpm, capPpm, settlePpm);
        feeRecipient = recipient;
        emit FeesSet(takerPpm, makerPpm, capPpm, settlePpm, recipient);
    }

    /// @notice Stops new trades only. Withdrawals, cancels and (later) settlement keep working.
    function pauseTrading(bool paused) external onlyRole(GUARDIAN_ROLE) {
        tradingPaused = paused;
        emit TradingPaused(paused);
    }

    // ================================================================ internals

    function _context(address taker, Side takerSide, uint256 seriesId) internal view returns (Ctx memory c) {
        uint8 u = SeriesId.underlying(seriesId);
        UnderlyingConfig memory cfg = registry.config(u);
        (c.collateral, c.perLot) = registry.collateralPerLot(seriesId);
        (c.spot,) = oracle.spot(u);
        c.seriesId = seriesId;
        c.taker = taker;
        c.takerSide = takerSide;
        c.lotsPerContract = cfg.lotsPerContract;
        c.tickUnit = cfg.tickSize / cfg.lotsPerContract;
        c.reserve = reservePerLot(seriesId);
    }

    /// @notice Settlement fee reserve that every long lot of `seriesId` carries, in USDC.
    /// Paid by whoever receives the lot, handed back when it is sold on, burned or settled.
    function reservePerLot(uint256 seriesId) public view returns (uint256) {
        Series memory s = SeriesId.decode(seriesId);
        return _ceilDiv(uint256(s.strike) * SETTLEMENT_RESERVE_PPM, registry.config(s.underlying).lotsPerContract);
    }

    /// @dev Settles the reserve of `lots` expired long lots: fee to the protocol, the rest to the holder.
    function _payReserve(address holder, uint64 lots, uint256 seriesId) internal {
        if (lots == 0) return;
        uint256 fee = lots * settleFeePerLot[seriesId];
        uint256 back = lots * reservePerLot(seriesId) - fee;
        freeBalance[feeRecipient][usdc] += fee;
        if (isVault[holder]) freeBalance[holder][usdc] += back;
        else if (back > 0) IERC20(usdc).safeTransfer(holder, back);
    }

    /// @dev min(ppm of spot * size, premiumCap of premium), in USDC.
    function _fee(Ctx memory c, uint256 premium, uint256 lots, uint32 ppm) internal view returns (uint256) {
        uint256 byNotional = c.spot * lots * ppm / (c.lotsPerContract * 1e8);
        uint256 byPremium = premium * premiumCapPpm / 1e6;
        return byNotional < byPremium ? byNotional : byPremium;
    }

    function _reserveOf(uint64 orderId, address maker) internal view returns (Reserve storage r) {
        r = reserves[orderId];
        if (r.maker != maker || maker == address(0)) revert UnknownReserve(orderId);
    }

    function _requireTradable(uint256 seriesId) internal view {
        if (!registry.isTradable(seriesId)) revert SeriesNotTradable(seriesId);
    }

    function _debitFree(address account, address tkn, uint256 amount) internal {
        uint256 bal = freeBalance[account][tkn];
        if (bal < amount) revert InsufficientBalance(account, tkn, amount, bal);
        freeBalance[account][tkn] = bal - amount;
    }

    function _unreserve(address account, address tkn, uint256 amount) internal {
        reservedBalance[account][tkn] -= amount;
        freeBalance[account][tkn] += amount;
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
