// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IOracleAdapter} from "./IOracleAdapter.sol";

import {Side, Fill} from "../types/DerstarTypes.sol";
import {IOptionToken} from "./IOptionToken.sol";

interface IClearing {
    event Deposited(address indexed account, address indexed token, uint256 amount);
    event Withdrawn(address indexed account, address indexed token, uint256 amount);
    event Reserved(
        uint64 indexed orderId, address indexed maker, uint256 indexed seriesId, uint64 tokenLots, uint256 amount
    );
    event Released(uint64 indexed orderId, address indexed maker, uint64 tokenLots, uint256 amount);
    event Trade(
        uint256 indexed seriesId,
        address indexed buyer,
        address indexed seller,
        uint64 orderId,
        Side takerSide,
        uint32 priceTicks,
        uint64 lots,
        uint256 premium,
        uint256 buyerFee,
        uint256 sellerFee
    );
    event PositionChanged(address indexed account, uint256 indexed seriesId, uint64 shortLots);
    event OrderBookSet(address orderBook);
    event VaultSet(address indexed vault, bool allowed);
    event FeesSet(
        uint32 takerFeePpm, uint32 makerFeePpm, uint32 premiumCapPpm, uint32 settlementFeePpm, address feeRecipient
    );
    event TradingPaused(bool paused);
    event SeriesSettled(uint256 indexed seriesId, uint256 settlementPrice1e8, uint256 payoffPerLot);
    event Redeemed(address indexed holder, uint256 indexed seriesId, uint64 lots, address token, uint256 amount);
    event Pledged(address indexed account, uint256 indexed coverId, uint256 indexed shortId, uint64 credit);
    event ShortClaimed(address indexed seller, uint256 indexed seriesId, uint64 lots, address token, uint256 amount);

    error NotOrderBook();
    error OrderBookAlreadySet();
    error TradingIsPaused();
    error SeriesNotTradable(uint256 seriesId);
    error InsufficientBalance(address account, address token, uint256 needed, uint256 available);
    error UnknownReserve(uint64 orderId);
    error ReserveExceeded(uint64 orderId);
    error NotAVault(address account);
    error InvalidCover(uint256 coverId, uint256 shortId);
    error InvalidAmount();
    error InvalidConfig();
    error NotExpired(uint256 seriesId);
    error PriceNotFinal(uint256 seriesId);
    error NotSettled(uint256 seriesId);

    // Users, makers, vaults
    function deposit(address token, uint256 amount) external;
    function withdraw(address token, uint256 amount) external;
    function netPositions(uint256 seriesId) external;

    // OrderBook only
    function reserveAsk(address maker, uint64 orderId, uint256 seriesId, uint64 lots)
        external
        returns (uint64 tokenLots);
    function reserveBid(address maker, uint64 orderId, uint256 seriesId, uint64 lots, uint32 priceTicks) external;
    function release(uint64 orderId) external;
    function settleFills(address taker, Side takerSide, uint256 seriesId, Fill[] calldata fills)
        external
        returns (uint256 premium, uint256 takerFee);

    // Settlement: anyone can call; payouts always go to the position owner
    function settleSeries(uint256 seriesId) external;
    function settleExpiry(uint8 underlying, uint64 expiry) external returns (uint256 settled);
    function redeem(uint256 seriesId, uint64 lots) external;
    function redeemFor(address[] calldata holders, uint256 seriesId) external;
    function claimShort(uint256 seriesId) external;
    function pledge(uint256 coverId, uint256 shortId, uint64 lots) external;
    function pledgeFor(address account, uint256 coverId, uint256 shortId, uint64 lots) external;
    function unpledge(uint256 shortId, uint64 lots) external;
    function claimShortFor(address seller, uint256 seriesId) external;

    // Views
    function payoffPerLot(uint256 seriesId) external view returns (uint256);
    function reservePerLot(uint256 seriesId) external view returns (uint256);
    function freeBalance(address account, address token) external view returns (uint256);
    function reservedBalance(address account, address token) external view returns (uint256);
    function shortOf(address account, uint256 seriesId) external view returns (uint64);
    function coveredShort(address account, uint256 seriesId) external view returns (uint64);
    function coverCredit(address account, uint256 seriesId) external view returns (uint64);
    function notionalFeePpm() external view returns (uint32);
    function premiumCapPpm() external view returns (uint32);
    function oracle() external view returns (IOracleAdapter);
    function totalShort(uint256 seriesId) external view returns (uint64);
    function isVault(address account) external view returns (bool);
    function token() external view returns (IOptionToken);
}
