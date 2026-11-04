// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// @notice Chainlink-compatible feed with a full round history, for tests and testnet demos.
/// Round ids follow Chainlink's layout: (phaseId << 64) | aggregatorRoundId.
contract MockAggregator is AggregatorV3Interface, Ownable {
    struct Round {
        int256 answer;
        uint64 updatedAt;
    }

    uint8 public immutable decimals;
    string public description;
    uint256 public constant version = 4;

    uint16 public phaseId = 1;
    uint64 public latestAggregatorRound;
    mapping(uint80 => Round) internal _rounds;

    error NoData();
    error NonMonotonicTime();

    constructor(uint8 decimals_, string memory description_, address owner_) Ownable(owner_) {
        decimals = decimals_;
        description = description_;
    }

    function pushPrice(int256 answer) external onlyOwner {
        _push(answer, uint64(block.timestamp));
    }

    /// @notice Test helper: record a round at a past or current timestamp (must not go backwards).
    function pushPriceAt(int256 answer, uint64 timestamp) external onlyOwner {
        _push(answer, timestamp);
    }

    /// @notice Simulates an aggregator upgrade: a new phase starts at round 1.
    function startNewPhase() external onlyOwner {
        ++phaseId;
        latestAggregatorRound = 0;
    }

    function _push(int256 answer, uint64 timestamp) internal {
        if (latestAggregatorRound != 0) {
            if (timestamp < _rounds[_id(latestAggregatorRound)].updatedAt) revert NonMonotonicTime();
        }
        ++latestAggregatorRound;
        _rounds[_id(latestAggregatorRound)] = Round(answer, timestamp);
    }

    function _id(uint64 aggRound) internal view returns (uint80) {
        return uint80((uint256(phaseId) << 64) | aggRound);
    }

    function getRoundData(uint80 roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = _rounds[roundId];
        if (r.updatedAt == 0) revert NoData();
        return (roundId, r.answer, r.updatedAt, r.updatedAt, roundId);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (latestAggregatorRound == 0) revert NoData();
        return getRoundData(_id(latestAggregatorRound));
    }
}
