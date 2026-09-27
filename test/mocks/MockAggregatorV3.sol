// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @notice Test double for a Chainlink aggregator with fully controllable rounds.
contract MockAggregatorV3 is AggregatorV3Interface {
    struct Round {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
        bool exists;
    }

    uint8 private immutable _decimals;
    uint80 public latestRound;
    mapping(uint80 => Round) private _rounds;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "MOCK / USD";
    }

    function version() external pure returns (uint256) {
        return 4;
    }

    /// @notice Append a complete round at `updatedAt` and make it the latest.
    function pushRound(int256 answer, uint256 updatedAt) external returns (uint80 roundId) {
        roundId = ++latestRound;
        _rounds[roundId] = Round(answer, updatedAt, updatedAt, roundId, true);
    }

    /// @notice Write an arbitrary round, including incomplete or stale shapes.
    function setRound(uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
        external
    {
        _rounds[roundId] = Round(answer, startedAt, updatedAt, answeredInRound, true);
    }

    function setLatest(uint80 roundId) external {
        latestRound = roundId;
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = _rounds[roundId];
        require(r.exists, "No data present");
        return (roundId, r.answer, r.startedAt, r.updatedAt, r.answeredInRound);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = _rounds[latestRound];
        require(r.exists, "No data present");
        return (latestRound, r.answer, r.startedAt, r.updatedAt, r.answeredInRound);
    }
}
