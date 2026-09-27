// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The subset of the Chainlink AggregatorV3 interface CallBook relies on.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);

    /// @dev Reverts with "No data present" on Chainlink aggregators when the round does not exist.
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
