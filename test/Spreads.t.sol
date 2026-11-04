// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TradingBase} from "./TradingBase.t.sol";
import {IClearing} from "../src/interfaces/IClearing.sol";
import {SeriesId} from "../src/libraries/SeriesId.sol";
import {Series, OptionType, Side} from "../src/types/DerstarTypes.sol";

/// Debit spreads: a long leg pledged in Clearing backs the short leg, so the short needs no
/// collateral. Carol buys the 108k call and sells the 110k call; bob buys the 110k call.
contract SpreadsTest is TradingBase {
    uint80 internal constant R1 = (uint80(1) << 64) | 1;
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

    function _expireAt(int256 price) internal {
        vm.warp(FRI_NOV06 - 1 hours);
        vm.prank(admin);
        btcFeed.pushPrice(price * 1e8);
        vm.warp(FRI_NOV06);
        oracle.finalize(BTC, FRI_NOV06, R1 + 1);
        clr.settleExpiry(BTC, FRI_NOV06);
    }

    /// Carol: long 10 lots of 108k, short 10 lots of 110k against them.
    function _bullCallSpread() internal {
        _ask(mm, call108, 600, 10);
        assertEq(_buy(carol, call108, 10, 600), 10);
        vm.prank(carol);
        clr.pledge(call108, call110, 10);
        _bid(bob, call110, 300, 10);
        uint256 btcBefore = wbtc.balanceOf(carol);
        assertEq(_sell(carol, call110, 10, 300), 10);
        assertEq(wbtc.balanceOf(carol), btcBefore, "no collateral for the short leg");
    }

    function test_shortLegNeedsNoCollateral() public {
        _bullCallSpread();
        assertEq(clr.shortOf(carol, call110), 10);
        assertEq(clr.coveredShort(carol, call110), 10);
        assertEq(clr.coverCredit(carol, call110), 0);
        assertEq(token.balanceOf(address(clr), call108), 10, "pledged long sits in Clearing");
        _assertBacked(call108);
        _assertBacked(call110);
    }

    function test_previewShowsNoCollateral() public {
        _ask(mm, call108, 600, 10);
        _buy(carol, call108, 10, 600);
        vm.prank(carol);
        clr.pledge(call108, call110, 6);
        _bid(bob, call110, 300, 10);
        (,,,, uint256 collIn,) = book.preview(call110, Side.Sell, 10, 1, carol);
        assertEq(collIn, 4 * 1e6, "only the 4 uncovered lots need collateral");
    }

    function test_bothLegsInTheMoney() public {
        _bullCallSpread();
        _expireAt(115_000);
        uint256 p108 = clr.payoffPerLot(call108);
        uint256 p110 = clr.payoffPerLot(call110);
        vm.prank(bob);
        clr.redeem(call110, 10);
        assertEq(wbtc.balanceOf(bob), 10e8 + 10 * p110);

        uint256 before = wbtc.balanceOf(carol);
        clr.claimShortFor(carol, call110);
        assertEq(wbtc.balanceOf(carol) - before, 10 * (p108 - p110), "the spread's width");
        assertEq(token.balanceOf(address(clr), call108), 0, "pledge cashed in");

        clr.claimShortFor(mm, call108);
        // Every satoshi accounted for: what is left in Clearing is exactly what people can withdraw.
        assertEq(
            wbtc.balanceOf(address(clr)),
            clr.freeBalance(mm, address(wbtc)) + clr.freeBalance(carol, address(wbtc))
                + clr.freeBalance(fees, address(wbtc))
        );
    }

    function test_onlyLongLegInTheMoney() public {
        _bullCallSpread();
        _expireAt(109_000);
        assertEq(clr.payoffPerLot(call110), 0);
        uint256 before = wbtc.balanceOf(carol);
        clr.claimShortFor(carol, call110);
        assertEq(wbtc.balanceOf(carol) - before, 10 * clr.payoffPerLot(call108));
    }

    function test_claimWaitsForCoverSettlement() public {
        _bullCallSpread();
        vm.warp(FRI_NOV06 - 1 hours);
        vm.prank(admin);
        btcFeed.pushPrice(115_000e8);
        vm.warp(FRI_NOV06);
        oracle.finalize(BTC, FRI_NOV06, R1 + 1);
        clr.settleSeries(call110);
        vm.expectRevert(abi.encodeWithSelector(IClearing.NotSettled.selector, call108));
        clr.claimShortFor(carol, call110);
    }

    function test_buyingBackReturnsCreditThenUnpledge() public {
        _bullCallSpread();
        _ask(mm, call110, 320, 10);
        assertEq(_buy(carol, call110, 10, 320), 10);
        assertEq(clr.shortOf(carol, call110), 0);
        assertEq(clr.coveredShort(carol, call110), 0);
        assertEq(clr.coverCredit(carol, call110), 10);
        assertEq(clr.freeBalance(carol, address(wbtc)), 0, "a covered short frees no collateral");

        vm.prank(carol);
        clr.unpledge(call110, 10);
        assertEq(token.balanceOf(carol, call108), 10);
        vm.prank(carol);
        vm.expectRevert(IClearing.InvalidAmount.selector);
        clr.unpledge(call110, 1);
    }

    function test_plainLotsCloseFirst() public {
        _ask(mm, call108, 600, 4);
        _buy(carol, call108, 4, 600);
        vm.prank(carol);
        clr.pledge(call108, call110, 4);
        _deposit(carol, wbtc, 1e8);
        _bid(bob, call110, 300, 10);
        // 4 covered, 6 against collateral pulled from the wallet.
        uint256 before = wbtc.balanceOf(carol);
        _sell(carol, call110, 10, 300);
        assertEq(before - wbtc.balanceOf(carol), 6 * 1e6);
        _ask(mm, call110, 320, 6);
        _buy(carol, call110, 6, 320);
        assertEq(clr.coveredShort(carol, call110), 4, "collateral-backed lots closed first");
        assertEq(wbtc.balanceOf(carol), before, "their collateral came back");
    }

    function test_bearPutSpreadInUsdc() public {
        // Carol buys the 104k put and sells the 102k put against it.
        uint256 put104 = SeriesId.encode(Series(BTC, OptionType.Put, FRI_NOV06, 104000));
        _ask(mm, put104, 500, 10);
        _buy(carol, put104, 10, 500);
        vm.prank(carol);
        clr.pledge(put104, put102, 10);
        _bid(bob, put102, 200, 10);
        uint256 before = usdc.balanceOf(carol);
        _sell(carol, put102, 10, 200);
        assertGt(usdc.balanceOf(carol), before, "premium in, no collateral out");

        _expireAt(100_000);
        before = usdc.balanceOf(carol);
        clr.claimShortFor(carol, put102);
        // (104k - 100k) - (102k - 100k) = 2 000 USDC per contract, plus both legs' reserves minus their fees
        uint256 reserves = 10 * (clr.reservePerLot(put102) - clr.settleFeePerLot(put102)) + 10
            * (clr.reservePerLot(put104) - clr.settleFeePerLot(put104));
        assertEq(usdc.balanceOf(carol) - before, 10 * 20e6 + reserves);
    }

    function test_rejectsCoversThatDoNotCover() public {
        _ask(mm, call110, 300, 10);
        _buy(carol, call110, 10, 300);
        vm.startPrank(carol);
        // A higher-strike call cannot back a lower-strike call.
        vm.expectRevert(abi.encodeWithSelector(IClearing.InvalidCover.selector, call110, call108));
        clr.pledge(call110, call108, 10);
        vm.expectRevert(abi.encodeWithSelector(IClearing.InvalidCover.selector, call110, put100));
        clr.pledge(call110, put100, 10);
        vm.expectRevert(abi.encodeWithSelector(IClearing.InvalidCover.selector, call110, call110));
        clr.pledge(call110, call110, 10);
        vm.stopPrank();
    }

    function test_unusedPledgeIsCashedInAtClaim() public {
        _ask(mm, call108, 600, 10);
        _buy(carol, call108, 10, 600);
        vm.prank(carol);
        clr.pledge(call108, call110, 10);
        _expireAt(115_000);
        uint256 before = wbtc.balanceOf(carol);
        clr.claimShortFor(carol, call110);
        assertEq(wbtc.balanceOf(carol) - before, 10 * clr.payoffPerLot(call108));
    }
}
