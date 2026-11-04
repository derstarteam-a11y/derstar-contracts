// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";
import {LibString} from "solady/utils/LibString.sol";
import {IOptionToken} from "../interfaces/IOptionToken.sol";
import {ISeriesRegistry} from "../interfaces/ISeriesRegistry.sol";
import {Series, OptionType} from "../types/DerstarTypes.sol";
import {SeriesId} from "../libraries/SeriesId.sol";

/// @title OptionToken
/// @notice A long option position. Token id = series id, balance = lots.
/// Only Clearing mints, burns and moves tokens on behalf of trades. Those internal moves skip
/// the ERC-1155 receiver callback, so a trade can't be re-entered or blocked by the receiver.
/// Ordinary transfers between users work as in any ERC-1155.
contract OptionToken is ERC1155Supply, IOptionToken {
    ISeriesRegistry public immutable registry;
    address public immutable deployer;
    address public clearing;

    modifier onlyClearing() {
        if (msg.sender != clearing) revert NotClearing();
        _;
    }

    constructor(ISeriesRegistry registry_) ERC1155("") {
        registry = registry_;
        deployer = msg.sender;
    }

    /// @notice One-time wiring by the deployer: Clearing is deployed after the token.
    function setClearing(address clearing_) external {
        if (msg.sender != deployer) revert NotClearing();
        if (clearing != address(0)) revert ClearingAlreadySet();
        clearing = clearing_;
    }

    function mint(address to, uint256 seriesId, uint256 lots) external onlyClearing {
        _update(address(0), to, _one(seriesId), _one(lots));
    }

    function burn(address from, uint256 seriesId, uint256 lots) external onlyClearing {
        _update(from, address(0), _one(seriesId), _one(lots));
    }

    function clearingMove(address from, address to, uint256 seriesId, uint256 lots) external onlyClearing {
        _update(from, to, _one(seriesId), _one(lots));
    }

    function totalSupply(uint256 seriesId) public view override(ERC1155Supply, IOptionToken) returns (uint256) {
        return ERC1155Supply.totalSupply(seriesId);
    }

    /// @notice Human-readable name, e.g. "BTC-27NOV26-110000-C".
    function seriesName(uint256 seriesId) public view returns (string memory) {
        Series memory s = SeriesId.decode(seriesId);
        (uint256 y, uint256 m, uint256 d) = DateTimeLib.timestampToDate(s.expiry);
        string memory day = d < 10 ? string.concat("0", LibString.toString(d)) : LibString.toString(d);
        string memory yy = LibString.toString(y % 100);
        if (y % 100 < 10) yy = string.concat("0", yy);
        return string.concat(
            registry.symbolOf(s.underlying),
            "-",
            day,
            _month(m),
            yy,
            "-",
            LibString.toString(s.strike),
            s.optType == OptionType.Call ? "-C" : "-P"
        );
    }

    function uri(uint256 seriesId) public view override returns (string memory) {
        return string.concat('data:application/json;utf8,{"name":"', seriesName(seriesId), '","decimals":0}');
    }

    function _month(uint256 m) internal pure returns (string memory) {
        return LibString.slice("JANFEBMARAPRMAYJUNJULAUGSEPOCTNOVDEC", (m - 1) * 3, m * 3);
    }

    function _one(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }
}
