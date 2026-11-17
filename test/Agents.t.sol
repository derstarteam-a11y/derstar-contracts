// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TradingBase} from "./TradingBase.t.sol";
import {IOrderBook} from "../src/interfaces/IOrderBook.sol";
import {IAgentRegistry} from "../src/interfaces/IAgentRegistry.sol";
import {Side} from "../src/types/DerstarTypes.sol";

/// API wallets: `bot` is mm's agent and trades for mm through execAs.
contract AgentsTest is TradingBase {
    address internal bot = makeAddr("bot");

    function setUp() public override {
        super.setUp();
        _deposit(mm, wbtc, 1e8);
        _deposit(mm, usdc, 10_000e6);
        vm.prank(mm);
        agents.setAgent(bot, uint64(block.timestamp + 30 days));
    }

    function _one(bytes memory call) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](1);
        calls[0] = call;
    }

    function _placeCall(Side side, uint32 ticks, uint64 lots) internal view returns (bytes memory) {
        IOrderBook.OrderParams[] memory o = new IOrderBook.OrderParams[](1);
        o[0] = IOrderBook.OrderParams(call110, side, ticks, lots);
        return abi.encodeCall(IOrderBook.placeOrders, (o));
    }

    // ------------------------------------------------------------ registry

    function test_setAgentAndExpiry() public {
        assertTrue(agents.isAgent(mm, bot));
        assertFalse(agents.isAgent(alice, bot), "agent of mm only");
        vm.warp(block.timestamp + 30 days + 1);
        assertFalse(agents.isAgent(mm, bot), "expired");
    }

    function test_revoke() public {
        vm.prank(mm);
        vm.expectEmit(address(agents));
        emit IAgentRegistry.AgentSet(mm, bot, 0);
        agents.setAgent(bot, 0);
        assertFalse(agents.isAgent(mm, bot));
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.NotAgent.selector, mm, bot));
        book.execAs(mm, _one(_placeCall(Side.Sell, 250, 1)));
    }

    function test_setAgentRejectsBadInput() public {
        vm.startPrank(mm);
        vm.expectRevert(abi.encodeWithSelector(IAgentRegistry.InvalidAgent.selector, address(0)));
        agents.setAgent(address(0), uint64(block.timestamp + 1));
        vm.expectRevert(abi.encodeWithSelector(IAgentRegistry.InvalidAgent.selector, mm));
        agents.setAgent(mm, uint64(block.timestamp + 1));
        vm.expectRevert(abi.encodeWithSelector(IAgentRegistry.InvalidExpiry.selector, uint64(block.timestamp)));
        agents.setAgent(bot, uint64(block.timestamp));
        vm.stopPrank();
    }

    // ------------------------------------------------------------ trading as the account

    function test_agentPlacesAndCancelsForAccount() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = _placeCall(Side.Sell, 250, 10);
        calls[1] = _placeCall(Side.Buy, 200, 5);
        vm.prank(bot);
        book.execAs(mm, calls);

        uint64 ask = book.nextOrderId() - 1;
        uint64 bid = book.nextOrderId();
        (address maker,,,,) = book.getOrder(ask);
        assertEq(maker, mm, "order is mm's");
        (maker,,,,) = book.getOrder(bid);
        assertEq(maker, mm);
        assertEq(clr.reservedBalance(mm, address(wbtc)), 0.1e8, "reserved from mm");

        // A plain cancel from the agent key is refused: agents act only through execAs.
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.NotOrderOwner.selector, ask));
        book.cancel(ask);

        uint64[] memory ids = new uint64[](2);
        (ids[0], ids[1]) = (ask, bid);
        vm.prank(bot);
        book.execAs(mm, _one(abi.encodeCall(IOrderBook.cancelMany, (ids))));
        assertEq(clr.reservedBalance(mm, address(wbtc)), 0);
        assertEq(clr.reservedBalance(mm, address(usdc)), 0);
        assertEq(clr.freeBalance(mm, address(usdc)), 10_000e6);
    }

    function test_agentReplaces() public {
        uint64 a = _ask(mm, call110, 250, 10);
        vm.prank(bot);
        book.execAs(mm, _one(abi.encodeCall(IOrderBook.replace, (a, 260, 4))));
        (address maker,,, uint32 ticks, uint64 left) = book.getOrder(book.nextOrderId());
        assertEq(maker, mm);
        assertEq(ticks, 260);
        assertEq(left, 4);
    }

    function test_agentTakesWithAccountFunds() public {
        _deposit(carol, wbtc, 1e8);
        _ask(carol, call110, 250, 10);
        uint256 mmUsdc = usdc.balanceOf(mm);
        vm.prank(bot);
        book.execAs(mm, _one(abi.encodeCall(IOrderBook.buy, (call110, 10, 250, 10, NO_DEADLINE))));
        assertEq(token.balanceOf(mm, call110), 10, "options go to mm");
        assertEq(token.balanceOf(bot, call110), 0);
        assertLt(usdc.balanceOf(mm), mmUsdc, "mm pays");
        _assertBacked(call110);
    }

    function test_strangerCannotAct() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.NotAgent.selector, mm, alice));
        book.execAs(mm, _one(_placeCall(Side.Sell, 250, 1)));
    }

    function test_expiredAgentCannotAct() public {
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.NotAgent.selector, mm, bot));
        book.execAs(mm, _one(_placeCall(Side.Sell, 250, 1)));
    }

    function test_batchIsAllOrNothing() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = _placeCall(Side.Sell, 250, 10);
        calls[1] = _placeCall(Side.Buy, 0, 1); // invalid price
        uint64 next = book.nextOrderId();
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(IOrderBook.InvalidPrice.selector, uint32(0)));
        book.execAs(mm, calls);
        assertEq(book.nextOrderId(), next, "nothing placed");
        assertEq(clr.reservedBalance(mm, address(wbtc)), 0);
    }

    function test_accountBatchesItsOwnCalls() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = _placeCall(Side.Sell, 250, 10);
        calls[1] = _placeCall(Side.Sell, 260, 10);
        vm.prank(mm);
        book.execAs(mm, calls);
        (address maker,,,,) = book.getOrder(book.nextOrderId());
        assertEq(maker, mm);
    }

    function test_noNesting() public {
        bytes[] memory inner = _one(_placeCall(Side.Sell, 250, 1));
        vm.prank(bot);
        vm.expectRevert(IOrderBook.InvalidConfig.selector);
        book.execAs(mm, _one(abi.encodeCall(IOrderBook.execAs, (mm, inner))));
    }

    function test_agentGetsNoAdminRights() public {
        vm.prank(bot);
        vm.expectRevert(); // AccessControl: the agent key holds no role
        book.execAs(mm, _one(abi.encodeCall(book.setMaxFillsPerTx, (1))));
    }

    /// After a batch the agent key is itself again: its own orders are its own.
    function test_actorClearedAfterBatch() public {
        _give(bot, wbtc, 1e8);
        _deposit(bot, wbtc, 1e8);
        vm.prank(bot);
        book.execAs(mm, _one(_placeCall(Side.Sell, 250, 1)));
        uint64 own = _ask(bot, call110, 300, 1);
        (address maker,,,,) = book.getOrder(own);
        assertEq(maker, bot);
    }
}
