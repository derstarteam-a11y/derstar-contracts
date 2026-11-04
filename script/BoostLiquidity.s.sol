// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ProtocolVault} from "../src/core/ProtocolVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Testnet: deeper vault liquidity. Raises the per-series and per-trade limits of the three
/// protocol vaults and adds test tokens, so larger orders fill in one go.
///
/// What changes, per vault (sizes in lots: BTC 100 lots = 1 contract, ETH 10 lots = 1 contract):
///   - setRisk: MAX_OI lots per series (default 5 000: 50 BTC or 500 ETH contracts) and MAX_TRADE
///     lots per trade (default 1 000: 10 BTC or 100 ETH contracts). Spread, utilisation markup,
///     time-to-expiry cutoff, spot age and the per-expiry cap stay as they are. Works at once.
///   - Put vault: PUT_USDC tUSDC (default 3 000 000) donated, i.e. collateral that works at once.
///   - Call vaults: CALL_WBTC tWBTC (default 20) and CALL_WETH tWETH (default 300) deposited by the
///     deployer. Deposits join at the vault's next epoch roll (after the next weekly expiry settles);
///     plus CALL_USDC tUSDC (default 100 000) donated to each, so they can also buy back at once.
/// Any amount set to 0 is skipped.
///
/// Run from the deployer wallet (it owns the test tokens and is the vaults' admin):
///   forge script script/BoostLiquidity.s.sol --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
/// or with a keystore account: --account <name> --sender <deployer address>.
/// Without --broadcast it is a dry run that prints what would change.
contract BoostLiquidity is Script {
    address internal me;

    function run() external {
        string memory path = vm.envOr("DEPLOYMENT", string("deployments/421614.json"));
        string memory json = vm.readFile(path);
        ProtocolVault btcCalls = ProtocolVault(vm.parseJsonAddress(json, ".vaultBtcCalls"));
        ProtocolVault ethCalls = ProtocolVault(vm.parseJsonAddress(json, ".vaultEthCalls"));
        ProtocolVault puts = ProtocolVault(vm.parseJsonAddress(json, ".vaultPuts"));
        MockERC20 usdc = MockERC20(vm.parseJsonAddress(json, ".usdc"));
        MockERC20 wbtc = MockERC20(vm.parseJsonAddress(json, ".wbtc"));
        MockERC20 weth = MockERC20(vm.parseJsonAddress(json, ".weth"));

        uint64 maxOI = uint64(vm.envOr("MAX_OI", uint256(5_000)));
        uint64 maxTrade = uint64(vm.envOr("MAX_TRADE", uint256(1_000)));
        uint256 putUsdc = vm.envOr("PUT_USDC", uint256(3_000_000)) * 1e6;
        uint256 callUsdc = vm.envOr("CALL_USDC", uint256(100_000)) * 1e6;
        uint256 callWbtc = vm.envOr("CALL_WBTC", uint256(20)) * 1e8;
        uint256 callWeth = vm.envOr("CALL_WETH", uint256(300)) * 1e18;

        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        me = pk != 0 ? vm.addr(pk) : msg.sender;
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();

        ProtocolVault[3] memory vaults = [btcCalls, ethCalls, puts];
        for (uint256 i; i < 3; ++i) {
            ProtocolVault v = vaults[i];
            console2.log(v.name());
            console2.log("  max lots per series", v.maxOIPerSeries(), "->", maxOI);
            console2.log("  max lots per trade ", v.maxLotsPerTrade(), "->", maxTrade);
            v.setRisk(
                v.spreadBps(), v.utilBps(), maxOI, maxTrade, v.minTimeToExpiry(), v.maxSpotAge(), v.maxExpiryBps()
            );
        }

        if (putUsdc > 0) _donate(usdc, puts, putUsdc);
        if (callUsdc > 0) {
            _donate(usdc, btcCalls, callUsdc);
            _donate(usdc, ethCalls, callUsdc);
        }
        if (callWbtc > 0) _deposit(wbtc, btcCalls, callWbtc);
        if (callWeth > 0) _deposit(weth, ethCalls, callWeth);

        vm.stopBroadcast();
    }

    function _donate(MockERC20 usdc, ProtocolVault v, uint256 amount) internal {
        usdc.mint(me, amount);
        usdc.approve(address(v), amount);
        v.donateUsdc(amount);
        console2.log("  donated tUSDC (whole)", amount / 1e6, "to", v.name());
    }

    function _deposit(MockERC20 tkn, ProtocolVault v, uint256 amount) internal {
        tkn.mint(me, amount);
        tkn.approve(address(v), amount);
        v.requestDeposit(amount);
        console2.log("  deposit requested (joins at the next roll), raw units", amount, v.name());
    }
}
