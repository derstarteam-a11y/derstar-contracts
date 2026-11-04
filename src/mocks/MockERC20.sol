// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface ITestnetAccess {
    function allowed(address account) external view returns (bool);
}

/// @notice Testnet stand-in for WBTC / WETH / USDC with a rate-limited faucet.
contract MockERC20 is ERC20, ERC20Permit, Ownable {
    uint8 private immutable _decimals;
    uint256 public faucetAmount;
    uint256 public faucetCooldown = 1 days;
    mapping(address => uint256) public lastDrip;
    /// @notice Unset: anyone may use the faucet. Set: only wallets it allows (closed testnet).
    ITestnetAccess public access;

    error FaucetCooldown(uint256 availableAt);
    error NotInvited(address account);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 faucetAmount_, address owner_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
        Ownable(owner_)
    {
        _decimals = decimals_;
        faucetAmount = faucetAmount_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function faucet() external {
        if (address(access) != address(0) && !access.allowed(msg.sender)) revert NotInvited(msg.sender);
        uint256 next = lastDrip[msg.sender] + faucetCooldown;
        if (lastDrip[msg.sender] != 0 && block.timestamp < next) revert FaucetCooldown(next);
        lastDrip[msg.sender] = block.timestamp;
        _mint(msg.sender, faucetAmount);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function setAccess(ITestnetAccess access_) external onlyOwner {
        access = access_;
    }

    function setFaucet(uint256 amount, uint256 cooldown) external onlyOwner {
        faucetAmount = amount;
        faucetCooldown = cooldown;
    }
}
