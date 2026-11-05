// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TradingBase} from "./TradingBase.t.sol";
import {StopOrders} from "../src/core/StopOrders.sol";
import {IvFeed} from "../src/core/IvFeed.sol";
import {IIvFeed} from "../src/interfaces/IIvFeed.sol";
import {IOrderBook} from "../src/interfaces/IOrderBook.sol";
import {IClearing} from "../src/interfaces/IClearing.sol";
import {ISeriesRegistry} from "../src/interfaces/ISeriesRegistry.sol";
import {Side} from "../src/types/DerstarTypes.sol";

/// Stop-loss on the BTC 110k call, Nov 6, flat 50% vol: mark $2 071.90 = 414 ticks at 104k spot.
contract StopOrdersTest is TradingBase {
    IvFeed internal ivFeed;
    StopOrders internal stops;
    address internal bot = makeAddr("bot");

    function _wire() internal override {
        super._wire();
        ivFeed = new IvFeed(admin, keeper);
        stops = new StopOrders(
            IOrderBook(address(book)),
            IClearing(address(clr)),
            ISeriesRegistry(address(registry)),
            IIvFeed(address(ivFeed))
        );
        bytes32 role = book.EXECUTOR_ROLE();
        vm.prank(admin);
        book.grantRole(role, address(stops));
    }

    function setUp() public override {
        super.setUp();
        _pushVol(500_000);
        _deposit(mm, wbtc, 5e8);
        _deposit(mm, usdc, 500_000e6);
        _deposit(carol, wbtc, 2e8);
    }

    function _pushVol(uint32 atm) internal {
        uint64[] memory e = new uint64[](1);
        e[0] = FRI_NOV06;
        IIvFeed.Smile[] memory s = new IIvFeed.Smile[](1);
        s[0] = IIvFeed.Smile(atm, 0, 0, 0);
        vm.prank(keeper);
        ivFeed.push(BTC, e, s);
    }

    function _spot(int256 price) internal {
        vm.prank(admin);
        btcFeed.pushPrice(price);
    }

    function _place(address who, Side side, uint64 lots, uint32 trig, uint32 limit) internal returns (uint64) {
        vm.prank(who);
        return stops.place(call110, side, lots, trig, limit);
    }

    /// bob holds 10 lots long.
    function _bobLong() internal {
        _ask(mm, call110, 420, 10);
        assertEq(_buy(bob, call110, 10, 420), 10);
    }

    /// carol has written 10 lots (covered by her WBTC in Clearing).
    function _carolShort() internal {
        _bid(mm, call110, 410, 10);
        assertEq(_sell(carol, call110, 10, 410), 10);
        assertEq(clr.shortOf(carol, call110), 10);
    }

    function test_markFromSpotAndVol() public view {
        assertEq(stops.markTicks(call110), 414);
    }

    function test_longStopSellsWhenMarkFalls() public {
        _bobLong();
        uint64 id = _place(bob, Side.Sell, 10, 300, 200);
        vm.expectRevert(abi.encodeWithSelector(StopOrders.NotTriggered.selector, id, uint32(414)));
        stops.trigger(id);
        assertFalse(stops.isTriggered(id));

        _spot(100_000e8);
        assertLe(stops.markTicks(call110), 300);
        assertTrue(stops.isTriggered(id));
        _bid(mm, call110, 250, 10);
        uint256 before = usdc.balanceOf(bob);

        vm.prank(bot);
        assertEq(stops.trigger(id), 10);
        assertEq(token.balanceOf(bob, call110), 0, "long sold");
        assertEq(clr.shortOf(bob, call110), 0, "no short opened");
        assertGt(usdc.balanceOf(bob), before, "proceeds to the owner, not the keeper");
        assertEq(stops.getStop(id).owner, address(0), "stop removed");
        assertEq(stops.stopCount(bob), 0);
        _assertBacked(call110);
    }

    function test_shortStopBuysBackWhenMarkRises() public {
        _carolShort();
        uint64 id = _place(carol, Side.Buy, 10, 600, 800);
        _spot(108_000e8);
        assertGe(stops.markTicks(call110), 600);
        _ask(mm, call110, 700, 10);

        vm.prank(bot);
        assertEq(stops.trigger(id), 10);
        assertEq(clr.shortOf(carol, call110), 0, "short bought back");
        assertEq(token.balanceOf(carol, call110), 0, "no long opened");
        _assertBacked(call110);
    }

    function test_neverClosesMoreThanHeld() public {
        _bobLong();
        uint64 id = _place(bob, Side.Sell, 10, 300, 200);
        _bid(mm, call110, 400, 6);
        _sell(bob, call110, 6, 400); // bob sells part himself
        _spot(100_000e8);
        _bid(mm, call110, 250, 10);

        assertEq(stops.trigger(id), 4);
        assertEq(token.balanceOf(bob, call110), 0);
        assertEq(clr.shortOf(bob, call110), 0, "the stop did not write a short");
        assertEq(stops.getStop(id).owner, address(0));
    }

    function test_partialFillKeepsTheRest() public {
        _bobLong();
        uint64 id = _place(bob, Side.Sell, 10, 300, 200);
        _spot(100_000e8);
        _bid(mm, call110, 250, 4);

        assertEq(stops.trigger(id), 4);
        assertEq(stops.getStop(id).lots, 6);
        assertEq(token.balanceOf(bob, call110), 6);
    }

    function test_noBidWithinLimitRevertsAndStopStays() public {
        _bobLong();
        uint64 id = _place(bob, Side.Sell, 10, 300, 200);
        _spot(100_000e8);
        _bid(mm, call110, 150, 10); // below bob's limit

        vm.expectRevert();
        stops.trigger(id);
        assertEq(stops.getStop(id).lots, 10);
        assertEq(token.balanceOf(bob, call110), 10);
    }

    function test_positionGoneRemovesTheStop() public {
        _bobLong();
        uint64 id = _place(bob, Side.Sell, 10, 300, 200);
        _bid(mm, call110, 400, 10);
        _sell(bob, call110, 10, 400);

        assertEq(stops.trigger(id), 0);
        assertEq(stops.getStop(id).owner, address(0));
        assertEq(stops.stopCount(bob), 0);
    }

    function test_staleVolBlocksTheTrigger() public {
        _bobLong();
        uint64 id = _place(bob, Side.Sell, 10, 500, 200);
        vm.warp(block.timestamp + 1 days);
        _spot(100_000e8);
        vm.expectRevert(abi.encodeWithSelector(StopOrders.MarkUnavailable.selector, call110));
        stops.trigger(id);
        assertFalse(stops.isTriggered(id));
    }

    function test_placeChecks() public {
        vm.expectRevert(abi.encodeWithSelector(StopOrders.NoPosition.selector, call110));
        _place(bob, Side.Sell, 10, 300, 200);
        _bobLong();
        vm.expectRevert(StopOrders.InvalidPrice.selector);
        _place(bob, Side.Sell, 10, 300, 301); // sell limit above the trigger
        vm.expectRevert(StopOrders.InvalidSize.selector);
        _place(bob, Side.Sell, 0, 300, 200);
        vm.expectRevert(abi.encodeWithSelector(StopOrders.NoPosition.selector, call110));
        _place(bob, Side.Buy, 10, 600, 700); // bob has no short
    }

    function test_onlyOwnerCancels() public {
        _bobLong();
        uint64 id = _place(bob, Side.Sell, 10, 300, 200);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(StopOrders.NotStopOwner.selector, id));
        stops.cancel(id);
        vm.prank(bob);
        stops.cancel(id);
        assertEq(stops.stopCount(bob), 0);
    }

    function test_takeForNeedsTheExecutorRole() public {
        _bobLong();
        _bid(mm, call110, 400, 10);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, carol, book.EXECUTOR_ROLE()
            )
        );
        vm.prank(carol);
        book.takeFor(bob, call110, Side.Sell, 10, 1);
    }
}
