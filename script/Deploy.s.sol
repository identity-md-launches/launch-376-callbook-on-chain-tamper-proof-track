// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {CallBook} from "../src/CallBook.sol";

/// @notice Deploys CallBook. The production launch goes through the IdentityMD ProjectFactory using
/// the constructor arguments documented in the README; this script is the reviewable equivalent for
/// a local dry run or an operator-run deployment. It never reads a private key.
contract Deploy is Script {
    struct Config {
        address owner;
        address ethUsd;
        address btcUsd;
    }

    uint256 public constant SEPOLIA = 11155111;
    uint256 public constant ANVIL = 31337;

    address public constant SEPOLIA_ETH_USD = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address public constant SEPOLIA_BTC_USD = 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43;

    /// @dev The only deployment, and the function tests call directly.
    function deploy(Config memory cfg) public returns (CallBook book) {
        book = new CallBook(cfg.owner, cfg.ethUsd, cfg.btcUsd);
    }

    /// @dev Reads configuration from the environment and refuses to run on an unexpected chain.
    /// EXPECTED_CHAIN_ID=0 skips the chain match but still restricts to Anvil or Sepolia.
    function run() external returns (CallBook book) {
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        require(block.chainid == ANVIL || block.chainid == SEPOLIA, "unsupported chain");
        require(expected == 0 || expected == block.chainid, "chain id mismatch");

        Config memory cfg = Config({
            owner: vm.envOr("CALLBOOK_OWNER", msg.sender),
            ethUsd: vm.envOr("CALLBOOK_ETH_USD", SEPOLIA_ETH_USD),
            btcUsd: vm.envOr("CALLBOOK_BTC_USD", SEPOLIA_BTC_USD)
        });

        vm.startBroadcast();
        book = deploy(cfg);
        vm.stopBroadcast();
    }
}
