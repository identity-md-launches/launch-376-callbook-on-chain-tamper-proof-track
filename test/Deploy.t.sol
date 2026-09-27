// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {CallBook} from "../src/CallBook.sol";

contract DeployTest is Test {
    function test_deployWiresConstructorArguments() public {
        Deploy d = new Deploy();
        address owner = makeAddr("owner");
        CallBook book =
            d.deploy(Deploy.Config({owner: owner, ethUsd: d.SEPOLIA_ETH_USD(), btcUsd: d.SEPOLIA_BTC_USD()}));

        assertEq(book.owner(), owner);
        address[] memory feeds = book.feeds();
        assertEq(feeds.length, 2);
        assertEq(feeds[0], 0x694AA1769357215DE4FAC081bf1f309aDC325306);
        assertEq(feeds[1], 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43);
        assertTrue(book.feedEnabled(feeds[0]));
        assertTrue(book.feedEnabled(feeds[1]));
        // The constructor made no external calls: feed addresses have no code here.
        assertEq(feeds[0].code.length, 0);
    }
}
