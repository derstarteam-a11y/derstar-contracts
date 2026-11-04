// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISpotOracle} from "./ISpotOracle.sol";

interface IOracleAdapter is ISpotOracle {
    enum PriceSource {
        None,
        Twap,
        PostRecovery,
        Governance,
        Backup
    }

    event SettlementPriceSet(uint8 indexed underlying, uint64 indexed expiry, uint256 price1e8, PriceSource source);
    event ParamsSet(uint32 twapWindow, uint32 maxSpotAge, uint32 sequencerGrace, uint32 governanceDelay);
    event BackupFeedSet(uint8 indexed underlying, address proxy);
    event BackupParamsSet(uint32 delay, uint32 minGap, uint16 minSamples);
    event BackupSampled(uint8 indexed underlying, uint64 indexed expiry, uint256 price1e8, uint32 samples);

    error NotExpired(uint64 expiry);
    error AlreadyFinal(uint8 underlying, uint64 expiry);
    error BadRoundHint(uint80 roundId);
    error TooManyRounds();
    error StalePrice(uint256 updatedAt);
    error InvalidPrice();
    error SequencerDown();
    error SequencerIncident();
    error NoSequencerIncident();
    error TooEarlyForGovernance(uint256 allowedAt);
    error InvalidConfig();
    error NoBackupFeed(uint8 underlying);
    error OutsideWindow();
    error TooSoon();
    error ChainlinkHealthy();
    error NotEnoughSamples(uint32 samples);

    /// @notice Normal path: 30-min time-weighted average of Chainlink rounds before expiry.
    /// @param roundHint the last round with updatedAt <= expiry (found off-chain, verified here)
    function finalize(uint8 underlying, uint64 expiry, uint80 roundHint) external returns (uint256 price1e8);

    /// @notice If the sequencer was down in the window: first Chainlink price after it recovered.
    function finalizeAfterRecovery(uint8 underlying, uint64 expiry, uint80 roundId) external returns (uint256 price1e8);

    /// @notice Backup oracle (API3): anyone records the API3 price during the TWAP window,
    /// at most once per `backupMinGap`. The samples become the backup settlement price.
    function recordBackup(uint8 underlying, uint64 expiry) external;

    /// @notice If Chainlink stopped updating (no round since the window opened) and `backupDelay`
    /// has passed after expiry: average of the API3 samples recorded in the window.
    function finalizeBackup(uint8 underlying, uint64 expiry) external returns (uint256 price1e8);

    /// @notice Last resort, Timelock only, once no valid price exists for `governanceDelay`.
    function setGovernancePrice(uint8 underlying, uint64 expiry, uint256 price1e8) external;

    function settlementPrice(uint8 underlying, uint64 expiry)
        external
        view
        returns (uint256 price1e8, bool isFinal, PriceSource source);
}
