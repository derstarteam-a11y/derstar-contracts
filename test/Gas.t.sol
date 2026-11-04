// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TradingBase} from "./TradingBase.t.sol";
import {Side} from "../src/types/DerstarTypes.sol";

/// @dev Gas per user action, printed with -vv. Warm storage effects inside one test make
/// these numbers a lower bound; real transactions also pay 21k base + calldata.
contract GasTest is TradingBase {
    function test_gasProfile() public {
        _deposit(mm, wbtc, 5e8);
        _deposit(mm, usdc, 100_000e6);
        _ask(mm, call110, 260, 10); // warms the book

        vm.startPrank(mm);
        uint256 g = gasleft();
        book.placeOrder(call110, Side.Sell, 250, 10);
        emit log_named_uint("placeOrder ask, new price level", g - gasleft());
        g = gasleft();
        uint64 id = book.placeOrder(call110, Side.Sell, 250, 10);
        emit log_named_uint("placeOrder ask, existing level", g - gasleft());
        g = gasleft();
        book.replace(id, 255, 10);
        emit log_named_uint("replace", g - gasleft());
        g = gasleft();
        uint64 bid = book.placeOrder(call110, Side.Buy, 200, 10);
        emit log_named_uint("placeOrder bid", g - gasleft());
        g = gasleft();
        book.cancel(bid);
        emit log_named_uint("cancel", g - gasleft());
        for (uint32 i; i < 5; ++i) {
            book.placeOrder(call110, Side.Sell, 300 + i, 2);
        }
        vm.stopPrank();

        vm.startPrank(alice);
        g = gasleft();
        book.buy(call110, 1, 250, 0, NO_DEADLINE);
        emit log_named_uint("buy, 1 fill (writes new option)", g - gasleft());
        g = gasleft();
        book.buy(call110, 39, 304, 0, NO_DEADLINE);
        emit log_named_uint("buy, sweeping 8 orders on 8 levels", g - gasleft());
        vm.stopPrank();

        vm.prank(mm);
        book.placeOrder(call110, Side.Buy, 240, 10);
        vm.prank(alice);
        g = gasleft();
        book.sell(call110, 10, 240, 0, NO_DEADLINE);
        emit log_named_uint("sell to close into a writer's bid", g - gasleft());
    }
}
