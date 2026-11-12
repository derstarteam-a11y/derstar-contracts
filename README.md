<div align="center">

# Derstar

**On-chain options exchange on Arbitrum**

Order book · Protocol vaults · Cash settlement · Weekly BTC and ETH options

[![tests](https://github.com/derstarteam-a11y/derstar-contracts/actions/workflows/ci.yml/badge.svg)](https://github.com/derstarteam-a11y/derstar-contracts/actions/workflows/ci.yml)
![Solidity](https://img.shields.io/badge/Solidity-0.8.28-363636)
![Network](https://img.shields.io/badge/network-Arbitrum%20Sepolia-28a0f0)
![Status](https://img.shields.io/badge/status-closed%20testnet-orange)

[App](https://derstar.xyz) · [Docs](https://derstar.gitbook.io/derstar-docs) · [Brand kit](https://derstar.xyz/brand/) · [X](https://x.com/Derstar_options) · [Discord](https://discord.gg/yAawhGKQxP)

</div>

---

## What Derstar is

Derstar is a fully on-chain options exchange. Every order, trade, position and payout lives in
these contracts on Arbitrum; there is no off-chain matching engine and no custody.

- **European BTC and ETH options**, calls and puts, cash-settled.
- **Weekly expiries** every Friday at 08:00 UTC, plus month-end expiries.
- **Central limit order book** with price-time priority. Makers can also quote in implied
  volatility: the order is repriced with Black-Scholes from live spot at every match.
- **Protocol vaults** quote both sides from a fair Black-Scholes price plus a spread, so there is
  liquidity from the first day. A vault fills only when it beats the best resting order.
- **Fully collateralised.** Calls are collateralised and paid out in the underlying (WBTC, WETH),
  puts in USDC. Leftover collateral goes straight back to the writer's wallet at expiry.

## How it works

```mermaid
flowchart LR
    T[Trader wallet] -->|orders, market buy/sell, strategies| OB[OrderBook]
    T -->|stop-loss| S[StopOrders]
    S -->|closes at market| OB
    OB -->|asks for a quote| V[ProtocolVault x3]
    OB -->|fills| C[Clearing]
    C -->|mints / burns longs| OT[OptionToken ERC-1155]
    C --> R[SeriesRegistry]
    V -->|fair price| IV[IvFeed]
    V -->|spot| O[OracleAdapter]
    C -->|settlement price| O
    O --> CL[Chainlink BTC/USD, ETH/USD]
    O -.backup.-> A3[API3]
    K[Keeper] -->|lists expiries, pushes vols, settles| R
    K --> IV
    K --> C
    K -->|fires due stops| S
```

1. The keeper lists the coming Fridays with a strike grid around spot and publishes an
   implied-volatility smile per expiry.
2. Traders place limit orders or take liquidity. One Sell button both closes a long and writes a
   new option against collateral; one Buy button covers a short first. Strategies (spreads,
   straddles, strangles) fill in one transaction with `takeLegs`: every leg in full or nothing.
   A stop-loss closes a position at market once its model mark crosses the owner's trigger,
   never worse than the owner's limit and never for more than the owner holds.
3. Trading stops 30 minutes before expiry. The settlement price is a 30-minute TWAP walked from
   Chainlink rounds, with an API3 backup if Chainlink stops updating.
4. Anyone can call settlement: holders are paid the intrinsic value, writers get the rest of their
   collateral back. Every step is permissionless and idempotent.

## Deployed contracts (Arbitrum Sepolia)

Closed testnet, deployed 31 Oct 2026 (block 324535483).

| Contract | Address | Role |
|---|---|---|
| SeriesRegistry | [`0x6FD72d25907b1D7ef31Ad50d83793B346bA411BC`](https://sepolia.arbiscan.io/address/0x6FD72d25907b1D7ef31Ad50d83793B346bA411BC) | Underlyings, weekly calendar, strike grid, trading cutoff |
| Clearing | [`0xd284fb4757E2032A087F57F5C5383C8EE5DDc67C`](https://sepolia.arbiscan.io/address/0xd284fb4757E2032A087F57F5C5383C8EE5DDc67C) | Balances, collateral, fills, fees, settlement and payouts |
| OrderBook | [`0xa33932121F627B490dfC8663525bc0c3fc108Ad8`](https://sepolia.arbiscan.io/address/0xa33932121F627B490dfC8663525bc0c3fc108Ad8) | Limit and vol orders, price-time priority, market buy/sell |
| StopOrders | [`0x272037cBcdB3893fFe29f2aa8341f37F194dd6d7`](https://sepolia.arbiscan.io/address/0x272037cBcdB3893fFe29f2aa8341f37F194dd6d7) | Stop-loss orders, executed by the keeper at market |
| OptionToken | [`0xD9c03B095BfD60e9cD9649D60452573c97609A7B`](https://sepolia.arbiscan.io/address/0xD9c03B095BfD60e9cD9649D60452573c97609A7B) | ERC-1155 long positions (id = series id) |
| OracleAdapter | [`0x2FFA67EaFE9deD60714cB9809c22393e754F17aB`](https://sepolia.arbiscan.io/address/0x2FFA67EaFE9deD60714cB9809c22393e754F17aB) | Chainlink spot, 30-min settlement TWAP, API3 backup |
| IvFeed | [`0xfF26Aa7DB7882EfA20D2D260C4b78bBFa7C6BDA3`](https://sepolia.arbiscan.io/address/0xfF26Aa7DB7882EfA20D2D260C4b78bBFa7C6BDA3) | Implied-vol smile per expiry |
| ProtocolVault (BTC calls) | [`0x2BE0BFDbA6d682F05F9C3A760616b23B200177A7`](https://sepolia.arbiscan.io/address/0x2BE0BFDbA6d682F05F9C3A760616b23B200177A7) | Quotes BTC calls, collateral tWBTC |
| ProtocolVault (ETH calls) | [`0x81C878D2dA15Ae4999fCdd75225d7f01dCA99AA9`](https://sepolia.arbiscan.io/address/0x81C878D2dA15Ae4999fCdd75225d7f01dCA99AA9) | Quotes ETH calls, collateral tWETH |
| ProtocolVault (puts) | [`0xb616e1AB179cA71f518a3A609301621602894a46`](https://sepolia.arbiscan.io/address/0xb616e1AB179cA71f518a3A609301621602894a46) | Quotes BTC and ETH puts, collateral tUSDC |
| tUSDC / tWBTC / tWETH | [`0x965e5368c8E75A23E3E1eD6e80a47B78874d6b9c`](https://sepolia.arbiscan.io/address/0x965e5368c8E75A23E3E1eD6e80a47B78874d6b9c) [`0xd1eb2997F5bdFbe1Fe734C329A725811adEfd2b6`](https://sepolia.arbiscan.io/address/0xd1eb2997F5bdFbe1Fe734C329A725811adEfd2b6) [`0x6018c44D38e4b540da8c0791Ea2e1E298b8FB522`](https://sepolia.arbiscan.io/address/0x6018c44D38e4b540da8c0791Ea2e1E298b8FB522) | Test tokens with a daily faucet |
| TestnetAccess | [`0x1376dBB6479208096eDB7d92CC12c434977EfC96`](https://sepolia.arbiscan.io/address/0x1376dBB6479208096eDB7d92CC12c434977EfC96) | Invite list for the closed testnet faucets |

Price feeds: Chainlink BTC/USD [`0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69`](https://sepolia.arbiscan.io/address/0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69), ETH/USD [`0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165`](https://sepolia.arbiscan.io/address/0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165).

## Fees

| | |
|---|---|
| Taker | 0.03% of notional, capped at 12.5% of premium |
| Maker | 0.015% of notional, capped at 12.5% of premium |
| Settlement | 0.015% of notional per side at expiry |

Notional is Chainlink spot × contracts.

## Safety

- **163 tests**, including fuzzing and an invariant suite that runs thousands of random orders,
  trades, cancels and transfers and checks that Clearing stays exactly solvent and that
  `totalSupply == totalShort` for every series.
- Price inputs are checked for staleness and for the Arbitrum sequencer being down; the vaults
  stop quoting when spot or volatility is stale.
- Governance for mainnet: every admin role moves to a 48-hour Timelock run by the team Safe
  (`script/HandoffGovernance.s.sol`); the deployer keeps no role.
- **Not audited yet.** This is a testnet. Do not use these contracts with real funds.

## Repository

```
src/core/        Clearing, OrderBook, StopOrders, SeriesRegistry, OptionToken, OracleAdapter, IvFeed, ProtocolVault, FeeCollector
src/libraries/   BlackScholes (on-chain, ~18k gas), ExpiryCalendar, TickBitmap, SeriesId
src/interfaces/  External interfaces
src/mocks/       Test tokens, mock feeds, TestnetAccess
test/            Foundry tests, fuzz and invariants
script/          Testnet deploy and admin scripts, mainnet governance handoff
deployments/     Deployed addresses per chain
```

## Build and test

Requires Node 22 and [Foundry](https://getfoundry.sh).

```bash
npm install
forge build
forge test
```

## Units

- Sizes in lots: 1 BTC lot = 0.01 contract, 1 ETH lot = 0.1 contract.
- Prices in ticks per contract: BTC tick = 5 USDC, ETH tick = 0.5 USDC.
- Series id packs `[underlying:8 | optType:8 | expiry:64 | strike:64]`.

## License

Copyright © 2026 Derstar. All rights reserved. The source is published for transparency and
review; see [LICENSE](LICENSE).

Security issues: write to derstar.team@gmail.com.
