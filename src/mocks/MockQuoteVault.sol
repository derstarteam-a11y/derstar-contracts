// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IQuoteVault} from "../interfaces/IQuoteVault.sol";
import {IClearing} from "../interfaces/IClearing.sol";
import {Side} from "../types/DerstarTypes.sol";

/// @notice Vault stand-in with fixed quotes, to test how the book merges virtual liquidity.
/// The real ProtocolVault prices from Black-Scholes and IvFeed.
contract MockQuoteVault is IQuoteVault {
    using SafeERC20 for IERC20;

    IClearing public immutable clearing;
    mapping(uint256 => mapping(Side => uint32)) public price;
    mapping(uint256 => mapping(Side => uint64)) public size;

    constructor(IClearing clearing_) {
        clearing = clearing_;
    }

    function setQuote(uint256 seriesId, Side vaultSide, uint32 priceTicks, uint64 lots) external {
        price[seriesId][vaultSide] = priceTicks;
        size[seriesId][vaultSide] = lots;
    }

    function fund(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).forceApprove(address(clearing), amount);
        clearing.deposit(token, amount);
    }

    function quote(uint256 seriesId, Side vaultSide, uint64) external view returns (uint32, uint64) {
        uint64 avail = size[seriesId][vaultSide];
        // Buying back is capped by what the vault is short, like the real vault.
        if (vaultSide == Side.Buy) {
            uint64 s = clearing.shortOf(address(this), seriesId);
            if (s < avail) avail = s;
        }
        return (price[seriesId][vaultSide], avail);
    }
}
