// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TradingBase} from "./TradingBase.t.sol";
import {IOrderBook} from "../src/interfaces/IOrderBook.sol";
import {IClearing} from "../src/interfaces/IClearing.sol";
import {Side} from "../src/types/DerstarTypes.sol";

contract TradingTest is TradingBase {
    // ------------------------------------------------------------ buy

    /// Spec example: 10 lots (0.1 BTC) of the 110k call at 1 250 USDC, spot 104 000.
    function test_buyFromAsk_specExample() public {
        _deposit(mm, wbtc, 1e8);
        _ask(mm, call110, 250, 10);
        assertEq(clr.reservedBalance(mm, address(wbtc)), 0.1e8);

        uint256 before = usdc.balanceOf(alice);
        assertEq(_buy(alice, call110, 10, 250), 10);

        // 0.66 USDC per lot: 0.06% of the 110 000 strike per contract, carried by each long lot
        assertEq(clr.reservePerLot(call110), 0.66e6);
        assertEq(
            before - usdc.balanceOf(alice), 128.12e6 + 6.6e6, "alice pays premium + taker fee + settlement reserve"
        );
        assertEq(token.balanceOf(alice, call110), 10);
        assertEq(clr.shortOf(mm, call110), 10);
        assertEq(clr.freeBalance(mm, address(usdc)), 123.44e6, "maker gets premium - maker fee");
        assertEq(clr.freeBalance(fees, address(usdc)), 4.68e6);
        assertEq(clr.reservedBalance(mm, address(wbtc)), 0);
        assertEq(clr.freeBalance(mm, address(wbtc)), 0.9e8);
        _assertBacked(call110);
    }

    /// Cheap options: both sides pay at most 12.5% of the premium, the maker no longer half of it.
    function test_premiumCapAppliesToEachSide() public {
        _deposit(mm, wbtc, 1e8);
        _ask(mm, call110, 1, 10); // 5 USDC per contract: premium 0.5 USDC for 0.1 BTC
        _buy(alice, call110, 10, 1);
        assertEq(clr.freeBalance(mm, address(usdc)), 0.5e6 - 0.0625e6, "maker: 12.5% of premium");
        assertEq(clr.freeBalance(fees, address(usdc)), 2 * 0.0625e6, "taker: 12.5% of premium");
    }

    function test_bidReservesPremiumFeeCapAndSettlementReserve() public {
        _deposit(mm, usdc, 1_000e6);
        _bid(mm, call110, 250, 10);
        // 125 premium + 12.5% worst-case maker fee + 10 lots x 0.66 settlement reserve
        assertEq(clr.reservedBalance(mm, address(usdc)), 125e6 + 15.625e6 + 6.6e6);
    }

    function test_buy_respectsLimitAndMinLots() public {
        _deposit(mm, wbtc, 1e8);
        _ask(mm, call110, 250, 5);
        _ask(mm, call110, 260, 5);

        assertEq(_buy(alice, call110, 10, 255), 5, "stops at the limit");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.BelowMinLots.selector, 0, 3));
        book.buy(call110, 3, 255, 3, NO_DEADLINE);
    }

    function test_priceTimePriority() public {
        _deposit(mm, wbtc, 1e8);
        _deposit(carol, wbtc, 1e8);
        _ask(mm, call110, 250, 5);
        _ask(carol, call110, 250, 5);
        _ask(carol, call110, 245, 2);

        _buy(alice, call110, 4, 250);
        assertEq(clr.shortOf(carol, call110), 2, "better price first");
        assertEq(clr.shortOf(mm, call110), 2, "then the earlier order at 250");
        _buy(alice, call110, 5, 250);
        assertEq(clr.shortOf(mm, call110), 5);
        assertEq(clr.shortOf(carol, call110), 4);
    }

    function test_deadline() public {
        vm.warp(NOW + 10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.Expired.selector, uint64(NOW)));
        book.buy(call110, 1, 250, 0, uint64(NOW));
    }

    // ------------------------------------------------------------ sell

    function test_sellToClose_intoBidOfShortMaker() public {
        _deposit(mm, wbtc, 1e8);
        _deposit(mm, usdc, 1_000e6);
        _ask(mm, call110, 250, 10);
        _buy(alice, call110, 10, 250);

        // The maker who wrote the call bids to buy it back at 1 900.
        _bid(mm, call110, 380, 10);
        uint256 before = usdc.balanceOf(alice);
        assertEq(_sell(alice, call110, 10, 380), 10);

        // 190 premium - min(3.12, 23.75) taker fee
        assertEq(usdc.balanceOf(alice) - before, 186.88e6 + 6.6e6, "premium - fee, plus the reserve back");
        assertEq(token.balanceOf(alice, call110), 0);
        assertEq(clr.shortOf(mm, call110), 0, "maker covered its short");
        assertEq(token.totalSupply(call110), 0, "open interest is gone");
        assertEq(clr.freeBalance(mm, address(wbtc)), 1e8, "collateral is free again");
        assertEq(clr.reservedBalance(mm, address(usdc)), 0, "fee buffer released");
        _assertBacked(call110);
    }

    function test_sellToOpen_writesPutWithCollateralFromWallet() public {
        _deposit(mm, usdc, 20_000e6);
        _bid(mm, put100, 180, 10); // 900 USDC per contract

        uint256 before = usdc.balanceOf(bob);
        (, uint256 prem, uint256 fee,, uint256 collIn,) = book.preview(put100, Side.Sell, 10, 180, bob);
        assertEq(prem, 90e6);
        assertEq(fee, 3.12e6);
        assertEq(collIn, 10_000e6);

        _sell(bob, put100, 10, 180);
        assertEq(before - usdc.balanceOf(bob), 10_000e6 - 86.88e6, "collateral in, premium - fee out");
        assertEq(clr.shortOf(bob, put100), 10);
        assertEq(token.balanceOf(mm, put100), 10);
        _assertBacked(put100);
    }

    function test_sellPartlyClosesPartlyWrites() public {
        _deposit(mm, wbtc, 1e8);
        _deposit(carol, usdc, 10_000e6);
        _ask(mm, call110, 250, 4);
        _buy(alice, call110, 4, 250);
        _bid(carol, call110, 240, 10);

        uint256 wbtcBefore = wbtc.balanceOf(alice);
        _sell(alice, call110, 10, 240);
        assertEq(token.balanceOf(alice, call110), 0);
        assertEq(clr.shortOf(alice, call110), 6, "6 lots written on top of the 4 closed");
        assertEq(wbtcBefore - wbtc.balanceOf(alice), 0.06e8);
        assertEq(token.balanceOf(carol, call110), 10);
        _assertBacked(call110);
    }

    function test_askBackedByTokensNeedsNoCollateral() public {
        _deposit(mm, wbtc, 1e8);
        _ask(mm, call110, 250, 10);
        _buy(alice, call110, 10, 250);

        _ask(alice, call110, 300, 10);
        assertEq(token.balanceOf(alice, call110), 0, "tokens held by Clearing");
        assertEq(token.balanceOf(address(clr), call110), 10);
        assertEq(clr.freeBalance(alice, address(wbtc)), 0);

        _buy(carol, call110, 10, 300);
        assertEq(token.balanceOf(carol, call110), 10);
        assertEq(clr.shortOf(alice, call110), 0, "alice only closed");
        assertEq(clr.shortOf(mm, call110), 10, "the writer is unchanged");
        _assertBacked(call110);
    }

    function test_writerBuysBackAndGetsCollateral() public {
        _deposit(mm, usdc, 20_000e6);
        _bid(mm, put100, 180, 10);
        _sell(bob, put100, 10, 180);
        assertEq(clr.shortOf(bob, put100), 10);

        _ask(mm, put100, 150, 10); // mm sells the tokens it holds
        uint256 before = usdc.balanceOf(bob);
        _buy(bob, put100, 10, 150);
        // gets 10 000 collateral back, pays 75 + 3.12
        assertEq(usdc.balanceOf(bob) - before, 10_000e6 - 78.12e6);
        assertEq(clr.shortOf(bob, put100), 0);
        assertEq(token.totalSupply(put100), 0);
        _assertBacked(put100);
    }

    // ------------------------------------------------------------ vault

    function test_vaultFillsOnlyWhenStrictlyBetter() public {
        _fundVault(wbtc, 1e8);
        _deposit(mm, wbtc, 1e8);
        _ask(mm, call110, 250, 5);

        vault.setQuote(call110, Side.Sell, 250, 100);
        _buy(alice, call110, 5, 250);
        assertEq(clr.shortOf(mm, call110), 5, "equal price: the book goes first");
        assertEq(clr.shortOf(address(vault), call110), 0);

        _ask(mm, call110, 250, 5);
        vault.setQuote(call110, Side.Sell, 240, 3);
        _buy(alice, call110, 6, 250);
        assertEq(clr.shortOf(address(vault), call110), 3, "vault at 240 first, capped at 3");
        assertEq(clr.shortOf(mm, call110), 8);
        _assertBacked(call110);
    }

    function test_vaultBuysBackOnlyItsShort() public {
        _fundVault(wbtc, 1e8);
        _fundVault(usdc, 10_000e6);
        vault.setQuote(call110, Side.Sell, 250, 100);
        _buy(alice, call110, 10, 260);
        assertEq(clr.shortOf(address(vault), call110), 10);

        vault.setQuote(call110, Side.Buy, 230, 100);
        uint256 before = usdc.balanceOf(alice);
        assertEq(_sell(alice, call110, 10, 230), 10);
        assertEq(usdc.balanceOf(alice) - before, 115e6 - 3.12e6 + 6.6e6);
        assertEq(clr.shortOf(address(vault), call110), 0);
        assertEq(token.totalSupply(call110), 0);

        // Nothing left to buy back: the vault bid disappears.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.BelowMinLots.selector, 0, 0));
        book.sell(call110, 1, 1, 0, NO_DEADLINE);
    }

    // ------------------------------------------------------------ makers

    function test_postOnly() public {
        _deposit(mm, wbtc, 1e8);
        _deposit(carol, usdc, 10_000e6);
        _ask(mm, call110, 250, 5);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.WouldCross.selector, uint32(250), uint32(250)));
        book.placeOrder(call110, Side.Buy, 250, 1);
        _bid(carol, call110, 249, 1);
    }

    function test_cancelReturnsEverything() public {
        _deposit(mm, wbtc, 1e8);
        _deposit(mm, usdc, 1_000e6);
        uint64 a = _ask(mm, call110, 250, 10);
        uint64 b = _bid(mm, call110, 200, 10);
        assertGt(clr.reservedBalance(mm, address(usdc)), 100e6);

        vm.startPrank(mm);
        book.cancel(a);
        book.cancel(b);
        vm.stopPrank();
        assertEq(clr.reservedBalance(mm, address(wbtc)), 0);
        assertEq(clr.reservedBalance(mm, address(usdc)), 0);
        assertEq(clr.freeBalance(mm, address(wbtc)), 1e8);
        assertEq(clr.freeBalance(mm, address(usdc)), 1_000e6);
        (uint32 bid,, uint32 ask,) = book.best(call110);
        assertEq(bid, 0);
        assertEq(ask, 0);
    }

    function test_onlyOwnerCancels() public {
        _deposit(mm, wbtc, 1e8);
        uint64 a = _ask(mm, call110, 250, 10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.NotOrderOwner.selector, a));
        book.cancel(a);
    }

    function test_replaceMovesPrice() public {
        _deposit(mm, wbtc, 1e8);
        uint64 a = _ask(mm, call110, 250, 10);
        vm.prank(mm);
        uint64 b = book.replace(a, 240, 8);
        (address maker,,,, uint64 left) = book.getOrder(a);
        assertEq(maker, address(0));
        (,,, uint32 price, uint64 lots) = book.getOrder(b);
        assertEq(price, 240);
        assertEq(lots, 8);
        assertEq(clr.reservedBalance(mm, address(wbtc)), 0.08e8);
        left;
    }

    function test_insufficientCollateralReverts() public {
        _deposit(mm, wbtc, 0.05e8);
        vm.prank(mm);
        vm.expectRevert(
            abi.encodeWithSelector(IClearing.InsufficientBalance.selector, mm, address(wbtc), 0.1e8, 0.05e8)
        );
        book.placeOrder(call110, Side.Sell, 250, 10);
    }

    function test_selfTradeIsSkipped() public {
        _deposit(mm, wbtc, 1e8);
        _deposit(carol, wbtc, 1e8);
        _ask(mm, call110, 250, 5);
        _ask(carol, call110, 260, 5);
        assertEq(_buy(mm, call110, 5, 260), 5);
        assertEq(clr.shortOf(carol, call110), 5, "filled against carol, not itself");
        (,, uint32 ask, uint64 lots) = book.best(call110);
        assertEq(ask, 250);
        assertEq(lots, 5);
    }

    function test_depthAndBest() public {
        _deposit(mm, wbtc, 1e8);
        _deposit(mm, usdc, 10_000e6);
        _ask(mm, call110, 250, 1);
        _ask(mm, call110, 300, 2);
        _ask(mm, call110, 5000, 3); // across bitmap words
        _bid(mm, call110, 200, 4);
        _bid(mm, call110, 3, 5);

        (uint32[] memory p, uint64[] memory l) = book.depth(call110, Side.Sell, 5);
        assertEq(p.length, 3);
        assertEq(p[0], 250);
        assertEq(p[2], 5000);
        assertEq(l[2], 3);
        (p, l) = book.depth(call110, Side.Buy, 1);
        assertEq(p.length, 1);
        assertEq(p[0], 200);
        (uint32 bid, uint64 bidLots, uint32 ask, uint64 askLots) = book.best(call110);
        assertEq(bid, 200);
        assertEq(bidLots, 4);
        assertEq(ask, 250);
        assertEq(askLots, 1);
    }

    // ------------------------------------------------------------ expiry and admin

    function test_cutoffStopsTradingButNotCancels() public {
        _deposit(mm, wbtc, 1e8);
        uint64 a = _ask(mm, call110, 250, 10);
        _ask(mm, call110, 260, 10);
        vm.warp(FRI_NOV06 - 30 minutes);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.SeriesNotTradable.selector, call110));
        book.buy(call110, 1, 250, 0, NO_DEADLINE);

        vm.prank(mm);
        book.cancel(a);
        assertEq(book.purgeExpired(call110, 10), 1);
        assertEq(clr.freeBalance(mm, address(wbtc)), 1e8);
    }

    function test_purgeOnlyAfterCutoff() public {
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.StillTradable.selector, call110));
        book.purgeExpired(call110, 10);
    }

    function test_pauseStopsTradesNotWithdrawals() public {
        _deposit(mm, wbtc, 1e8);
        _ask(mm, call110, 250, 10);
        vm.prank(admin);
        clr.pauseTrading(true);

        vm.prank(alice);
        vm.expectRevert(IClearing.TradingIsPaused.selector);
        book.buy(call110, 1, 250, 0, NO_DEADLINE);

        vm.prank(mm);
        clr.withdraw(address(wbtc), 0.9e8);
        assertEq(wbtc.balanceOf(mm), 9.9e8);
    }

    function test_onlyBookCallsClearing() public {
        vm.expectRevert(IClearing.NotOrderBook.selector);
        clr.reserveAsk(mm, 1, call110, 1);
    }

    function test_orderBookIsSetOnce() public {
        vm.prank(admin);
        vm.expectRevert(IClearing.OrderBookAlreadySet.selector);
        clr.setOrderBook(alice);
    }

    function test_netPositionsAfterPlainTransfer() public {
        _deposit(mm, wbtc, 1e8);
        _ask(mm, call110, 250, 10);
        _buy(alice, call110, 10, 250);
        // alice gifts the options to the writer
        vm.prank(alice);
        token.safeTransferFrom(alice, mm, call110, 4, "");

        vm.prank(mm);
        clr.netPositions(call110);
        assertEq(clr.shortOf(mm, call110), 6);
        assertEq(token.balanceOf(mm, call110), 0);
        assertEq(clr.freeBalance(mm, address(wbtc)), 0.94e8);
        _assertBacked(call110);
    }
}
