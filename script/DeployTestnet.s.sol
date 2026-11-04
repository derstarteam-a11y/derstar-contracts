// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SeriesRegistry} from "../src/core/SeriesRegistry.sol";
import {OptionToken} from "../src/core/OptionToken.sol";
import {OracleAdapter} from "../src/core/OracleAdapter.sol";
import {IvFeed} from "../src/core/IvFeed.sol";
import {Clearing} from "../src/core/Clearing.sol";
import {OrderBook} from "../src/core/OrderBook.sol";
import {ProtocolVault} from "../src/core/ProtocolVault.sol";
import {IClearing} from "../src/interfaces/IClearing.sol";
import {ISeriesRegistry} from "../src/interfaces/ISeriesRegistry.sol";
import {IOracleAdapter} from "../src/interfaces/IOracleAdapter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {IApi3ReaderProxy} from "../src/interfaces/IApi3ReaderProxy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {TestnetAccess} from "../src/mocks/TestnetAccess.sol";
import {ITestnetAccess} from "../src/mocks/MockERC20.sol";
import {UnderlyingConfig, OptionType} from "../src/types/DerstarTypes.sol";

/// @notice Testnet deploy of the whole protocol: test tokens, registry, option token, oracle,
/// IV feed, clearing, order book (with vol orders) and three protocol vaults (BTC calls on tWBTC,
/// ETH calls on tWETH, puts on both in tUSDC), wired together. With SEED_VAULTS=true (default)
/// the deployer mints test tokens and seeds each vault so it quotes as soon as the keeper pushes
/// vols. Mock feeds start at BTC_PRICE / ETH_PRICE (whole dollars, default 104 000 / 3 100).
/// Env: PRIVATE_KEY, KEEPER (address), DEMO_INTERVAL (seconds, 0 = Friday calendar),
/// BTC_FEED / ETH_FEED (Chainlink on Arbitrum Sepolia; empty = deploy mock feeds the keeper
/// pushes to), SEQUENCER_FEED (Chainlink L2 uptime feed; empty = no sequencer checks),
/// FEE_RECIPIENT (default: deployer), BTC_API3 / ETH_API3 (API3 dAPI proxies for the backup
/// oracle; empty = no backup), CLOSED_TESTNET (default true: faucets only for invited wallets),
/// GATEKEEPER (backend wallet that admits wallets redeeming an invite code), USDC / WBTC / WETH /
/// ACCESS (existing test tokens and invite list to keep on a redeploy). KEEPER gets the
/// series and IV publisher roles and owns the mock feeds; the deployer stays admin (testnet runs on one team wallet; mainnet hands the roles
/// to the Safe and Timelock with HandoffGovernance.s.sol).
contract DeployTestnet is Script {
    address internal deployer;
    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockERC20 internal weth;
    TestnetAccess internal access;
    address internal btcFeed;
    address internal ethFeed;
    SeriesRegistry internal registry;
    OptionToken internal token;
    OracleAdapter internal oracle;
    IvFeed internal ivFeed;
    Clearing internal clearing;
    OrderBook internal book;
    ProtocolVault internal btcCalls;
    ProtocolVault internal ethCalls;
    ProtocolVault internal puts;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(pk);
        vm.startBroadcast(pk);
        _deployCore();
        _deployVaults();
        if (vm.envOr("SEED_VAULTS", true)) {
            _seed(btcCalls, wbtc, 10e8);
            _seed(ethCalls, weth, 150e18);
            _seed(puts, usdc, 2_000_000e6);
            // Call vaults earn premium in USDC only once they sell; a starting balance lets them bid
            // on the calls traders write against a pledged long (bull call spreads) from day one.
            _donate(btcCalls, 100_000e6);
            _donate(ethCalls, 100_000e6);
        }
        vm.stopBroadcast();
        _log();
        _writeDeployment();
    }

    /// @dev Addresses for the backend (keepers, indexer, API): deployments/<chainId>.json.
    function _writeDeployment() internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "usdc", address(usdc));
        vm.serializeAddress(k, "wbtc", address(wbtc));
        vm.serializeAddress(k, "weth", address(weth));
        vm.serializeAddress(k, "access", address(access));
        vm.serializeAddress(k, "btcFeed", btcFeed);
        vm.serializeAddress(k, "ethFeed", ethFeed);
        vm.serializeBool(k, "mockFeeds", vm.envOr("BTC_FEED", address(0)) == address(0));
        vm.serializeAddress(k, "registry", address(registry));
        vm.serializeAddress(k, "optionToken", address(token));
        vm.serializeAddress(k, "oracle", address(oracle));
        vm.serializeAddress(k, "ivFeed", address(ivFeed));
        vm.serializeAddress(k, "clearing", address(clearing));
        vm.serializeAddress(k, "orderBook", address(book));
        vm.serializeAddress(k, "vaultBtcCalls", address(btcCalls));
        vm.serializeAddress(k, "vaultEthCalls", address(ethCalls));
        vm.serializeAddress(k, "vaultPuts", address(puts));
        string memory json = vm.serializeUint(k, "demoInterval", registry.demoInterval());
        vm.createDir("deployments", true);
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }

    function _deployCore() internal {
        address keeper = vm.envOr("KEEPER", deployer);
        // forge-lint: disable-next-line(unsafe-typecast) -- operator-supplied seconds
        uint32 demoInterval = uint32(vm.envOr("DEMO_INTERVAL", uint256(0)));
        btcFeed = vm.envOr("BTC_FEED", address(0));
        ethFeed = vm.envOr("ETH_FEED", address(0));

        // A redeploy can keep the test tokens and the invite list (USDC / WBTC / WETH / ACCESS set),
        // so testers keep their balances and invited wallets stay in.
        if (vm.envOr("USDC", address(0)) != address(0)) {
            usdc = MockERC20(vm.envAddress("USDC"));
            wbtc = MockERC20(vm.envAddress("WBTC"));
            weth = MockERC20(vm.envAddress("WETH"));
            access = TestnetAccess(vm.envOr("ACCESS", address(0)));
        } else {
            usdc = new MockERC20("Derstar Test USDC", "tUSDC", 6, 100_000e6, deployer);
            wbtc = new MockERC20("Derstar Test WBTC", "tWBTC", 8, 1e8, deployer);
            weth = new MockERC20("Derstar Test WETH", "tWETH", 18, 10e18, deployer);
            // Closed testnet (CLOSED_TESTNET=true, default): faucets serve invited wallets only.
            // GATEKEEPER is the backend wallet that adds a wallet when it redeems an invite code.
            if (vm.envOr("CLOSED_TESTNET", true)) {
                access = new TestnetAccess(deployer, vm.envOr("GATEKEEPER", address(0)));
                usdc.setAccess(ITestnetAccess(address(access)));
                wbtc.setAccess(ITestnetAccess(address(access)));
                weth.setAccess(ITestnetAccess(address(access)));
            }
        }
        // Mock feeds owned by the deployer get a first price so spot reads work immediately.
        if (btcFeed == address(0)) {
            MockAggregator f = new MockAggregator(8, "BTC / USD", deployer);
            f.pushPrice(int256(vm.envOr("BTC_PRICE", uint256(104_000))) * 1e8);
            btcFeed = address(f);
            if (keeper != deployer) f.transferOwnership(keeper); // the keeper pushes spot
        }
        if (ethFeed == address(0)) {
            MockAggregator f = new MockAggregator(8, "ETH / USD", deployer);
            f.pushPrice(int256(vm.envOr("ETH_PRICE", uint256(3_100))) * 1e8);
            ethFeed = address(f);
            if (keeper != deployer) f.transferOwnership(keeper); // the keeper pushes spot
        }

        registry = new SeriesRegistry(deployer, address(usdc), demoInterval, demoInterval == 0 ? 75 days : 7 days);
        // Short demo expiries (hours) need a finer grid and tick than weeklies.
        bool short_ = demoInterval != 0 && demoInterval < 1 days;
        registry.setUnderlying(
            0,
            "BTC",
            UnderlyingConfig(address(wbtc), 8, btcFeed, 100, short_ ? 1e6 : 5e6, short_ ? 500 : 2000, 21, true)
        );
        registry.setUnderlying(
            1, "ETH", UnderlyingConfig(address(weth), 18, ethFeed, 10, short_ ? 1e5 : 5e5, short_ ? 25 : 100, 21, true)
        );
        registry.grantRole(registry.SERIES_ROLE(), keeper);
        token = new OptionToken(registry);

        oracle = new OracleAdapter(deployer, registry, AggregatorV3Interface(vm.envOr("SEQUENCER_FEED", address(0))));
        if (vm.envOr("BTC_API3", address(0)) != address(0)) {
            oracle.setBackupFeed(0, IApi3ReaderProxy(vm.envAddress("BTC_API3")));
        }
        if (vm.envOr("ETH_API3", address(0)) != address(0)) {
            oracle.setBackupFeed(1, IApi3ReaderProxy(vm.envAddress("ETH_API3")));
        }
        ivFeed = new IvFeed(deployer, keeper);
        clearing = new Clearing(deployer, registry, token, oracle, vm.envOr("FEE_RECIPIENT", deployer));
        book = new OrderBook(deployer, registry, clearing);
        registry.setClearing(address(clearing));
        token.setClearing(address(clearing));
        clearing.setOrderBook(address(book));
        book.setVolPricing(oracle, 2 hours, 64);
        if (short_) {
            // Hourly options: trade until 10 minutes before expiry, settle on a 10-minute TWAP.
            registry.setTradingCutoff(10 minutes);
            oracle.setParams(10 minutes, oracle.maxSpotAge(), oracle.sequencerGrace(), oracle.governanceDelay());
        }
    }

    function _deployVaults() internal {
        btcCalls = _vault("Derstar BTC Call Vault", "dvBTCc", address(wbtc), OptionType.Call, 0);
        ethCalls = _vault("Derstar ETH Call Vault", "dvETHc", address(weth), OptionType.Call, 1);
        puts = _vault("Derstar Put Vault", "dvPUT", address(usdc), OptionType.Put, 0);
        puts.setServes(1, true);
        book.setVaultFor(1, uint8(OptionType.Put), address(puts));
    }

    /// @dev A vault for one option type; a call vault serves its own underlying only.
    function _vault(string memory name, string memory symbol, address asset, OptionType optType, uint8 underlying)
        internal
        returns (ProtocolVault v)
    {
        v = new ProtocolVault(
            name,
            symbol,
            deployer,
            IClearing(address(clearing)),
            ISeriesRegistry(address(registry)),
            IOracleAdapter(address(oracle)),
            ivFeed,
            asset,
            optType,
            underlying
        );
        v.setServes(underlying, true);
        // Demo expiries are hours apart: let the vault quote until the trading cutoff.
        uint32 di = registry.demoInterval();
        if (di != 0) v.setRisk(500, 2_000, 1_000, 200, di < 1 days ? 10 minutes : 30 minutes, 2 hours, 5_000);
        clearing.setVault(address(v), true);
        book.setVaultFor(underlying, uint8(optType), address(v));
    }

    /// @dev First deposit: an empty vault rolls at once, so the shares are minted right away.
    function _seed(ProtocolVault v, MockERC20 tkn, uint256 amount) internal {
        tkn.mint(deployer, amount);
        tkn.approve(address(v), amount);
        v.requestDeposit(amount);
        v.rollEpoch(0);
        v.claim();
    }

    function _donate(ProtocolVault v, uint256 amount) internal {
        usdc.mint(deployer, amount);
        usdc.approve(address(v), amount);
        v.donateUsdc(amount);
    }

    function _log() internal view {
        console2.log("tUSDC", address(usdc));
        console2.log("tWBTC", address(wbtc));
        console2.log("tWETH", address(weth));
        console2.log("BTC feed", btcFeed);
        console2.log("ETH feed", ethFeed);
        console2.log("SeriesRegistry", address(registry));
        console2.log("OptionToken", address(token));
        console2.log("OracleAdapter", address(oracle));
        console2.log("IvFeed", address(ivFeed));
        console2.log("Clearing", address(clearing));
        console2.log("OrderBook", address(book));
        console2.log("Vault BTC calls", address(btcCalls));
        console2.log("Vault ETH calls", address(ethCalls));
        console2.log("Vault puts", address(puts));
    }
}
