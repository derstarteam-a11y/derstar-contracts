// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TradingBase} from "./TradingBase.t.sol";
import {HandoffGovernance} from "../script/HandoffGovernance.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {FeeCollector} from "../src/core/FeeCollector.sol";
import {OptionType} from "../src/types/DerstarTypes.sol";

contract GovernanceTest is TradingBase {
    HandoffGovernance internal gov;
    address internal safe;

    function setUp() public override {
        super.setUp();
        gov = new HandoffGovernance();
        safe = address(new SafeStub());
    }

    function _handoff() internal returns (TimelockController tl, FeeCollector fc) {
        HandoffGovernance.Addrs memory a;
        (a.registry, a.oracle, a.clearing, a.orderBook) =
        (address(registry), address(oracle), address(clr), address(book));
        // The trading tests run without IvFeed and protocol vaults: role-only stand-ins take their place.
        a.ivFeed = address(new RoleStub(address(gov)));
        a.vaults = [
            address(new RoleStub(address(gov))),
            address(new RoleStub(address(gov))),
            address(new RoleStub(address(gov)))
        ];
        // The script runs as the admin: hand it the roles first, as the deployer would hold them.
        vm.startPrank(admin);
        bytes32[2] memory roles = [bytes32(0), keccak256("GUARDIAN_ROLE")];
        address[4] memory targets = [address(registry), address(oracle), address(clr), address(book)];
        for (uint256 i; i < targets.length; ++i) {
            for (uint256 r; r < 2; ++r) {
                IAccessControl(targets[i]).grantRole(roles[r], address(gov));
            }
        }
        vm.stopPrank();
        (tl, fc) = gov.handoff(a, address(gov), safe, 48 hours);
    }

    function test_handoffLeavesTheDeployerNothing() public {
        (TimelockController tl, FeeCollector fc) = _handoff();
        assertTrue(clr.hasRole(0x00, address(tl)));
        assertTrue(clr.hasRole(clr.GUARDIAN_ROLE(), safe));
        assertFalse(clr.hasRole(0x00, address(gov)));
        assertFalse(clr.hasRole(clr.GUARDIAN_ROLE(), address(gov)));
        assertTrue(registry.hasRole(0x00, address(tl)));
        assertFalse(registry.hasRole(0x00, address(gov)));
        assertEq(clr.feeRecipient(), address(fc));
        assertEq(fc.owner(), address(tl));
        assertEq(tl.getMinDelay(), 48 hours);
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), safe));

        // The Safe pauses at once; parameter changes must wait out the Timelock.
        vm.prank(safe);
        clr.pauseTrading(true);
        vm.prank(safe);
        vm.expectRevert();
        clr.setFees(300, 150, 125_000, 150, safe);
    }

    function test_feesSweptToCollectorAndPaidOnlyByTimelock() public {
        (TimelockController tl, FeeCollector fc) = _handoff();
        _deposit(mm, wbtc, 1e8);
        _ask(mm, call110, 250, 10);
        _buy(alice, call110, 10, 250);
        assertEq(fc.sweep(address(usdc)), 4.68e6);
        assertEq(usdc.balanceOf(address(fc)), 4.68e6);

        vm.prank(safe);
        vm.expectRevert();
        fc.pay(address(usdc), safe, 1);

        bytes memory call = abi.encodeCall(FeeCollector.pay, (address(usdc), safe, 4.68e6));
        vm.prank(safe);
        tl.schedule(address(fc), 0, call, bytes32(0), bytes32(0), 48 hours);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(safe);
        tl.execute(address(fc), 0, call, bytes32(0), bytes32(0));
        assertEq(usdc.balanceOf(safe), 4.68e6);
    }

    function test_refusesAnEoaAsSafe() public {
        HandoffGovernance.Addrs memory a;
        vm.expectRevert("SAFE must be a deployed multisig");
        gov.handoff(a, address(gov), makeAddr("eoa"), 48 hours);
    }
}

/// @dev Stands in for a Safe: any contract address works for role checks.
contract SafeStub {}

contract RoleStub is AccessControl {
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(keccak256("GUARDIAN_ROLE"), admin);
    }
}
