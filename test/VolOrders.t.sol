// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TradingBase} from "./TradingBase.t.sol";
import {IOrderBook} from "../src/interfaces/IOrderBook.sol";
import {IOracleAdapter} from "../src/interfaces/IOracleAdapter.sol";
import {Side} from "../src/types/DerstarTypes.sol";

/// Vol orders on the BTC 110k call, Nov 6. At 104k spot and 16.8 days, Black-Scholes gives
/// per contract: 45% $1 694.13, 50% $2 071.90, 55% $2 460.79, 80% $4 502.02; tick $5.
contract VolOrdersTest is TradingBase {
    function _wire() internal override {
        super._wire();
        vm.prank(admin);
        book.setVolPricing(IOracleAdapter(address(oracle)), 2 hours, 64);
    }

    function setUp() public override {
        super.setUp();
        _deposit(mm, wbtc, 2e8);
        _deposit(mm, usdc, 200_000e6);
        _deposit(carol, wbtc, 2e8);
        _deposit(carol, usdc, 200_000e6);
    }

    function _volAsk(address who, uint32 vol, uint32 floorTicks, uint64 lots) internal returns (uint64) {
        vm.prank(who);
        return book.placeVolOrder(call110, Side.Sell, vol, floorTicks, lots);
    }

    function _volBid(address who, uint32 vol, uint32 capTicks, uint64 lots) internal returns (uint64) {
        vm.prank(who);
        return book.placeVolOrder(call110, Side.Buy, vol, capTicks, lots);
    }

    function test_askPricedFromVol() public {
        _volAsk(mm, 500_000, 1, 10);
        uint256 before = usdc.balanceOf(alice);
        assertEq(_buy(alice, call110, 10, 500), 10);
        assertEq(clr.shortOf(mm, call110), 10);
        // 2 071.90 / 5 rounds up to 415 ticks = $20.75 per lot
        assertEq(clr.freeBalance(mm, address(usdc)), 200_000e6 + 415 * 50_000 * 10 - _makerFee(415, 10));
        assertGt(before - usdc.balanceOf(alice), 415 * 50_000 * 10);
        _assertBacked(call110);
    }

    function test_followsSpotWithoutUpdates() public {
        _volAsk(mm, 500_000, 1, 10);
        (,,, uint32[] memory p) = book.volBook(call110, Side.Sell, 10);
        assertEq(p[0], 415);
        vm.prank(admin);
        btcFeed.pushPrice(108_000e8); // 3 596.39 -> 720 ticks
        (,,, p) = book.volBook(call110, Side.Sell, 10);
        assertEq(p[0], 720);
        assertEq(_tryBuy(alice, 10, 700), 0); // repriced above the old limit
        assertEq(_buy(alice, call110, 10, 720), 10);
    }

    function _tryBuy(address who, uint64 lots, uint32 max) internal view returns (uint64) {
        (uint64 filled,,,,,) = book.preview(call110, Side.Buy, lots, max, who);
        return filled;
    }

    function test_queuesByVol() public {
        uint64 high = _volAsk(mm, 550_000, 1, 5);
        uint64 low = _volAsk(carol, 500_000, 1, 5);
        uint64 lowLater = _volAsk(mm, 500_000, 1, 5);
        (uint64[] memory ids, uint32[] memory vols,,) = book.volBook(call110, Side.Sell, 10);
        assertEq(ids[0], low);
        assertEq(ids[1], lowLater); // same vol: arrival order
        assertEq(ids[2], high);
        assertEq(vols[2], 550_000);

        _buy(alice, call110, 7, 1000);
        assertEq(clr.shortOf(carol, call110), 5);
        assertEq(clr.shortOf(mm, call110), 2);
        (,,, uint64 left) = _volLeft(lowLater);
        assertEq(left, 3);
    }

    function _volLeft(uint64 id) internal view returns (address, uint256, Side, uint64) {
        (address maker, uint256 s, Side side,,, uint64 lots) = book.getVolOrder(id);
        return (maker, s, side, lots);
    }

    function test_bidsQueueHighVolFirst() public {
        // Alice holds tokens to sell back.
        _volAsk(mm, 500_000, 1, 10);
        _buy(alice, call110, 10, 500);

        _volBid(carol, 450_000, 1000, 5); // 1 694.13 -> 338 ticks
        _volBid(carol, 480_000, 1000, 5);
        (uint64 filled, uint256 premium,) = _sellFull(alice, 5, 1);
        assertEq(filled, 5);
        // 48% first: price between the 45% and 50% marks
        assertGt(premium, 338 * 50_000 * 5);
        assertLt(premium, 414 * 50_000 * 5);
    }

    function _sellFull(address who, uint64 lots, uint32 minTicks) internal returns (uint64, uint256, uint256) {
        vm.prank(who);
        return book.sell(call110, lots, minTicks, 0, NO_DEADLINE);
    }

    function test_priceBookWinsTies() public {
        _ask(carol, call110, 415, 4); // same price as the 50% vol ask
        _volAsk(mm, 500_000, 1, 10);
        _ask(carol, call110, 416, 10);
        assertEq(_buy(alice, call110, 10, 500), 10);
        assertEq(clr.shortOf(carol, call110), 4); // tie went to the price order
        assertEq(clr.shortOf(mm, call110), 6); // then vol beat 416
    }

    function test_vaultYieldsToEqualVolOrder() public {
        _fundVault(wbtc, 1e8);
        vault.setQuote(call110, Side.Sell, 415, 10);
        _volAsk(mm, 500_000, 1, 4);
        assertEq(_buy(alice, call110, 10, 500), 10);
        assertEq(clr.shortOf(mm, call110), 4);
        assertEq(clr.shortOf(address(vault), call110), 6);
    }

    function test_bidCapAndAskFloor() public {
        _volAsk(mm, 300_000, 450, 5); // 30% would be 135 ticks: floored at 450
        assertEq(_tryBuy(alice, 5, 440), 0);
        assertEq(_buy(alice, call110, 5, 450), 5);

        _volBid(carol, 800_000, 300, 5); // 80% would be 900 ticks: capped at 300
        (uint64 filled, uint256 premium,) = _sellFull(alice, 5, 1);
        assertEq(filled, 5);
        assertEq(premium, 300 * 50_000 * 5);
    }

    function test_bidReservesAtCapAndReleasesRest() public {
        uint256 freeBefore = clr.freeBalance(carol, address(usdc));
        uint64 id = _volBid(carol, 500_000, 600, 5);
        uint256 reserved = freeBefore - clr.freeBalance(carol, address(usdc));
        assertGe(reserved, 600 * 50_000 * 5);

        // Fill at 414 (50%, rounded down for a bid); the cap's excess comes back.
        _volAsk(mm, 400_000, 1, 5);
        _buy(alice, call110, 5, 1000); // alice takes mm's ask first, then sells back to carol
        (uint64 filled, uint256 premium,) = _sellFull(alice, 5, 1);
        assertEq(filled, 5);
        assertEq(premium, 414 * 50_000 * 5);
        (address maker,,,) = _volLeft(id);
        assertEq(maker, address(0), "filled and removed");
        assertEq(clr.reservedBalance(carol, address(usdc)), 0);
    }

    function test_selfTradeSkipped() public {
        _volAsk(mm, 500_000, 1, 5);
        _volAsk(carol, 550_000, 1, 5);
        assertEq(_buy(mm, call110, 5, 1000), 5);
        assertEq(clr.shortOf(carol, call110), 5);
        (address maker,,,) = _volLeft(1);
        assertEq(maker, mm, "mm's own order untouched");
    }

    function test_staleSpotSkipsVolBook() public {
        _volAsk(mm, 500_000, 1, 5);
        vm.warp(block.timestamp + 3 hours);
        assertEq(_tryBuy(alice, 5, 1000), 0);
        vm.prank(admin);
        btcFeed.pushPrice(104_000e8);
        assertGt(_tryBuy(alice, 5, 1000), 0);
    }

    function test_cancelReleasesReserve() public {
        uint64 id = _volAsk(mm, 500_000, 1, 10);
        assertEq(clr.freeBalance(mm, address(wbtc)), 2e8 - 10 * 1e6);
        vm.prank(mm);
        book.cancel(id);
        assertEq(clr.freeBalance(mm, address(wbtc)), 2e8);
        assertEq(book.volOrderCount(keccak256(abi.encode(call110, Side.Sell))), 0);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.UnknownOrder.selector, id));
        book.cancel(id);
    }

    function test_onlyOwnerCancels() public {
        uint64 id = _volAsk(mm, 500_000, 1, 10);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.NotOrderOwner.selector, id));
        book.cancel(id);
    }

    function test_purgedAfterCutoff() public {
        _volAsk(mm, 500_000, 1, 10);
        _volBid(carol, 400_000, 500, 10);
        vm.warp(FRI_NOV06 - 10 minutes);
        assertEq(book.purgeExpired(call110, 10), 2);
        assertEq(clr.freeBalance(mm, address(wbtc)), 2e8);
        assertEq(clr.reservedBalance(carol, address(usdc)), 0);
    }

    function test_validation() public {
        vm.startPrank(mm);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.InvalidVol.selector, uint32(5_000)));
        book.placeVolOrder(call110, Side.Sell, 5_000, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.InvalidPrice.selector, uint32(0)));
        book.placeVolOrder(call110, Side.Buy, 500_000, 0, 1);
        vm.stopPrank();

        vm.prank(admin);
        book.setVolPricing(IOracleAdapter(address(oracle)), 2 hours, 1);
        _volAsk(mm, 500_000, 1, 1);
        vm.prank(mm);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.TooManyVolOrders.selector, call110, Side.Sell));
        book.placeVolOrder(call110, Side.Sell, 500_000, 1, 1);
    }

    function test_gasProfile() public {
        _volAsk(carol, 600_000, 1, 1); // warms the vol book
        vm.startPrank(mm);
        uint256 g = gasleft();
        book.placeVolOrder(call110, Side.Sell, 500_000, 1, 10);
        emit log_named_uint("placeVolOrder ask, head of 2", g - gasleft());
        vm.stopPrank();
        vm.prank(alice);
        g = gasleft();
        book.buy(call110, 5, 1000, 0, NO_DEADLINE);
        emit log_named_uint("buy against a vol order (1 BS run)", g - gasleft());
    }

    function _makerFee(uint256 ticks, uint256 lots) internal pure returns (uint256) {
        uint256 premium = ticks * 50_000 * lots;
        // taker fee = min(0.03% of spot notional, 12.5% of premium); maker pays half
        uint256 notionalFee = uint256(104_000e6) * 300 / 1e6 * lots / 100;
        uint256 capFee = premium * 125_000 / 1e6;
        uint256 taker = notionalFee < capFee ? notionalFee : capFee;
        return taker / 2;
    }
}
