// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IvFeed} from "../src/core/IvFeed.sol";
import {IIvFeed} from "../src/interfaces/IIvFeed.sol";

contract IvFeedTest is Test {
    IvFeed internal feed;
    address internal admin = makeAddr("admin");
    address internal publisher = makeAddr("publisher");
    uint64 internal constant E = 1793952000;

    function setUp() public {
        vm.warp(1792584000);
        feed = new IvFeed(admin, publisher);
    }

    function _push(uint32 atm, int32 skew, int32 curv) internal {
        uint64[] memory e = new uint64[](1);
        e[0] = E;
        IIvFeed.Smile[] memory s = new IIvFeed.Smile[](1);
        s[0] = IIvFeed.Smile(atm, skew, curv, 0);
        vm.prank(publisher);
        feed.push(0, e, s);
    }

    function test_atmStrikeReturnsAtmVol() public {
        _push(550_000, -200_000, 1_000_000);
        assertEq(feed.iv(0, E, 104_000, 104_000e8), 550_000);
        assertTrue(feed.isFresh(0, E));
    }

    function test_skewAndCurvature() public {
        _push(550_000, -200_000, 1_000_000);
        // k = ln(94000/104000) ~ -0.1011: 0.55 + 0.0202 + 0.0102 ~ 0.5804
        assertApproxEqAbs(feed.iv(0, E, 94_000, 104_000e8), 580_437, 5);
        // k = ln(114000/104000) ~ 0.0918: 0.55 - 0.0184 + 0.0084 ~ 0.5401 (exact 0.540067)
        assertApproxEqAbs(feed.iv(0, E, 114_000, 104_000e8), 540_067, 5);
    }

    function test_clampedToBounds() public {
        _push(60_000, 2_000_000, 0);
        assertEq(feed.iv(0, E, 50_000, 104_000e8), 50_000); // would go negative: clamped to min
    }

    function test_rejectsOutOfBounds() public {
        uint64[] memory e = new uint64[](1);
        e[0] = E;
        IIvFeed.Smile[] memory s = new IIvFeed.Smile[](1);
        s[0] = IIvFeed.Smile(10_000, 0, 0, 0);
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(IIvFeed.VolOutOfBounds.selector, E, uint32(10_000)));
        feed.push(0, e, s);
    }

    function test_rejectsWildShape() public {
        uint64[] memory e = new uint64[](1);
        e[0] = E;
        IIvFeed.Smile[] memory s = new IIvFeed.Smile[](1);
        s[0] = IIvFeed.Smile(550_000, -3_000_001, 0, 0);
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(IIvFeed.ShapeOutOfBounds.selector, E, int32(-3_000_001), int32(0)));
        feed.push(0, e, s);

        s[0] = IIvFeed.Smile(550_000, 0, 30_000_001, 0);
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(IIvFeed.ShapeOutOfBounds.selector, E, int32(0), int32(30_000_001)));
        feed.push(0, e, s);

        _push(550_000, -3_000_000, 30_000_000); // the bounds themselves are allowed
        assertTrue(feed.isFresh(0, E));
    }

    function test_shapeBoundsAdminOnly() public {
        vm.expectRevert();
        feed.setShapeBounds(1, 1);
        vm.prank(admin);
        feed.setShapeBounds(100_000, 100_000);
        assertEq(feed.maxAbsSkew(), 100_000);
        vm.prank(admin);
        vm.expectRevert(IIvFeed.InvalidConfig.selector);
        feed.setShapeBounds(0, 1);
    }

    function test_jumpCapOnlyAgainstFreshValue() public {
        _push(500_000, 0, 0);
        uint64[] memory e = new uint64[](1);
        e[0] = E;
        IIvFeed.Smile[] memory s = new IIvFeed.Smile[](1);
        s[0] = IIvFeed.Smile(700_000, 0, 0, 0); // +40% > 30% cap
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(IIvFeed.JumpTooLarge.selector, E, uint32(500_000), uint32(700_000)));
        feed.push(0, e, s);

        vm.warp(block.timestamp + 16 minutes);
        assertFalse(feed.isFresh(0, E));
        _push(700_000, 0, 0);
        assertTrue(feed.isFresh(0, E));
    }

    function test_onlyPublisher() public {
        uint64[] memory e = new uint64[](0);
        IIvFeed.Smile[] memory s = new IIvFeed.Smile[](0);
        vm.expectRevert();
        feed.push(0, e, s);
    }
}
