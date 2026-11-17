// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAgentRegistry} from "../interfaces/IAgentRegistry.sol";

/// @title AgentRegistry
/// @notice API wallets. An account names agent keys (a trading bot's hot key) and how long each may
/// act. OrderBook (through execAs) and StopOrders let an agent trade in the account's name: place,
/// replace and cancel orders and stops, and take liquidity, all with the account's own funds. An
/// agent cannot withdraw, transfer tokens or name other agents: those need the account's own key.
/// So a leaked bot key can trade badly but cannot take the funds out.
///
/// Holds no funds and has no admin: each account manages only its own agents.
contract AgentRegistry is IAgentRegistry {
    /// @notice Time until which `agent` may act for `account`; 0 = not an agent.
    mapping(address account => mapping(address agent => uint64)) public agentUntil;

    /// @notice Lets `agent` trade for the caller until `validUntil` (unix seconds); 0 revokes at once.
    function setAgent(address agent, uint64 validUntil) external {
        if (agent == address(0) || agent == msg.sender) revert InvalidAgent(agent);
        if (validUntil != 0 && validUntil <= block.timestamp) revert InvalidExpiry(validUntil);
        agentUntil[msg.sender][agent] = validUntil;
        emit AgentSet(msg.sender, agent, validUntil);
    }

    function isAgent(address account, address agent) external view returns (bool) {
        return agentUntil[account][agent] >= block.timestamp;
    }
}
