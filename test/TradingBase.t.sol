// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {Clearing} from "../src/core/Clearing.sol";
import {OrderBook} from "../src/core/OrderBook.sol";
import {OracleAdapter} from "../src/core/OracleAdapter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockQuoteVault} from "../src/mocks/MockQuoteVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {SeriesId} from "../src/libraries/SeriesId.sol";
import {Series, OptionType, Side} from "../src/types/DerstarTypes.sol";

abstract contract TradingBase is BaseTest {
    OracleAdapter internal oracle;
    Clearing internal clr;
    OrderBook internal book;
    MockQuoteVault internal vault;

    address internal mm = makeAddr("mm");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal fees = makeAddr("fees");

    uint256 internal call110; // BTC call, strike 110 000, Nov 6
    uint256 internal put100; // BTC put, strike 100 000, Nov 6

    uint64 internal constant NO_DEADLINE = type(uint64).max;

    function _wire() internal virtual override {
        vm.startPrank(admin);
        btcFeed.pushPrice(104_000e8);
        ethFeed.pushPrice(3_100e8);
        vm.stopPrank();
        oracle = new OracleAdapter(admin, registry, AggregatorV3Interface(address(0)));
        clr = new Clearing(admin, registry, token, oracle, fees);
        book = new OrderBook(admin, registry, clr);
        vault = new MockQuoteVault(clr);
        vm.startPrank(admin);
        registry.setClearing(address(clr));
        clr.setOrderBook(address(book));
        clr.setVault(address(vault), true);
        book.setVaultFor(BTC, uint8(OptionType.Call), address(vault));
        book.setVaultFor(BTC, uint8(OptionType.Put), address(vault));
        vm.stopPrank();
        token.setClearing(address(clr));
    }

    function setUp() public virtual override {
        super.setUp();
        uint64[] memory s = new uint64[](6);
        (s[0], s[1], s[2], s[3], s[4], s[5]) = (100000, 102000, 104000, 106000, 108000, 110000);
        vm.prank(keeper);
        registry.createExpiry(BTC, FRI_NOV06, s);
        call110 = SeriesId.encode(Series(BTC, OptionType.Call, FRI_NOV06, 110000));
        put100 = SeriesId.encode(Series(BTC, OptionType.Put, FRI_NOV06, 100000));

        address[5] memory people = [mm, alice, bob, carol, address(this)];
        for (uint256 i; i < people.length; ++i) {
            _give(people[i], wbtc, 10e8);
            _give(people[i], usdc, 1_000_000e6);
        }
    }

    function _give(address who, MockERC20 tkn, uint256 amount) internal {
        vm.prank(admin);
        tkn.mint(who, amount);
        vm.prank(who);
        tkn.approve(address(clr), type(uint256).max);
    }

    function _deposit(address who, MockERC20 tkn, uint256 amount) internal {
        vm.prank(who);
        clr.deposit(address(tkn), amount);
    }

    function _ask(address who, uint256 series, uint32 ticks, uint64 lots) internal returns (uint64) {
        vm.prank(who);
        return book.placeOrder(series, Side.Sell, ticks, lots);
    }

    function _bid(address who, uint256 series, uint32 ticks, uint64 lots) internal returns (uint64) {
        vm.prank(who);
        return book.placeOrder(series, Side.Buy, ticks, lots);
    }

    function _buy(address who, uint256 series, uint64 lots, uint32 maxTicks) internal returns (uint64 filled) {
        vm.prank(who);
        (filled,,) = book.buy(series, lots, maxTicks, 0, NO_DEADLINE);
    }

    function _sell(address who, uint256 series, uint64 lots, uint32 minTicks) internal returns (uint64 filled) {
        vm.prank(who);
        (filled,,) = book.sell(series, lots, minTicks, 0, NO_DEADLINE);
    }

    function _fundVault(MockERC20 tkn, uint256 amount) internal {
        _give(address(this), tkn, amount);
        tkn.approve(address(vault), amount);
        vault.fund(address(tkn), amount);
    }

    /// @dev The core invariant: every long token is backed by exactly one short lot.
    function _assertBacked(uint256 series) internal view {
        assertEq(token.totalSupply(series), clr.totalShort(series), "supply != total short");
    }
}
