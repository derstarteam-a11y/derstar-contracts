// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

enum OptionType {
    Call,
    Put
}

enum Side {
    Buy,
    Sell
}

enum SeriesState {
    None,
    Active,
    Settled
}

/// @notice One option series. Its ERC-1155 token id is SeriesId.encode(series).
struct Series {
    uint8 underlying; // 0 = BTC, 1 = ETH
    OptionType optType;
    uint64 expiry; // unix seconds, Friday 08:00 UTC
    uint64 strike; // whole USD, e.g. 110000
}

/// @notice Per-underlying trading parameters.
/// One contract = 1 unit of the underlying; sizes are always counted in lots.
struct UnderlyingConfig {
    address collateral; // WBTC / WETH, backs calls
    uint8 collateralDecimals;
    address feed; // Chainlink <ASSET>/USD aggregator
    uint16 lotsPerContract; // 100 for BTC (lot = 0.01), 10 for ETH (lot = 0.1)
    uint32 tickSize; // price step per contract, USDC 6 decimals: 5e6 for BTC, 5e5 for ETH
    uint64 strikeStep; // whole USD: 2000 for BTC, 100 for ETH
    uint16 maxStrikesPerExpiry; // strike grid cap per expiry
    bool enabled;
}

/// @notice One match produced by the order book and executed by Clearing.
struct Fill {
    address maker; // resting order owner, or the vault for a virtual quote
    uint64 orderId; // 0 for a vault quote
    uint32 priceTicks;
    uint64 lots;
    bool fromVault;
}
