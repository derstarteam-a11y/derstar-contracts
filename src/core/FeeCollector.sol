// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IClearing} from "../interfaces/IClearing.sol";

/// @title FeeCollector
/// @notice Clearing's fee recipient on mainnet. Anyone can sweep accrued fees from Clearing into
/// this contract; only the owner (the Timelock) can send them on, so every treasury payout is
/// public 48 hours before it happens.
contract FeeCollector is Ownable {
    using SafeERC20 for IERC20;

    IClearing public immutable clearing;

    event Swept(address indexed token, uint256 amount);
    event Paid(address indexed token, address indexed to, uint256 amount);

    constructor(IClearing clearing_, address owner_) Ownable(owner_) {
        clearing = clearing_;
    }

    /// @notice Moves this contract's whole free balance of `token` out of Clearing.
    function sweep(address token) external returns (uint256 amount) {
        amount = clearing.freeBalance(address(this), token);
        if (amount > 0) clearing.withdraw(token, amount);
        emit Swept(token, amount);
    }

    function pay(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
        emit Paid(token, to, amount);
    }
}
