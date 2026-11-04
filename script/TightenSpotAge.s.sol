// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {OrderBook} from "../src/core/OrderBook.sol";

/// @notice Testnet: IV orders fill only against a fresh spot price. The default allows a price up to
/// 2 hours old; the price keeper pushes every 10 minutes, so SPOT_AGE (default 1200 s = 20 min)
/// still leaves room for one missed push. The oracle and the per-side order cap stay as they are.
/// Vaults are not touched.
///
///   forge script script/TightenSpotAge.s.sol --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
/// Without --broadcast it is a dry run.
contract TightenSpotAge is Script {
    function run() external {
        string memory json = vm.readFile(vm.envOr("DEPLOYMENT", string("deployments/421614.json")));
        OrderBook book = OrderBook(vm.parseJsonAddress(json, ".orderBook"));
        uint32 age = uint32(vm.envOr("SPOT_AGE", uint256(1200)));
        console2.log("IV orders: max spot age", book.maxSpotAge(), "->", age);
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();
        book.setVolPricing(book.oracle(), age, book.maxVolOrdersPerSide());
        vm.stopBroadcast();
    }
}
