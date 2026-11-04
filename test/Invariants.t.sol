// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TradingBase} from "./TradingBase.t.sol";
import {Clearing} from "../src/core/Clearing.sol";
import {OrderBook} from "../src/core/OrderBook.sol";
import {OptionToken} from "../src/core/OptionToken.sol";
import {Side} from "../src/types/DerstarTypes.sol";

/// @dev Random traders hitting the book. Every call may revert; reverts are fine.
contract Handler is Test {
    OrderBook internal book;
    Clearing internal clr;
    OptionToken internal token;
    address[] public actors;
    uint256[2] public series;
    uint64[] public orderIds;
    mapping(uint64 => address) public ownerOf;
    uint256 public trades;

    constructor(OrderBook b, Clearing c, OptionToken t, address[] memory a, uint256 s0, uint256 s1) {
        (book, clr, token, actors) = (b, c, t, a);
        series = [s0, s1];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function place(uint256 a, uint256 s, bool isBid, uint32 price, uint64 lots) external {
        address who = _actor(a);
        price = uint32(bound(price, 1, 600));
        lots = uint64(bound(lots, 1, 30));
        vm.prank(who);
        try book.placeOrder(series[s % 2], isBid ? Side.Buy : Side.Sell, price, lots) returns (uint64 id) {
            orderIds.push(id);
            ownerOf[id] = who;
        } catch {}
    }

    function take(uint256 a, uint256 s, bool isBuy, uint32 limit, uint64 lots) external {
        address who = _actor(a);
        lots = uint64(bound(lots, 1, 40));
        // Mostly marketable, so trades actually happen.
        limit = isBuy ? uint32(bound(limit, 300, 600)) : uint32(bound(limit, 1, 300));
        vm.prank(who);
        if (isBuy) {
            try book.buy(series[s % 2], lots, limit, 0, type(uint64).max) {
                ++trades;
            } catch {}
        } else {
            try book.sell(series[s % 2], lots, limit, 0, type(uint64).max) {
                ++trades;
            } catch {}
        }
    }

    function cancel(uint256 i) external {
        if (orderIds.length == 0) return;
        uint64 id = orderIds[i % orderIds.length];
        vm.prank(ownerOf[id]);
        try book.cancel(id) {} catch {}
    }

    function transferTokens(uint256 a, uint256 b, uint256 s, uint256 amount) external {
        address from = _actor(a);
        uint256 id = series[s % 2];
        uint256 bal = token.balanceOf(from, id);
        if (bal == 0) return;
        vm.prank(from);
        token.safeTransferFrom(from, _actor(b), id, bound(amount, 1, bal), "");
    }

    function net(uint256 a, uint256 s) external {
        vm.prank(_actor(a));
        clr.netPositions(series[s % 2]);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract InvariantsTest is TradingBase {
    Handler internal handler;
    address[] internal traders;

    function setUp() public override {
        super.setUp();
        traders = [mm, alice, bob, carol];
        for (uint256 i; i < traders.length; ++i) {
            _deposit(traders[i], wbtc, 2e8);
            _deposit(traders[i], usdc, 200_000e6);
        }
        // The vault keeps a two-sided quote so takers find liquidity most of the time.
        _fundVault(wbtc, 5e8);
        _fundVault(usdc, 1_000_000e6);
        vault.setQuote(call110, Side.Sell, 350, 1000);
        vault.setQuote(call110, Side.Buy, 250, 1000);
        vault.setQuote(put100, Side.Sell, 350, 1000);
        vault.setQuote(put100, Side.Buy, 250, 1000);
        handler = new Handler(book, clr, token, traders, call110, put100);
        targetContract(address(handler));
    }

    function afterInvariant() public {
        emit log_named_uint("trades", handler.trades());
    }

    function invariant_everyLongIsBacked() public view {
        _assertBacked(call110);
        _assertBacked(put100);
    }

    /// Clearing holds exactly what its books say: free + reserved + locked collateral.
    function invariant_clearingIsSolvent() public view {
        uint256 usdcBooks = clr.freeBalance(fees, address(usdc)) + clr.freeBalance(address(vault), address(usdc));
        uint256 wbtcBooks = clr.freeBalance(address(vault), address(wbtc));
        for (uint256 i; i < traders.length; ++i) {
            address t = traders[i];
            usdcBooks += clr.freeBalance(t, address(usdc)) + clr.reservedBalance(t, address(usdc));
            wbtcBooks += clr.freeBalance(t, address(wbtc)) + clr.reservedBalance(t, address(wbtc));
        }
        usdcBooks += uint256(clr.totalShort(put100)) * 1000e6; // 100 000 strike, 0.01 lot
        // Every long lot carries its settlement fee reserve.
        usdcBooks += token.totalSupply(call110) * clr.reservePerLot(call110);
        usdcBooks += token.totalSupply(put100) * clr.reservePerLot(put100);
        wbtcBooks += uint256(clr.totalShort(call110)) * 0.01e8;
        assertEq(usdc.balanceOf(address(clr)), usdcBooks, "usdc");
        assertEq(wbtc.balanceOf(address(clr)), wbtcBooks, "wbtc");
    }

    /// Tokens of resting asks sit at Clearing and are counted as long positions of nobody else.
    function invariant_noShortWithoutCollateral() public view {
        for (uint256 i; i < traders.length; ++i) {
            assertLe(clr.shortOf(traders[i], call110), clr.totalShort(call110));
        }
    }
}
