// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

interface IOptionToken is IERC1155 {
    error NotClearing();
    error ClearingAlreadySet();

    // Clearing only. Called inside the owner's own order or trade, so no token approval is needed.
    function mint(address to, uint256 seriesId, uint256 lots) external;
    function burn(address from, uint256 seriesId, uint256 lots) external;
    function clearingMove(address from, address to, uint256 seriesId, uint256 lots) external;

    function totalSupply(uint256 seriesId) external view returns (uint256);
    function seriesName(uint256 seriesId) external view returns (string memory);
}
