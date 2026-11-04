// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Clearing} from "../src/core/Clearing.sol";
import {ProtocolVault} from "../src/core/ProtocolVault.sol";
import {FeeCollector} from "../src/core/FeeCollector.sol";
import {IClearing} from "../src/interfaces/IClearing.sol";

/// @notice Mainnet governance: hands every admin role from the deployer to a TimelockController
/// owned by the team Safe, makes the Safe the guardian (pause only, no delay), and routes fees to
/// a FeeCollector the Timelock controls. The deployer keeps nothing.
///
/// Testnet stays on one team wallet and does not run this.
///
/// Env: PRIVATE_KEY (current admin), SAFE (Safe multisig, 2-of-3 on mainnet),
/// DEPLOYMENT (default deployments/<chainId>.json), TIMELOCK_DELAY (seconds, default 48 h).
contract HandoffGovernance is Script {
    bytes32 internal constant ADMIN = 0x00; // DEFAULT_ADMIN_ROLE
    bytes32 internal constant GUARDIAN = keccak256("GUARDIAN_ROLE");

    struct Addrs {
        address registry;
        address oracle;
        address ivFeed;
        address clearing;
        address orderBook;
        address[3] vaults;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address safe = vm.envAddress("SAFE");
        uint256 delay = vm.envOr("TIMELOCK_DELAY", uint256(48 hours));
        string memory path = vm.envOr("DEPLOYMENT", string.concat("deployments/", vm.toString(block.chainid), ".json"));
        string memory json = vm.readFile(path);
        Addrs memory a;
        a.registry = vm.parseJsonAddress(json, ".registry");
        a.oracle = vm.parseJsonAddress(json, ".oracle");
        a.ivFeed = vm.parseJsonAddress(json, ".ivFeed");
        a.clearing = vm.parseJsonAddress(json, ".clearing");
        a.orderBook = vm.parseJsonAddress(json, ".orderBook");
        a.vaults = [
            vm.parseJsonAddress(json, ".vaultBtcCalls"),
            vm.parseJsonAddress(json, ".vaultEthCalls"),
            vm.parseJsonAddress(json, ".vaultPuts")
        ];

        vm.startBroadcast(pk);
        (TimelockController timelock, FeeCollector collector) = handoff(a, vm.addr(pk), safe, delay);
        vm.stopBroadcast();
        console2.log("TimelockController", address(timelock));
        console2.log("FeeCollector", address(collector));
    }

    /// @dev Separate from `run` so tests can call it directly. `me` is the current admin.
    function handoff(Addrs memory a, address me, address safe, uint256 delay)
        public
        returns (TimelockController timelock, FeeCollector collector)
    {
        require(safe != address(0) && safe.code.length > 0, "SAFE must be a deployed multisig");
        address[] memory safeOnly = new address[](1);
        safeOnly[0] = safe;
        // The Safe proposes and executes; nobody administers the Timelock but itself.
        timelock = new TimelockController(delay, safeOnly, safeOnly, address(0));
        collector = new FeeCollector(IClearing(a.clearing), address(timelock));

        Clearing c = Clearing(a.clearing);
        c.setFees(c.notionalFeePpm(), c.makerFeePpm(), c.premiumCapPpm(), c.settlementFeePpm(), address(collector));

        _move(a.clearing, me, safe, address(timelock), true);
        for (uint256 i; i < 3; ++i) {
            _move(a.vaults[i], me, safe, address(timelock), true);
        }
        _move(a.registry, me, safe, address(timelock), false);
        _move(a.oracle, me, safe, address(timelock), false);
        _move(a.ivFeed, me, safe, address(timelock), false);
        _move(a.orderBook, me, safe, address(timelock), false);
    }

    function _move(address target, address me, address safe, address timelock, bool hasGuardian) internal {
        IAccessControl ac = IAccessControl(target);
        ac.grantRole(ADMIN, timelock);
        if (hasGuardian) {
            ac.grantRole(GUARDIAN, safe);
            ac.renounceRole(GUARDIAN, me);
        }
        ac.renounceRole(ADMIN, me);
    }
}
