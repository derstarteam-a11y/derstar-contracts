// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {ISeriesRegistry} from "../src/interfaces/ISeriesRegistry.sol";
import {SeriesRegistry} from "../src/core/SeriesRegistry.sol";
import {SeriesId} from "../src/libraries/SeriesId.sol";
import {Series, SeriesState, OptionType, UnderlyingConfig} from "../src/types/DerstarTypes.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract SeriesRegistryTest is BaseTest {
    function _callId(uint8 u, uint64 expiry, uint64 k) internal pure returns (uint256) {
        return SeriesId.encode(Series(u, OptionType.Call, expiry, k));
    }

    function _putId(uint8 u, uint64 expiry, uint64 k) internal pure returns (uint256) {
        return SeriesId.encode(Series(u, OptionType.Put, expiry, k));
    }

    function test_createExpiry_listsCallsAndPuts() public {
        vm.prank(keeper);
        registry.createExpiry(BTC, FRI_NOV06, strikes(100000, 102000, 104000));

        uint256[] memory ids = registry.listSeries(BTC, FRI_NOV06);
        assertEq(ids.length, 6);
        assertEq(uint8(registry.stateOf(_callId(BTC, FRI_NOV06, 102000))), uint8(SeriesState.Active));
        assertEq(uint8(registry.stateOf(_putId(BTC, FRI_NOV06, 102000))), uint8(SeriesState.Active));
        assertTrue(registry.isTradable(_callId(BTC, FRI_NOV06, 104000)));
        assertEq(registry.listExpiries(BTC).length, 1);
    }

    function test_createExpiry_isIdempotent() public {
        vm.startPrank(keeper);
        registry.createExpiry(BTC, FRI_NOV06, strikes(100000, 102000, 104000));
        registry.createExpiry(BTC, FRI_NOV06, strikes(100000, 102000, 106000));
        vm.stopPrank();
        assertEq(registry.listSeries(BTC, FRI_NOV06).length, 8);
        assertEq(registry.listExpiries(BTC).length, 1);
    }

    function test_acceptsDailies() public {
        vm.prank(keeper);
        registry.createExpiry(BTC, THU_NOV26, strikes(100000, 102000, 104000));
        assertTrue(registry.isListed(BTC, THU_NOV26));
    }

    function test_rejectsWrongHour() public {
        uint64 bad = FRI_NOV06 + 1 hours;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ISeriesRegistry.InvalidExpiry.selector, bad));
        registry.createExpiry(BTC, bad, strikes(100000, 102000, 104000));
    }

    function test_rejectsBeyondHorizon() public {
        uint64 far = FRI_NOV06 + 11 weeks;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ISeriesRegistry.InvalidExpiry.selector, far));
        registry.createExpiry(BTC, far, strikes(100000, 102000, 104000));
    }

    function test_rejectsOffGridStrike() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ISeriesRegistry.InvalidStrike.selector, uint64(101000)));
        registry.createExpiry(BTC, FRI_NOV06, strikes(100000, 101000, 104000));
    }

    function test_rejectsTooManyStrikes() public {
        uint64[] memory s = new uint64[](22);
        for (uint256 i; i < 22; ++i) {
            s[i] = uint64(80000 + 2000 * i);
        }
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ISeriesRegistry.TooManyStrikes.selector, 22, 21));
        registry.createExpiry(BTC, FRI_NOV06, s);
    }

    function test_onlyKeeperLists() public {
        bytes32 role = registry.SERIES_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        registry.createExpiry(BTC, FRI_NOV06, strikes(100000, 102000, 104000));
    }

    function test_tradingStopsAtCutoff() public {
        vm.prank(keeper);
        registry.createExpiry(BTC, FRI_NOV06, strikes(100000, 102000, 104000));
        uint256 id = _callId(BTC, FRI_NOV06, 102000);

        vm.warp(FRI_NOV06 - 30 minutes - 1);
        assertTrue(registry.isTradable(id));
        vm.warp(FRI_NOV06 - 30 minutes);
        assertFalse(registry.isTradable(id));
    }

    function test_addStrikes_closedNearExpiry() public {
        vm.prank(keeper);
        registry.createExpiry(BTC, FRI_NOV06, strikes(100000, 102000, 104000));
        vm.warp(FRI_NOV06 - 10 minutes);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ISeriesRegistry.InvalidExpiry.selector, FRI_NOV06));
        registry.addStrikes(BTC, FRI_NOV06, strikes(106000, 108000, 110000));
    }

    function test_collateralPerLot() public {
        vm.startPrank(keeper);
        registry.createExpiry(BTC, FRI_NOV06, strikes(100000, 102000, 104000));
        registry.createExpiry(ETH, FRI_NOV06, strikes(3000, 3100, 3200));
        vm.stopPrank();

        (address t, uint256 a) = registry.collateralPerLot(_callId(BTC, FRI_NOV06, 102000));
        assertEq(t, address(wbtc));
        assertEq(a, 1_000_000); // 0.01 WBTC
        (t, a) = registry.collateralPerLot(_putId(BTC, FRI_NOV06, 102000));
        assertEq(t, address(usdc));
        assertEq(a, 1020e6); // 102000 * 0.01
        (t, a) = registry.collateralPerLot(_callId(ETH, FRI_NOV06, 3100));
        assertEq(t, address(weth));
        assertEq(a, 1e17); // 0.1 WETH
        (t, a) = registry.collateralPerLot(_putId(ETH, FRI_NOV06, 3100));
        assertEq(a, 310e6); // 3100 * 0.1
    }

    function test_premiumForTicks_matchesSpecExample() public {
        vm.prank(keeper);
        registry.createExpiry(BTC, FRI_NOV06, strikes(106000, 108000, 110000));
        // 1 250 USDC per contract = 250 ticks, 10 lots = 0.1 BTC -> 125 USDC
        assertEq(registry.premiumForTicks(_callId(BTC, FRI_NOV06, 110000), 250, 10), 125e6);
    }

    function test_markSettled_onlyClearing() public {
        vm.prank(keeper);
        registry.createExpiry(BTC, FRI_NOV06, strikes(100000, 102000, 104000));
        uint256 id = _callId(BTC, FRI_NOV06, 102000);

        vm.prank(alice);
        vm.expectRevert(ISeriesRegistry.NotClearing.selector);
        registry.markSettled(id);

        vm.prank(clearing);
        registry.markSettled(id);
        assertEq(uint8(registry.stateOf(id)), uint8(SeriesState.Settled));
        assertFalse(registry.isTradable(id));

        vm.prank(clearing);
        vm.expectRevert(abi.encodeWithSelector(ISeriesRegistry.SeriesNotActive.selector, id));
        registry.markSettled(id);
    }

    function test_configLockedOnceSeriesExist() public {
        vm.prank(keeper);
        registry.createExpiry(BTC, FRI_NOV06, strikes(100000, 102000, 104000));

        UnderlyingConfig memory cfg = btcConfig();
        cfg.lotsPerContract = 10;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISeriesRegistry.ConfigLocked.selector, BTC));
        registry.setUnderlying(BTC, "BTC", cfg);

        // Feed and the enabled flag may still change.
        cfg = btcConfig();
        cfg.feed = address(0xFEED);
        cfg.enabled = false;
        vm.prank(admin);
        registry.setUnderlying(BTC, "BTC", cfg);
        assertFalse(registry.isTradable(_callId(BTC, FRI_NOV06, 102000)));
    }

    function test_rejectsInexactLotConfig() public {
        UnderlyingConfig memory cfg = btcConfig();
        cfg.lotsPerContract = 3; // 1e8 WBTC units / 3 is not exact
        vm.prank(admin);
        vm.expectRevert(ISeriesRegistry.InvalidConfig.selector);
        registry.setUnderlying(2, "SOL", cfg);
    }

    function test_activeExpiriesDropsPast() public {
        vm.startPrank(keeper);
        registry.createExpiry(BTC, FRI_OCT30, strikes(100000, 102000, 104000));
        registry.createExpiry(BTC, FRI_NOV06, strikes(100000, 102000, 104000));
        vm.stopPrank();
        vm.warp(FRI_OCT30 + 1);
        uint64[] memory a = registry.activeExpiries(BTC);
        assertEq(a.length, 1);
        assertEq(a[0], FRI_NOV06);
    }

    function test_demoModeAcceptsHourlyExpiries() public {
        SeriesRegistry demo = new SeriesRegistry(admin, address(usdc), 1 hours, 7 days);
        vm.startPrank(admin);
        demo.setUnderlying(BTC, "BTC", btcConfig());
        demo.grantRole(demo.SERIES_ROLE(), keeper);
        vm.stopPrank();

        uint64 inTwoHours = uint64(NOW + 2 hours);
        vm.prank(keeper);
        demo.createExpiry(BTC, inTwoHours, strikes(100000, 102000, 104000));
        assertEq(demo.listSeries(BTC, inTwoHours).length, 6);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ISeriesRegistry.InvalidExpiry.selector, inTwoHours + 60));
        demo.createExpiry(BTC, inTwoHours + 60, strikes(100000, 102000, 104000));
    }
}
