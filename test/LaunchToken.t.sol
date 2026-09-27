// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.prank(deployer);
        token = new LaunchToken();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "CallBook");
        assertEq(token.symbol(), "CALL");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(deployer), token.totalSupply());
    }

    function test_transfer() public {
        vm.prank(deployer);
        assertTrue(token.transfer(bob, 1e18));
        assertEq(token.balanceOf(bob), 1e18);
        assertEq(token.balanceOf(deployer), token.totalSupply() - 1e18);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(bob);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transfer(deployer, 1);
    }

    function test_transferFromRespectsAllowance() public {
        vm.prank(deployer);
        token.approve(bob, 5e18);
        vm.prank(bob);
        token.transferFrom(deployer, bob, 3e18);
        assertEq(token.allowance(deployer, bob), 2e18);
        vm.prank(bob);
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        token.transferFrom(deployer, bob, 3e18);
    }

    function test_noMintPath() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", bob, 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function testFuzz_transferConservesSupply(uint256 amount, address to) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, token.totalSupply());
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), token.totalSupply());
    }
}
