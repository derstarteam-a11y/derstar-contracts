// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {IOptionToken} from "../src/interfaces/IOptionToken.sol";
import {SeriesId} from "../src/libraries/SeriesId.sol";
import {Series, OptionType} from "../src/types/DerstarTypes.sol";

/// @dev A contract that rejects ERC-1155 transfers. Clearing moves must still reach it.
contract Rejector {}

contract OptionTokenTest is BaseTest {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        vm.prank(keeper);
        registry.createExpiry(BTC, FRI_NOV27, strikes(106000, 108000, 110000));
        id = SeriesId.encode(Series(BTC, OptionType.Call, FRI_NOV27, 110000));
    }

    function test_seriesName() public view {
        assertEq(token.seriesName(id), "BTC-27NOV26-110000-C");
        uint256 put = SeriesId.encode(Series(BTC, OptionType.Put, FRI_NOV27, 106000));
        assertEq(token.seriesName(put), "BTC-27NOV26-106000-P");
    }

    function test_onlyClearingMints() public {
        vm.prank(alice);
        vm.expectRevert(IOptionToken.NotClearing.selector);
        token.mint(alice, id, 10);
    }

    function test_mintMoveBurnTracksSupply() public {
        address bob = makeAddr("bob");
        vm.startPrank(clearing);
        token.mint(alice, id, 10);
        token.clearingMove(alice, bob, id, 4);
        token.burn(bob, id, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(alice, id), 6);
        assertEq(token.balanceOf(bob, id), 3);
        assertEq(token.totalSupply(id), 9);
    }

    function test_clearingMintSkipsReceiverCallback() public {
        Rejector r = new Rejector();
        vm.prank(clearing);
        token.mint(address(r), id, 5);
        assertEq(token.balanceOf(address(r), id), 5);
    }

    function test_usersCanTransferFreely() public {
        address bob = makeAddr("bob");
        vm.prank(clearing);
        token.mint(alice, id, 10);
        vm.prank(alice);
        token.safeTransferFrom(alice, bob, id, 3, "");
        assertEq(token.balanceOf(bob, id), 3);
    }

    function test_setClearingOnce() public {
        vm.expectRevert(IOptionToken.ClearingAlreadySet.selector);
        token.setClearing(alice);
    }
}
