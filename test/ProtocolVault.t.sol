// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TradingBase} from "./TradingBase.t.sol";
import {ProtocolVault} from "../src/core/ProtocolVault.sol";
import {IvFeed} from "../src/core/IvFeed.sol";
import {IIvFeed} from "../src/interfaces/IIvFeed.sol";
import {IClearing} from "../src/interfaces/IClearing.sol";
import {ISeriesRegistry} from "../src/interfaces/ISeriesRegistry.sol";
import {IOracleAdapter} from "../src/interfaces/IOracleAdapter.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {OptionType, Side, Series} from "../src/types/DerstarTypes.sol";
import {SeriesId} from "../src/libraries/SeriesId.sol";

contract ProtocolVaultTest is TradingBase {
    IvFeed internal ivFeed;
    ProtocolVault internal callVault; // BTC calls, WBTC
    ProtocolVault internal putVault; // BTC puts, USDC

    address internal lp = makeAddr("lp");
    address internal lp2 = makeAddr("lp2");

    function _wire() internal override {
        super._wire();
        ivFeed = new IvFeed(admin, keeper);
        callVault = new ProtocolVault(
            "Derstar BTC Call Vault",
            "dsBTCc",
            admin,
            IClearing(address(clr)),
            ISeriesRegistry(address(registry)),
            IOracleAdapter(address(oracle)),
            ivFeed,
            address(wbtc),
            OptionType.Call,
            BTC
        );
        putVault = new ProtocolVault(
            "Derstar Put Vault",
            "dsPUT",
            admin,
            IClearing(address(clr)),
            ISeriesRegistry(address(registry)),
            IOracleAdapter(address(oracle)),
            ivFeed,
            address(usdc),
            OptionType.Put,
            0
        );
        vm.startPrank(admin);
        callVault.setServes(BTC, true);
        putVault.setServes(BTC, true);
        clr.setVault(address(callVault), true);
        clr.setVault(address(putVault), true);
        book.setVaultFor(BTC, uint8(OptionType.Call), address(callVault));
        book.setVaultFor(BTC, uint8(OptionType.Put), address(putVault));
        vm.stopPrank();
    }

    function setUp() public override {
        super.setUp();
        _pushVol(500_000);
        _give(lp, wbtc, 10e8);
        _give(lp2, wbtc, 10e8);
        _give(lp, usdc, 1_000_000e6);
        vm.startPrank(lp);
        wbtc.approve(address(callVault), type(uint256).max);
        usdc.approve(address(putVault), type(uint256).max);
        vm.stopPrank();
        vm.prank(lp2);
        wbtc.approve(address(callVault), type(uint256).max);
    }

    function _pushVol(uint32 atm) internal {
        uint64[] memory e = new uint64[](1);
        e[0] = FRI_NOV06;
        IIvFeed.Smile[] memory s = new IIvFeed.Smile[](1);
        s[0] = IIvFeed.Smile(atm, 0, 0, 0);
        vm.prank(keeper);
        ivFeed.push(BTC, e, s);
    }

    function _seedCallVault(uint256 amount) internal {
        vm.prank(lp);
        callVault.requestDeposit(amount);
        callVault.rollEpoch(0);
        vm.prank(lp);
        callVault.claim();
    }

    function _expireAt(int256 price) internal {
        vm.warp(FRI_NOV06 - 1 hours);
        vm.prank(admin);
        btcFeed.pushPrice(price * 1e8);
        vm.warp(FRI_NOV06);
        (uint80 latest,,,,) = btcFeed.latestRoundData();
        oracle.finalize(BTC, FRI_NOV06, latest);
        clr.settleExpiry(BTC, FRI_NOV06);
    }

    // ---------------------------------------------------------------- quotes

    function test_askIsFairPlusSpread() public {
        _seedCallVault(5e8);
        // BS fair at 104k spot, 110k strike, 16.8 days, 50% vol: $2 071.90.
        // 10 lots: 5% spread, utilisation 1% adds ~0: 2 175.50 / 5 -> 436 ticks.
        (uint32 ask, uint64 avail) = callVault.quote(call110, Side.Sell, 10);
        assertEq(ask, 436);
        assertEq(avail, 10);
        // 200 lots: utilisation 20% adds 2000 * 0.2^2 = 80 bps: 2 192.07 / 5 -> 439 ticks.
        (ask,) = callVault.quote(call110, Side.Sell, 200);
        assertEq(ask, 439);
        // With only 1 BTC of collateral the same request is capped at 100 lots (util 10%: 436).
    }

    function test_putAskAndCollateralCap() public {
        vm.prank(lp);
        putVault.requestDeposit(5_000e6);
        putVault.rollEpoch(0);
        _noExpiryCap(putVault);
        // Fair $2 532.27 * 1.05 / 5 -> 532 ticks; 5 000 USDC backs 5 lots of a 100k put.
        (uint32 ask, uint64 avail) = putVault.quote(put100, Side.Sell, 50);
        assertEq(ask, 532);
        assertEq(avail, 5);
    }

    function test_buyFromVaultWritesAgainstItsCollateral() public {
        _seedCallVault(1e8);
        uint256 cost = 436 * 50_000 * 10;
        uint256 before = usdc.balanceOf(alice);
        assertEq(_buy(alice, call110, 10, 500), 10);

        assertEq(token.balanceOf(alice, call110), 10);
        assertEq(clr.shortOf(address(callVault), call110), 10);
        assertEq(clr.freeBalance(address(callVault), address(wbtc)), 1e8 - 10 * 1e6);
        uint256 paid = before - usdc.balanceOf(alice);
        assertGt(paid, cost); // premium plus taker fee
        assertGt(clr.freeBalance(address(callVault), address(usdc)), cost * 9_000 / 10_000);
        _assertBacked(call110);
    }

    function test_bookBeatsVaultOnlyWhenBetter() public {
        _seedCallVault(1e8);
        _deposit(mm, wbtc, 1e8);
        _ask(mm, call110, 430, 4); // better than the vault's 436
        _ask(mm, call110, 440, 4); // worse
        assertEq(_buy(alice, call110, 10, 500), 10);
        assertEq(clr.shortOf(mm, call110), 4);
        assertEq(clr.shortOf(address(callVault), call110), 6);
    }

    function test_callVaultBidIsBoundByUsdcItEarned() public {
        _seedCallVault(1e8);
        _buy(alice, call110, 10, 500);
        (uint32 bid, uint64 avail) = callVault.quote(call110, Side.Buy, 50);
        assertEq(bid, 393); // 2 071.90 * 0.95 / 5
        assertEq(avail, 10);

        // Alice sells 25 back: the vault's only USDC is the premium it took, enough for 10.
        assertEq(_sell(alice, call110, 25, 300), 10);
        assertEq(clr.shortOf(address(callVault), call110), 0);
        assertEq(clr.shortOf(alice, call110), 0); // she delivered her tokens, wrote nothing
        assertEq(token.balanceOf(alice, call110), 0);
        (, avail) = callVault.quote(call110, Side.Buy, 1);
        assertEq(avail, 0);
        assertEq(clr.freeBalance(address(callVault), address(wbtc)), 1e8);
        _assertBacked(call110);
    }

    function test_donatedUsdcLetsCallVaultBidAndCountsInNav() public {
        _seedCallVault(1e8);
        (, uint64 avail) = callVault.quote(call110, Side.Buy, 1);
        assertEq(avail, 0);
        uint256 navBefore = callVault.navUsd();

        _give(admin, usdc, 10_000e6);
        vm.startPrank(admin);
        usdc.approve(address(callVault), 10_000e6);
        callVault.donateUsdc(10_000e6);
        vm.stopPrank();
        assertEq(clr.freeBalance(address(callVault), address(usdc)), 10_000e6);
        assertEq(callVault.navUsd(), navBefore + 10_000e18);
        (uint32 bid, uint64 avail2) = callVault.quote(call110, Side.Buy, 1_000);
        assertGt(bid, 0);
        assertGt(avail2, 0);
    }

    function test_donateIsAdminOnly() public {
        _give(alice, usdc, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(callVault), 1e6);
        vm.expectRevert();
        callVault.donateUsdc(1e6);
        vm.stopPrank();
    }

    function test_putVaultGoesLongAndCashesInAtRoll() public {
        vm.prank(lp);
        putVault.requestDeposit(100_000e6);
        putVault.rollEpoch(0);
        uint256 nav0 = putVault.navUsd();

        // No short to cover: the vault buys put100 outright and holds the tokens.
        (uint32 bid, uint64 avail) = putVault.quote(put100, Side.Buy, 20);
        assertGt(bid, 0);
        assertEq(avail, 20);
        assertEq(_sell(bob, put100, 20, 1), 20);
        assertEq(token.balanceOf(address(putVault), put100), 20);
        assertEq(clr.shortOf(bob, put100), 20);
        // Bought below fair value: NAV goes up by the spread, less the maker fee.
        assertGt(putVault.navUsd(), nav0);

        // Keeper payouts skip vaults; the roll cashes the longs in and redeposits the USDC.
        _expireAt(95_000);
        address[] memory holders = new address[](1);
        holders[0] = address(putVault);
        clr.redeemFor(holders, put100);
        assertEq(token.balanceOf(address(putVault), put100), 20);
        uint256 freeBefore = clr.freeBalance(address(putVault), address(usdc));
        putVault.rollEpoch(FRI_NOV06);
        assertEq(token.balanceOf(address(putVault), put100), 0);
        // payoff plus the long lots' settlement reserve minus the fee (0.60 - 0.1425 per lot)
        assertEq(clr.freeBalance(address(putVault), address(usdc)) - freeBefore, 20 * 50e6 + 20 * (0.6e6 - 0.1425e6));
        assertEq(usdc.balanceOf(address(putVault)), 0, "nothing idle in the vault");
    }

    function test_longCapPerSeries() public {
        vm.prank(lp);
        putVault.requestDeposit(500_000e6);
        putVault.rollEpoch(0);
        vm.prank(admin);
        putVault.setRisk(500, 2_000, 30, 200, 30 minutes, 2 hours, 10_000);
        assertEq(_sell(bob, put100, 50, 1), 30);
        (, uint64 avail) = putVault.quote(put100, Side.Buy, 10);
        assertEq(avail, 0);
    }

    function test_openInterestCap() public {
        _seedCallVault(5e8);
        vm.prank(admin);
        callVault.setRisk(500, 2_000, 30, 200, 1 hours, 2 hours, 10_000);
        assertEq(_buy(alice, call110, 50, 1000), 30);
        (, uint64 avail) = callVault.quote(call110, Side.Sell, 1);
        assertEq(avail, 0);
    }

    function test_noQuoteWhenStaleOrClose() public {
        _seedCallVault(1e8);
        vm.warp(block.timestamp + 16 minutes);
        (, uint64 avail) = callVault.quote(call110, Side.Sell, 10);
        assertEq(avail, 0, "stale vol");

        _pushVol(500_000);
        vm.warp(block.timestamp + 3 hours);
        _pushVol(500_000);
        (, avail) = callVault.quote(call110, Side.Sell, 10);
        assertEq(avail, 0, "stale spot");

        vm.prank(admin);
        btcFeed.pushPrice(104_000e8);
        (, avail) = callVault.quote(call110, Side.Sell, 10);
        assertEq(avail, 10);

        vm.prank(admin);
        callVault.pause(true);
        (, avail) = callVault.quote(call110, Side.Sell, 10);
        assertEq(avail, 0, "paused");
    }

    function test_noQuoteForOtherType() public {
        _seedCallVault(1e8);
        (, uint64 avail) = callVault.quote(put100, Side.Sell, 10);
        assertEq(avail, 0);
    }

    // ---------------------------------------------------------------- NAV and epochs

    function test_bootstrapMintsSharesAtSpot() public {
        _seedCallVault(1e8);
        assertEq(callVault.balanceOf(lp), 104_000e18); // 1 share = $1
        assertEq(callVault.navUsd(), 104_000e18);
        assertEq(callVault.epoch(), 1);
    }

    function test_saleRaisesNavBySpread() public {
        _seedCallVault(1e8);
        _buy(alice, call110, 10, 500);
        uint256 nav = callVault.navUsd();
        // Earned premium (436 ticks, minus maker fee) minus fair value of what was sold.
        assertGt(nav, 104_000e18);
        assertLt(nav, 104_000e18 + 200e18);
    }

    function test_navNeedsFreshVolWhileShort() public {
        _seedCallVault(1e8);
        _buy(alice, call110, 1, 500);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert();
        callVault.navUsd();
    }

    function test_rollNeedsSettledExpiry() public {
        _seedCallVault(1e8);
        _buy(alice, call110, 10, 500);
        vm.expectRevert(abi.encodeWithSelector(ProtocolVault.EpochNotReady.selector, FRI_NOV06));
        callVault.rollEpoch(FRI_NOV06); // not yet expired
        vm.expectRevert(abi.encodeWithSelector(ProtocolVault.EpochNotReady.selector, FRI_OCT30));
        callVault.rollEpoch(FRI_OCT30); // not a listed expiry
        // Expired but not settled
        vm.warp(FRI_NOV06 + 1);
        vm.expectRevert(abi.encodeWithSelector(ProtocolVault.EpochNotReady.selector, FRI_NOV06));
        callVault.rollEpoch(FRI_NOV06);
    }

    function test_fullEpochCycle() public {
        _seedCallVault(1e8);
        _buy(alice, call110, 10, 500);
        uint256 premium = clr.freeBalance(address(callVault), address(usdc));

        // Queued during the week: lp redeems half, lp2 deposits 1 BTC.
        vm.prank(lp);
        callVault.requestRedeem(52_000e18);
        vm.prank(lp2);
        callVault.requestDeposit(1e8);

        _expireAt(115_000); // ITM: payoff 43 478 sats per lot
        callVault.rollEpoch(FRI_NOV06);

        uint256 freeBtc = 1e8 - 10 * 43_478 - 10 * 150; // payoff and the writer's settlement fee
        uint256 nav = freeBtc * 115_000 * 1e10 + premium * 1e12;
        assertEq(clr.shortOf(address(callVault), call110), 0, "collected");
        (,,,,,, uint256 navPerShare) = callVault.epochs(1);
        assertEq(navPerShare, nav * 1e18 / 104_000e18);

        vm.prank(lp);
        callVault.claim();
        vm.prank(lp2);
        callVault.claim();
        // Half the vault, paid pro rata in WBTC and USDC.
        assertApproxEqAbs(wbtc.balanceOf(lp), 9e8 + freeBtc / 2, 1);
        assertApproxEqAbs(usdc.balanceOf(lp), 1_000_000e6 + premium / 2, 1);
        assertEq(callVault.balanceOf(lp), 52_000e18);
        // lp2: 1 BTC at $115 000 over the new NAV per share.
        assertEq(callVault.balanceOf(lp2), uint256(115_000e18) * 1e18 / navPerShare);
        assertEq(callVault.epoch(), 2);
    }

    function test_redeemLimitedToFreeFunds() public {
        _seedCallVault(1e8);
        // A Nov 27 call keeps 0.8 BTC locked across the Nov 6 roll.
        uint64[] memory s = new uint64[](1);
        s[0] = 120000;
        vm.prank(keeper);
        registry.createExpiry(BTC, FRI_NOV27, s);
        uint256 call120 = registry.listSeries(BTC, FRI_NOV27)[0];
        _pushVolFor(FRI_NOV27);
        _noExpiryCap(callVault);
        _buy(alice, call120, 80, 2000);

        vm.prank(lp);
        callVault.requestRedeem(104_000e18); // everything
        _expireAt(100_000);
        vm.prank(admin);
        btcFeed.pushPrice(100_000e8);
        _pushVolFor(FRI_NOV27);
        callVault.rollEpoch(FRI_NOV06);
        vm.prank(lp);
        callVault.claim();

        // Only the free 0.2 BTC and the premium left; the unfilled shares came back to lp.
        assertEq(clr.freeBalance(address(callVault), address(wbtc)), 0);
        assertEq(clr.freeBalance(address(callVault), address(usdc)), 0);
        assertEq(clr.shortOf(address(callVault), call120), 80);
        uint256 left = callVault.balanceOf(lp);
        assertGt(left, 0);
        assertEq(callVault.totalSupply(), left);
        assertEq(wbtc.balanceOf(lp), 9e8 + 0.2e8);
    }

    /// @dev Defaults, except one expiry may use all the collateral.
    function _noExpiryCap(ProtocolVault v) internal {
        vm.prank(admin);
        v.setRisk(500, 2_000, 1_000, 200, 1 hours, 2 hours, 10_000);
    }

    function test_expiryCapSpreadsCollateralAcrossExpiries() public {
        _seedCallVault(1e8); // 100 lots of collateral, half of it per expiry by default
        assertEq(callVault.maxExpiryBps(), 5_000);
        (, uint64 avail) = callVault.quote(call110, Side.Sell, 100);
        assertEq(avail, 50);
        assertEq(_buy(alice, call110, 100, 2000), 50);

        // Another strike of the same expiry: 50 locked + 50 free -> cap 50, all used.
        uint64[] memory k = new uint64[](1);
        k[0] = 120000;
        vm.prank(keeper);
        registry.addStrikes(BTC, FRI_NOV06, k);
        uint256 call120 = SeriesId.encode(Series(BTC, OptionType.Call, FRI_NOV06, 120000));
        (, avail) = callVault.quote(call120, Side.Sell, 10);
        assertEq(avail, 0);

        // A later expiry still gets half of what is free.
        vm.prank(keeper);
        registry.createExpiry(BTC, FRI_NOV27, k);
        _pushVolFor(FRI_NOV27);
        uint256 nov27 = registry.listSeries(BTC, FRI_NOV27)[0];
        (, avail) = callVault.quote(nov27, Side.Sell, 100);
        assertEq(avail, 25);
    }

    function _pushVolFor(uint64 expiry) internal {
        uint64[] memory e = new uint64[](1);
        e[0] = expiry;
        IIvFeed.Smile[] memory sm = new IIvFeed.Smile[](1);
        sm[0] = IIvFeed.Smile(500_000, 0, 0, 0);
        vm.prank(keeper);
        ivFeed.push(BTC, e, sm);
    }

    function test_cancelBeforeRoll() public {
        _seedCallVault(1e8);
        vm.prank(lp2);
        callVault.requestDeposit(0.5e8);
        vm.prank(lp2);
        callVault.cancelRequest();
        assertEq(wbtc.balanceOf(lp2), 10e8);
        assertEq(callVault.pendingDeposits(), 0);
    }

    /// Two LPs in, both out after an expiry with no trades: nobody gains, rounding favours the vault.
    function testFuzz_lpRoundTripConserves(uint256 a, uint256 b) public {
        a = bound(a, 1e4, 10e8);
        b = bound(b, 1e4, 10e8);
        _give(lp, wbtc, 10e8);
        _seedCallVault(a);
        vm.prank(lp2);
        callVault.requestDeposit(b);
        // Second roll needs a settled expiry: let Nov 6 pass with no positions.
        vm.warp(FRI_NOV06 + 1);
        vm.prank(admin);
        btcFeed.pushPrice(104_000e8);
        callVault.rollEpoch(FRI_NOV06);
        vm.prank(lp2);
        callVault.claim();

        uint256 sharesA = callVault.balanceOf(lp);
        uint256 sharesB = callVault.balanceOf(lp2);
        vm.prank(lp);
        callVault.requestRedeem(sharesA);
        vm.prank(lp2);
        callVault.requestRedeem(sharesB);
        uint64[] memory s = new uint64[](1);
        s[0] = 110000;
        vm.prank(keeper);
        registry.createExpiry(BTC, FRI_NOV27, s);
        vm.warp(FRI_NOV27 + 1);
        vm.prank(admin);
        btcFeed.pushPrice(104_000e8);
        callVault.rollEpoch(FRI_NOV27);
        vm.prank(lp);
        callVault.claim();
        vm.prank(lp2);
        callVault.claim();

        uint256 outA = wbtc.balanceOf(lp) + a - 20e8;
        uint256 outB = wbtc.balanceOf(lp2) + b - 10e8;
        assertLe(outA, a);
        assertLe(outB, b);
        assertApproxEqAbs(outA, a, 2);
        assertApproxEqAbs(outB, b, 2);
    }
}
