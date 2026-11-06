# Notes for auditors

Trust assumptions and known behaviour, so review time goes to what is not already known.

## Roles and trust

- **Admin** (mainnet: 2-of-3 Safe behind a 48 h timelock) changes parameters only within bounds set in code. It cannot move user funds or upgrade contracts (no proxies).
- **Guardian** can pause new trades. Withdrawals of free funds, order cancellation, settlement and payouts stay open during a pause.
- **Keeper** holds two roles: series listing (SeriesRegistry) and volatility publication (IvFeed). IvFeed bounds every value and every step (5%–300%, ATM change ≤ 30% per update, |skew| ≤ 3, |curv| ≤ 30, stale after 15 min). The smile is the protocol's main offchain trust point.
- **EXECUTOR_ROLE** on OrderBook is granted only to StopOrders. `takeFor` trades on behalf of a stop's owner: it can spend the owner's USDC allowance to Clearing for a buy-back, bounded by the owner's own limit price and position size.

## Oracles

- Spot reads accept Chainlink prices up to `maxSpotAge` (26 h) old. Chainlink BTC/USD and ETH/USD on Arbitrum update on deviation with a 24 h heartbeat, so an old timestamp normally means the price has not moved past the deviation threshold.
- API3 fallback samples use the same age bound for the same reason (deviation-triggered dAPI with a 24 h heartbeat). A tighter bound would reject valid samples in calm markets and leave the fallback unusable.
- Settlement uses a time-weighted Chainlink TWAP over the 30 minutes before expiry, independent of who calls settlement or when. Order of fallbacks: Chainlink TWAP, API3 average (≥ 5 samples, only when Chainlink has not updated since the window began and 1 h after expiry), first price after a sequencer outage plus grace, governance price after 72 h through the timelock.

## Protocol vaults

- Vaults quote Black–Scholes fair value from Chainlink spot and the IvFeed smile, plus a spread (5%) and a utilisation markup. Quotes can lag the market by up to one Chainlink update and one smile update (3 min); fast moves can let takers trade against a stale quote. Mitigation is operational: per-trade and per-series limits, the per-expiry cap, and spread settings.
- Vaults do not hedge delta. Covered calls and cash-secured puts carry the usual directional risk for depositors.

## Known limitations

- OrderBook, Clearing and ProtocolVault are within about 1–2.5 KB of the 24 KB code size limit.
- Clearing accepts deposits only in USDC and in the collateral tokens of configured underlyings (WBTC, WETH). Fee-on-transfer and rebasing tokens are not supported and are not configured.
- Static analysis: Slither and Aderyn high findings were reviewed; the remaining ones are false positives (calls to the protocol's own contracts under `nonReentrant`, guarded casts, and library code in OpenZeppelin and Solady).
