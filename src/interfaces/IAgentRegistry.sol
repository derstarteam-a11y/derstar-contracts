// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice API wallets: keys an account lets trade for it, each until a set time.
interface IAgentRegistry {
    event AgentSet(address indexed account, address indexed agent, uint64 validUntil);

    error InvalidAgent(address agent);
    error InvalidExpiry(uint64 validUntil);

    function setAgent(address agent, uint64 validUntil) external;
    function agentUntil(address account, address agent) external view returns (uint64);
    function isAgent(address account, address agent) external view returns (bool);
}
