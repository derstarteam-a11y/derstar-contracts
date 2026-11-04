// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice API3 dAPI proxy (Api3ReaderProxyV1). Values have 18 decimals.
interface IApi3ReaderProxy {
    function read() external view returns (int224 value, uint32 timestamp);
}
