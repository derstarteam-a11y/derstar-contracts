// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TradingBase} from "./TradingBase.t.sol";
import {IOrderBook} from "../src/interfaces/IOrderBook.sol";
import {IClearing} from "../src/interfaces/IClearing.sol";
import {SeriesId} from "../src/libraries/SeriesId.sol";
import {Series, OptionType, Side} from "../src/types/DerstarTypes.sol";

/// Strategies in one transaction: every leg fills in full or nothing happens.
contract TakeLegsTest is TradingBase {
    uint256 internal call108;
    uint256 internal put102;

    function setUp() public override {
        super.setUp();
        call108 = SeriesId.encode(Series(BTC, OptionType.Call, FRI_NOV06, 108000));
        put102 = SeriesId.encode(Series(BTC, OptionType.Put, FRI_NOV06, 102000));
        _deposit(mm, wbtc, 2e8);
        _deposit(mm, usdc, 200_000e6);
        _deposit(bob, usdc, 100_000e6);
    }

    function _leg(uint256 id, Side side, uint64 lots, uint32 limit, uint256 pledgeFrom)
        internal
        pure
        returns (IOrderBook.Leg memory)
    {
        return IOrderBook.Leg(id, side, lots, limit, pledgeFrom);
    }

    function _take(address who, IOrderBook.Leg[] memory legs) internal {
        vm.prank(who);
        book.takeLegs(legs, NO_DEADLINE);
    }

    function test_bullCallSpreadInOneTransaction() public {
        _ask(mm, call108, 600, 10);
        _bid(bob, call110, 300, 10);
        IOrderBook.Leg[] memory legs = new IOrderBook.Leg[](2);
        legs[0] = _leg(call108, Side.Buy, 10, 600, 0);
        legs[1] = _leg(call110, Side.Sell, 10, 300, call108);
        uint256 btcBefore = wbtc.balanceOf(carol);
        _take(carol, legs);

        assertEq(clr.shortOf(carol, call110), 10);
        assertEq(clr.coveredShort(carol, call110), 10, "short leg covered by the long");
        assertEq(token.balanceOf(address(clr), call108), 10, "long pledged in Clearing");
        assertEq(wbtc.balanceOf(carol), btcBefore, "no collateral for the short leg");
        _assertBacked(call108);
        _assertBacked(call110);
    }

    function test_straddleBuysBothLegs() public {
        _deposit(mm, usdc, 200_000e6);
        _ask(mm, call110, 400, 5);
        vm.prank(mm);
        book.placeOrder(put100, Side.Sell, 500, 5);
        IOrderBook.Leg[] memory legs = new IOrderBook.Leg[](2);
        legs[0] = _leg(call110, Side.Buy, 5, 400, 0);
        legs[1] = _leg(put100, Side.Buy, 5, 500, 0);
        _take(carol, legs);
        assertEq(token.balanceOf(carol, call110), 5);
        assertEq(token.balanceOf(carol, put100), 5);
    }

    function test_revertsWhenALegDoesNotFillInFull() public {
        _ask(mm, call108, 600, 10);
        _bid(bob, call110, 300, 4); // only 4 of the 10 the short leg needs
        IOrderBook.Leg[] memory legs = new IOrderBook.Leg[](2);
        legs[0] = _leg(call108, Side.Buy, 10, 600, 0);
        legs[1] = _leg(call110, Side.Sell, 10, 300, call108);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.BelowMinLots.selector, uint64(4), uint64(10)));
        book.takeLegs(legs, NO_DEADLINE);
        assertEq(token.balanceOf(carol, call108), 0, "first leg rolled back too");
    }

    function test_revertsOnBadLegCount() public {
        IOrderBook.Leg[] memory none = new IOrderBook.Leg[](0);
        vm.prank(carol);
        vm.expectRevert(IOrderBook.InvalidSize.selector);
        book.takeLegs(none, NO_DEADLINE);

        IOrderBook.Leg[] memory five = new IOrderBook.Leg[](5);
        vm.prank(carol);
        vm.expectRevert(IOrderBook.InvalidSize.selector);
        book.takeLegs(five, NO_DEADLINE);
    }

    function test_revertsAfterDeadline() public {
        _ask(mm, call108, 600, 10);
        IOrderBook.Leg[] memory legs = new IOrderBook.Leg[](1);
        legs[0] = _leg(call108, Side.Buy, 10, 600, 0);
        uint64 deadline = uint64(block.timestamp - 1);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.Expired.selector, deadline));
        book.takeLegs(legs, deadline);
    }

    function test_pledgeForIsOrderBookOnly() public {
        vm.prank(carol);
        vm.expectRevert();
        clr.pledgeFor(carol, call108, call110, 1);
    }
}
