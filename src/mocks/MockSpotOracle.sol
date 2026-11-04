// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISpotOracle} from "../interfaces/ISpotOracle.sol";

/// @notice Fixed spot prices for tests until OracleAdapter lands.
contract MockSpotOracle is ISpotOracle {
    mapping(uint8 => uint256) public price;

    function set(uint8 underlying, uint256 price1e8) external {
        price[underlying] = price1e8;
    }

    function spot(uint8 underlying) external view returns (uint256, uint256) {
        return (price[underlying], block.timestamp);
    }
}
