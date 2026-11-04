// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {ITestnetAccess} from "../src/mocks/MockERC20.sol";
import {TestnetAccess} from "../src/mocks/TestnetAccess.sol";

contract MocksTest is BaseTest {
    function test_faucetCooldown() public {
        vm.startPrank(alice);
        usdc.faucet();
        assertEq(usdc.balanceOf(alice), 100_000e6);
        vm.expectRevert(abi.encodeWithSelector(MockERC20.FaucetCooldown.selector, NOW + 1 days));
        usdc.faucet();
        vm.warp(NOW + 1 days);
        usdc.faucet();
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 200_000e6);
    }

    function test_closedFaucet() public {
        address gate = makeAddr("gatekeeper");
        address bob = makeAddr("bob");
        TestnetAccess access = new TestnetAccess(admin, gate);
        vm.prank(admin);
        usdc.setAccess(ITestnetAccess(address(access)));

        vm.expectRevert(abi.encodeWithSelector(MockERC20.NotInvited.selector, alice));
        vm.prank(alice);
        usdc.faucet();

        address[] memory who = new address[](1);
        who[0] = alice;
        vm.expectRevert(); // only the gatekeeper (or admin) admits wallets
        vm.prank(bob);
        access.grant(who);
        vm.prank(gate);
        access.grant(who);
        vm.prank(alice);
        usdc.faucet();
        assertEq(usdc.balanceOf(alice), 100_000e6);

        vm.expectRevert(); // the gatekeeper cannot remove wallets
        vm.prank(gate);
        access.revoke(who);
        vm.prank(admin);
        access.revoke(who);
        assertFalse(access.allowed(alice));

        vm.prank(admin);
        access.setOpenToAll(true);
        vm.prank(bob);
        usdc.faucet();
        assertEq(usdc.balanceOf(bob), 100_000e6);
    }

    function test_aggregatorHistory() public {
        vm.startPrank(admin);
        btcFeed.pushPriceAt(104_000e8, uint64(NOW - 100));
        btcFeed.pushPrice(104_500e8);
        vm.stopPrank();

        (uint80 rid, int256 p,, uint256 at,) = btcFeed.latestRoundData();
        assertEq(p, 104_500e8);
        assertEq(at, NOW);
        assertEq(rid, (uint80(1) << 64) | 2);
        (, int256 prev,, uint256 prevAt,) = btcFeed.getRoundData(rid - 1);
        assertEq(prev, 104_000e8);
        assertEq(prevAt, NOW - 100);
    }

    function test_aggregatorRejectsTimeTravel() public {
        vm.startPrank(admin);
        btcFeed.pushPrice(104_000e8);
        vm.expectRevert(MockAggregator.NonMonotonicTime.selector);
        btcFeed.pushPriceAt(104_000e8, uint64(NOW - 1));
        vm.stopPrank();
    }

    function test_aggregatorNewPhase() public {
        vm.startPrank(admin);
        btcFeed.pushPrice(104_000e8);
        btcFeed.startNewPhase();
        btcFeed.pushPrice(105_000e8);
        vm.stopPrank();
        (uint80 rid,,,,) = btcFeed.latestRoundData();
        assertEq(rid, (uint80(2) << 64) | 1);
    }
}
