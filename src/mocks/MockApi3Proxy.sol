// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IApi3ReaderProxy} from "../interfaces/IApi3ReaderProxy.sol";

/// @notice API3-compatible proxy for tests and testnet demos: the owner sets the value.
contract MockApi3Proxy is IApi3ReaderProxy, Ownable {
    int224 internal _value;
    uint32 internal _timestamp;

    constructor(address owner_) Ownable(owner_) {}

    function set(int224 value, uint32 timestamp) external onlyOwner {
        (_value, _timestamp) = (value, timestamp);
    }

    function read() external view returns (int224, uint32) {
        return (_value, _timestamp);
    }
}
