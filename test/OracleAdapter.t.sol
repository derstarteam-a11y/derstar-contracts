// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {OracleAdapter} from "../src/core/OracleAdapter.sol";
import {IOracleAdapter} from "../src/interfaces/IOracleAdapter.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {IApi3ReaderProxy} from "../src/interfaces/IApi3ReaderProxy.sol";
import {MockApi3Proxy} from "../src/mocks/MockApi3Proxy.sol";

contract OracleAdapterTest is BaseTest {
    OracleAdapter internal oracle;
    uint64 internal constant E = FRI_NOV06;
    uint80 internal constant R1 = (uint80(1) << 64) | 1;

    function setUp() public override {
        super.setUp();
        oracle = new OracleAdapter(admin, registry, AggregatorV3Interface(address(0)));
    }

    function _at(int256 price, uint256 ts) internal {
        vm.prank(admin);
        btcFeed.pushPriceAt(price * 1e8, uint64(ts));
    }

    function test_twapWeightsByTimeLive() public {
        _at(100_000, E - 2 hours);
        _at(106_000, E - 20 minutes);
        _at(103_000, E - 5 minutes);
        _at(120_000, E + 10 minutes); // after expiry: ignored
        vm.warp(E + 15 minutes);

        // 10 min at 100k, 15 min at 106k, 5 min at 103k
        assertEq(oracle.finalize(BTC, E, R1 + 2), 103_500e8);
        (uint256 p, bool isFinal, IOracleAdapter.PriceSource src) = oracle.settlementPrice(BTC, E);
        assertEq(p, 103_500e8);
        assertTrue(isFinal);
        assertEq(uint8(src), uint8(IOracleAdapter.PriceSource.Twap));
    }

    function test_singleRoundCoversWholeWindow() public {
        _at(104_000, E - 3 hours);
        vm.warp(E);
        assertEq(oracle.finalize(BTC, E, R1), 104_000e8);
    }

    function test_rejectsWrongHints() public {
        _at(100_000, E - 2 hours);
        _at(106_000, E - 20 minutes);
        _at(120_000, E + 10 minutes);
        vm.warp(E + 1 hours);

        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.BadRoundHint.selector, R1)); // a later round is <= E
        oracle.finalize(BTC, E, R1);
        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.BadRoundHint.selector, R1 + 2)); // after E
        oracle.finalize(BTC, E, R1 + 2);
        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.BadRoundHint.selector, R1 + 9)); // missing
        oracle.finalize(BTC, E, R1 + 9);
    }

    function test_notBeforeExpiryAndOnlyOnce() public {
        _at(104_000, E - 3 hours);
        vm.warp(E - 1);
        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.NotExpired.selector, E));
        oracle.finalize(BTC, E, R1);
        vm.warp(E);
        oracle.finalize(BTC, E, R1);
        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.AlreadyFinal.selector, BTC, E));
        oracle.finalize(BTC, E, R1);
    }

    function test_spotStaleness() public {
        _at(104_000, NOW);
        (uint256 p,) = oracle.spot(BTC);
        assertEq(p, 104_000e8);
        vm.warp(NOW + 26 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.StalePrice.selector, NOW));
        oracle.spot(BTC);
    }

    function test_governanceOnlyAfterDelay() public {
        vm.warp(E + 71 hours);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.TooEarlyForGovernance.selector, uint256(E) + 72 hours));
        oracle.setGovernancePrice(BTC, E, 104_000e8);

        vm.warp(E + 72 hours);
        vm.prank(admin);
        oracle.setGovernancePrice(BTC, E, 104_000e8);
        (, bool isFinal, IOracleAdapter.PriceSource src) = oracle.settlementPrice(BTC, E);
        assertTrue(isFinal);
        assertEq(uint8(src), uint8(IOracleAdapter.PriceSource.Governance));
    }

    // ---------------------------------------------------------------- API3 backup

    function _withBackup() internal returns (MockApi3Proxy api3) {
        api3 = new MockApi3Proxy(admin);
        vm.prank(admin);
        oracle.setBackupFeed(BTC, IApi3ReaderProxy(address(api3)));
    }

    /// Records one API3 sample every 5 minutes through the window, the price rising by 100 each time.
    function _sampleWindow(MockApi3Proxy api3) internal {
        for (uint256 i; i <= 6; ++i) {
            uint256 t = E - 30 minutes + i * 5 minutes;
            vm.warp(t);
            vm.prank(admin);
            api3.set(int224(int256((100_000 + i * 100) * 1e18)), uint32(t));
            oracle.recordBackup(BTC, E);
        }
    }

    function test_backupAveragesApi3SamplesWhenChainlinkStops() public {
        _at(99_000, E - 2 hours); // Chainlink's last round, before the window
        MockApi3Proxy api3 = _withBackup();
        _sampleWindow(api3);
        vm.warp(E + 1 hours);
        assertEq(oracle.finalizeBackup(BTC, E), 100_300e8, "average of 100 000 .. 100 600");
        (, bool isFinal, IOracleAdapter.PriceSource src) = oracle.settlementPrice(BTC, E);
        assertTrue(isFinal);
        assertEq(uint8(src), uint8(IOracleAdapter.PriceSource.Backup));
    }

    function test_backupRefusedWhileChainlinkUpdates() public {
        MockApi3Proxy api3 = _withBackup();
        _sampleWindow(api3);
        _at(100_000, E - 1 minutes); // Chainlink posted inside the window
        vm.warp(E + 1 hours);
        vm.expectRevert(IOracleAdapter.ChainlinkHealthy.selector);
        oracle.finalizeBackup(BTC, E);
    }

    function test_backupWaitsForDelayAndSamples() public {
        _at(99_000, E - 2 hours);
        MockApi3Proxy api3 = _withBackup();
        vm.warp(E - 10 minutes);
        vm.prank(admin);
        api3.set(int224(int256(100_000e18)), uint32(block.timestamp));
        oracle.recordBackup(BTC, E);
        vm.expectRevert(IOracleAdapter.TooSoon.selector);
        oracle.recordBackup(BTC, E);

        vm.warp(E + 30 minutes);
        vm.expectRevert(IOracleAdapter.TooSoon.selector);
        oracle.finalizeBackup(BTC, E);
        vm.warp(E + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.NotEnoughSamples.selector, 1));
        oracle.finalizeBackup(BTC, E);
    }

    function test_recordOnlyInsideWindow() public {
        MockApi3Proxy api3 = _withBackup();
        vm.warp(E - 31 minutes);
        vm.prank(admin);
        api3.set(int224(int256(100_000e18)), uint32(block.timestamp));
        vm.expectRevert(IOracleAdapter.OutsideWindow.selector);
        oracle.recordBackup(BTC, E);
        vm.warp(E + 1);
        vm.expectRevert(IOracleAdapter.OutsideWindow.selector);
        oracle.recordBackup(BTC, E);
    }
}

contract OracleSequencerTest is BaseTest {
    OracleAdapter internal oracle;
    MockAggregator internal seq;
    uint64 internal constant E = FRI_NOV06;
    uint80 internal constant R1 = (uint80(1) << 64) | 1;

    function setUp() public override {
        super.setUp();
        seq = new MockAggregator(0, "L2 Sequencer Uptime", admin);
        vm.prank(admin);
        seq.pushPriceAt(0, uint64(NOW - 30 days)); // up for a long time
        oracle = new OracleAdapter(admin, registry, AggregatorV3Interface(address(seq)));
    }

    function test_spotRevertsWhileSequencerDown() public {
        vm.startPrank(admin);
        btcFeed.pushPrice(104_000e8);
        seq.pushPrice(1);
        vm.stopPrank();
        vm.expectRevert(IOracleAdapter.SequencerDown.selector);
        oracle.spot(BTC);
    }

    function test_outageInWindowUsesFirstPriceAfterRecovery() public {
        vm.startPrank(admin);
        btcFeed.pushPriceAt(104_000e8, uint64(E - 3 hours));
        seq.pushPriceAt(1, uint64(E - 40 minutes)); // down
        seq.pushPriceAt(0, uint64(E - 10 minutes)); // back up inside the window
        btcFeed.pushPriceAt(108_000e8, uint64(E + 10 minutes)); // inside the grace period
        btcFeed.pushPriceAt(109_000e8, uint64(E + 55 minutes)); // first after grace (E + 50m)
        vm.stopPrank();
        vm.warp(E + 2 hours);

        vm.expectRevert(IOracleAdapter.SequencerIncident.selector);
        oracle.finalize(BTC, E, R1);

        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.BadRoundHint.selector, R1 + 1));
        oracle.finalizeAfterRecovery(BTC, E, R1 + 1);
        assertEq(oracle.finalizeAfterRecovery(BTC, E, R1 + 2), 109_000e8);
    }

    function test_recoveryPathNeedsAnIncident() public {
        vm.startPrank(admin);
        btcFeed.pushPriceAt(104_000e8, uint64(E - 3 hours));
        btcFeed.pushPriceAt(109_000e8, uint64(E + 2 hours));
        vm.stopPrank();
        vm.warp(E + 3 hours);
        vm.expectRevert(IOracleAdapter.NoSequencerIncident.selector);
        oracle.finalizeAfterRecovery(BTC, E, R1 + 1);
        assertEq(oracle.finalize(BTC, E, R1), 104_000e8);
    }
}
