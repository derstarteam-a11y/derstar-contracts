// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SeriesRegistry} from "../src/core/SeriesRegistry.sol";
import {OptionToken} from "../src/core/OptionToken.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {UnderlyingConfig} from "../src/types/DerstarTypes.sol";

abstract contract BaseTest is Test {
    uint8 internal constant BTC = 0;
    uint8 internal constant ETH = 1;

    // Wed 2026-10-21 12:00 UTC
    uint256 internal constant NOW = 1792584000;
    uint64 internal constant FRI_OCT30 = 1793347200; // last Friday of October
    uint64 internal constant FRI_NOV06 = 1793952000; // weekly
    uint64 internal constant FRI_NOV27 = 1795766400; // monthly (last Friday)
    uint64 internal constant THU_NOV26 = 1795680000;

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal clearing = makeAddr("clearing");
    address internal alice = makeAddr("alice");

    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockERC20 internal weth;
    MockAggregator internal btcFeed;
    MockAggregator internal ethFeed;
    SeriesRegistry internal registry;
    OptionToken internal token;

    function setUp() public virtual {
        vm.warp(NOW);
        usdc = new MockERC20("USD Coin", "USDC", 6, 100_000e6, admin);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8, 1e8, admin);
        weth = new MockERC20("Wrapped Ether", "WETH", 18, 10e18, admin);
        btcFeed = new MockAggregator(8, "BTC / USD", admin);
        ethFeed = new MockAggregator(8, "ETH / USD", admin);

        registry = new SeriesRegistry(admin, address(usdc), 0, 75 days);
        vm.startPrank(admin);
        registry.setUnderlying(BTC, "BTC", btcConfig());
        registry.setUnderlying(ETH, "ETH", ethConfig());
        registry.grantRole(registry.SERIES_ROLE(), keeper);
        vm.stopPrank();

        token = new OptionToken(registry);
        _wire();
    }

    /// @dev Default: a plain address plays Clearing. Trading tests deploy the real one.
    function _wire() internal virtual {
        vm.prank(admin);
        registry.setClearing(clearing);
        token.setClearing(clearing);
    }

    function btcConfig() internal view returns (UnderlyingConfig memory) {
        return UnderlyingConfig({
            collateral: address(wbtc),
            collateralDecimals: 8,
            feed: address(btcFeed),
            lotsPerContract: 100,
            tickSize: 5e6,
            strikeStep: 2000,
            maxStrikesPerExpiry: 21,
            enabled: true
        });
    }

    function ethConfig() internal view returns (UnderlyingConfig memory) {
        return UnderlyingConfig({
            collateral: address(weth),
            collateralDecimals: 18,
            feed: address(ethFeed),
            lotsPerContract: 10,
            tickSize: 5e5,
            strikeStep: 100,
            maxStrikesPerExpiry: 21,
            enabled: true
        });
    }

    function strikes(uint64 a, uint64 b, uint64 c) internal pure returns (uint64[] memory s) {
        s = new uint64[](3);
        (s[0], s[1], s[2]) = (a, b, c);
    }
}
