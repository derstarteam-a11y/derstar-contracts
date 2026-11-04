// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice Closed testnet: which wallets may draw test tokens from the faucets. The backend's
/// gatekeeper adds a wallet once it redeems an invite code; the admin can add or remove wallets
/// directly, or open the faucets to everyone. Test tokens stay transferable.
contract TestnetAccess is AccessControl {
    bytes32 public constant GATEKEEPER_ROLE = keccak256("GATEKEEPER_ROLE");

    mapping(address => bool) public isAllowed;
    /// @notice True: every wallet may use the faucets.
    bool public openToAll;

    event AccessSet(address indexed account, bool allowed);
    event OpenToAll(bool open);

    constructor(address admin, address gatekeeper) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GATEKEEPER_ROLE, admin);
        if (gatekeeper != address(0)) _grantRole(GATEKEEPER_ROLE, gatekeeper);
    }

    function allowed(address account) external view returns (bool) {
        return openToAll || isAllowed[account];
    }

    function grant(address[] calldata accounts) external onlyRole(GATEKEEPER_ROLE) {
        for (uint256 i; i < accounts.length; ++i) {
            isAllowed[accounts[i]] = true;
            emit AccessSet(accounts[i], true);
        }
    }

    function revoke(address[] calldata accounts) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i; i < accounts.length; ++i) {
            isAllowed[accounts[i]] = false;
            emit AccessSet(accounts[i], false);
        }
    }

    function setOpenToAll(bool open) external onlyRole(DEFAULT_ADMIN_ROLE) {
        openToAll = open;
        emit OpenToAll(open);
    }
}
