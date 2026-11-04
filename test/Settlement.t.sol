// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TradingBase} from "./TradingBase.t.sol";
import {IClearing} from "../src/interfaces/IClearing.sol";
import {IOrderBook} from "../src/interfaces/IOrderBook.sol";
import {SeriesState} from "../src/types/DerstarTypes.sol";

contract SettlementTest is TradingBase {
    uint80 internal constant R1 = (uint80(1) << 64) | 1;

    /// Sets a flat settlement price for Nov 6 and finalizes it.
    function _expireAt(int256 price) internal {
        vm.warp(FRI_NOV06 - 1 hours);
        vm.prank(admin);
        btcFeed.pushPrice(price * 1e8);
        vm.warp(FRI_NOV06);
        oracle.finalize(BTC, FRI_NOV06, R1 + 1); // round 1 was the setUp price
    }

    function _writeCallToAlice() internal {
        _deposit(mm, wbtc, 1e8);
        _ask(mm, call110, 250, 10);
        _buy(alice, call110, 10, 250);
    }

    function test_callInTheMoney() public {
        _writeCallToAlice();
        _expireAt(115_000);
        assertEq(clr.settleExpiry(BTC, FRI_NOV06), 12);
        assertEq(uint8(registry.stateOf(call110)), uint8(SeriesState.Settled));

        // (115k - 110k) / 115k of 0.01 BTC per lot, rounded down
        assertEq(clr.payoffPerLot(call110), 43_478);
        // Settlement fee: 0.015% of 115 000 per contract = 0.1725 USDC per lot, from the 0.66 reserve
        assertEq(clr.settleFeePerLot(call110), 0.1725e6);
        uint256 before = wbtc.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        clr.redeem(call110, 10);
        assertEq(wbtc.balanceOf(alice) - before, 434_780);
        assertEq(usdc.balanceOf(alice) - usdcBefore, 10 * (0.66e6 - 0.1725e6), "reserve minus fee back");

        // The writer pays the same fee in the underlying: 0.015% of 0.01 BTC = 150 sat per lot.
        assertEq(clr.shortSettleFeePerLot(call110), 150);
        before = wbtc.balanceOf(mm);
        vm.prank(mm);
        clr.claimShort(call110);
        assertEq(wbtc.balanceOf(mm) - before, 10 * (1e6 - 43_478 - 150), "leftover collateral to the wallet");
        assertEq(clr.freeBalance(mm, address(wbtc)), 0.9e8, "free balance untouched");
        assertEq(clr.freeBalance(fees, address(wbtc)), 1_500);
        assertEq(
            wbtc.balanceOf(address(clr)),
            clr.freeBalance(mm, address(wbtc)) + clr.freeBalance(fees, address(wbtc)),
            "nothing left behind"
        );
    }

    function test_callOutOfTheMoney() public {
        _writeCallToAlice();
        _expireAt(105_000);
        clr.settleSeries(call110);
        assertEq(clr.payoffPerLot(call110), 0);
        vm.prank(alice);
        clr.redeem(call110, 10);
        assertEq(token.balanceOf(alice, call110), 0);
        uint256 before = wbtc.balanceOf(mm);
        clr.claimShortFor(mm, call110);
        assertEq(wbtc.balanceOf(mm) - before, 10 * (1e6 - 150), "collateral minus the fee, to the wallet");
        assertEq(clr.freeBalance(fees, address(usdc)) - 4.68e6, 10 * clr.settleFeePerLot(call110), "buyer paid too");
    }

    function test_putInTheMoneyPaysUsdc() public {
        _deposit(mm, usdc, 20_000e6);
        _bid(mm, put100, 180, 10);
        _sell(bob, put100, 10, 180);
        _expireAt(95_000);
        clr.settleSeries(put100);
        assertEq(clr.payoffPerLot(put100), 50e6); // 5 000 USDC per contract / 100 lots

        address[] memory holders = new address[](1);
        holders[0] = mm;
        uint256 before = usdc.balanceOf(mm);
        clr.redeemFor(holders, put100);
        // payout + reserve (0.60) minus fee (0.015% of 95 000 = 0.1425) per lot
        assertEq(usdc.balanceOf(mm) - before, 500e6 + 10 * (0.6e6 - 0.1425e6));

        before = usdc.balanceOf(bob);
        clr.claimShortFor(bob, put100);
        assertEq(usdc.balanceOf(bob) - before, 10_000e6 - 500e6 - 10 * 0.1425e6);
        assertEq(clr.freeBalance(bob, address(usdc)), 0);
    }

    function test_needsFinalPriceAndExpiry() public {
        _writeCallToAlice();
        vm.expectRevert(abi.encodeWithSelector(IClearing.NotExpired.selector, call110));
        clr.settleSeries(call110);
        vm.warp(FRI_NOV06);
        vm.expectRevert(abi.encodeWithSelector(IClearing.PriceNotFinal.selector, call110));
        clr.settleSeries(call110);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IClearing.NotSettled.selector, call110));
        clr.redeem(call110, 10);
    }

    function test_tokensUnderAskAreRedeemedAfterCancel() public {
        _writeCallToAlice();
        uint64 id = _ask(alice, call110, 400, 10); // alice tries to sell, nobody buys
        _expireAt(115_000);
        clr.settleSeries(call110);

        vm.prank(alice);
        book.cancel(id);
        vm.prank(alice);
        clr.redeem(call110, 10);
        assertEq(token.balanceOf(alice, call110), 0);
    }

    function test_noTradingAfterExpiry() public {
        _writeCallToAlice();
        _expireAt(115_000);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.SeriesNotTradable.selector, call110));
        book.sell(call110, 10, 1, 0, NO_DEADLINE);
    }

    /// Payout to holders + collateral back to writers == collateral locked, for any price.
    function testFuzz_settlementConservesCollateral(uint256 price, uint64 lots) public {
        price = bound(price, 1_000, 400_000);
        lots = uint64(bound(lots, 1, 100));
        _deposit(mm, wbtc, 1e8);
        _deposit(mm, usdc, 200_000e6);
        _ask(mm, call110, 250, lots);
        _ask(mm, put100, 250, lots);
        _buy(alice, call110, lots, 250);
        _buy(alice, put100, lots, 250);

        _expireAt(int256(price));
        clr.settleExpiry(BTC, FRI_NOV06);
        vm.startPrank(alice);
        clr.redeem(call110, lots);
        clr.redeem(put100, lots);
        vm.stopPrank();
        clr.claimShortFor(mm, call110);
        clr.claimShortFor(mm, put100);

        uint256 wbtcOut = wbtc.balanceOf(alice) - 10e8 + wbtc.balanceOf(mm) - 9e8;
        uint256 kept = clr.freeBalance(mm, address(wbtc)) + clr.freeBalance(fees, address(wbtc));
        assertEq(wbtcOut + kept, 1e8, "wbtc conserved");
        assertEq(wbtc.balanceOf(address(clr)), kept);
        assertEq(
            usdc.balanceOf(address(clr)),
            clr.freeBalance(mm, address(usdc)) + clr.freeBalance(fees, address(usdc)),
            "usdc: only free balances remain"
        );
        assertEq(clr.totalShort(call110), 0);
        assertEq(token.totalSupply(call110), 0);
    }

    function test_settlementFeeCappedByReserve() public {
        _writeCallToAlice();
        _expireAt(500_000); // 0.015% of 500 000 = 0.75 per lot, above the 0.66 reserve
        clr.settleSeries(call110);
        assertEq(clr.settleFeePerLot(call110), clr.reservePerLot(call110));
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        clr.redeem(call110, 10);
        assertEq(usdc.balanceOf(alice), before, "whole reserve went to the fee");
    }

    function test_feeEvenWithoutPayout() public {
        _writeCallToAlice();
        _expireAt(100_000);
        clr.settleSeries(call110);
        assertEq(clr.payoffPerLot(call110), 0);
        uint256 feesBefore = clr.freeBalance(fees, address(usdc));
        vm.prank(alice);
        clr.redeem(call110, 10);
        assertEq(clr.freeBalance(fees, address(usdc)) - feesBefore, 10 * 0.15e6);
    }
}
