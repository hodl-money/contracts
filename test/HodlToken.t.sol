// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseTest } from  "./BaseTest.sol";
import { FakeOracle } from  "./helpers/FakeOracle.sol";

import { IStEth } from "../src/interfaces/IStEth.sol";
import { ILiquidityPool } from "../src/interfaces/ILiquidityPool.sol";
import { Vault } from  "../src/Vault.sol";
import { Router } from  "../src/Router.sol";
import { StETHYieldSource } from "../src/sources/StETHYieldSource.sol";
import { HodlToken } from  "../src/single/HodlToken.sol";

contract HodlTokenTest is BaseTest {
    Vault vault;

    FakeOracle oracle;

    uint64 strike1 = 2000_00000000;
    uint64 strike2 = 3000_00000000;

    HodlToken hodlTokenStrike1;
    HodlToken hodlTokenStrike2;

    function setUp() public {
        init();
    }

    function initVault() public {
        oracle = new FakeOracle();
        oracle.setPrice(1999_00000000, 0);
        StETHYieldSource source = new StETHYieldSource(steth);
        vault = new Vault(address(source), address(oracle), address(this));
        source.transferOwnership(address(vault));
    }

    function testHodlToken() public {
        initVault();

        // Mint HODL tokens for Alice
        vm.startPrank(alice);
        vault.mint{value: 1 ether}(strike1);
        vault.mint{value: 2 ether}(strike2);
        vm.stopPrank();

        // Mint HODL tokens for Bob
        vm.startPrank(bob);
        vault.mint{value: 3 ether}(strike1);
        vault.mint{value: 4 ether}(strike2);
        vm.stopPrank();

        // Alice has 1 @ strike1, 2 @ strike2
        // Bob has 3 @ strike1, 4 @ strike2

        // Deploy HodlTokens for each strike
        hodlTokenStrike1 = HodlToken(vault.deployERC20(strike1));
        hodlTokenStrike2 = HodlToken(vault.deployERC20(strike2));

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 1 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(alice, strike2), 2 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike1), 3 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike2), 4 ether, 10);
        assertEq(vault.hodlMulti().balanceOf(chad, strike1), 0);
        assertEq(vault.hodlMulti().balanceOf(chad, strike2), 0);

        assertClose(hodlTokenStrike1.balanceOf(alice), 1 ether, 10);
        assertClose(hodlTokenStrike2.balanceOf(alice), 2 ether, 10);
        assertClose(hodlTokenStrike1.balanceOf(bob), 3 ether, 10);
        assertClose(hodlTokenStrike2.balanceOf(bob), 4 ether, 10);
        assertEq(hodlTokenStrike1.balanceOf(chad), 0);
        assertEq(hodlTokenStrike2.balanceOf(chad), 0);

        // Alice transfers her strike1 tokens to Chad
        vm.startPrank(alice);
        hodlTokenStrike1.transfer(chad, 1 ether - 1);
        vm.stopPrank();

        assertEq(vault.hodlMulti().balanceOf(alice, strike1), 0);
        assertClose(vault.hodlMulti().balanceOf(alice, strike2), 2 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike1), 3 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike2), 4 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(chad, strike1), 1 ether, 10);
        assertEq(vault.hodlMulti().balanceOf(chad, strike2), 0);

        assertEq(hodlTokenStrike1.balanceOf(alice), 0);
        assertClose(hodlTokenStrike2.balanceOf(alice), 2 ether, 10);
        assertClose(hodlTokenStrike1.balanceOf(bob), 3 ether, 10);
        assertClose(hodlTokenStrike2.balanceOf(bob), 4 ether, 10);
        assertClose(hodlTokenStrike1.balanceOf(chad),  1 ether, 10);
        assertEq(hodlTokenStrike2.balanceOf(chad), 0);

        // Chad attempts to transfer strike 2 tokens from Alice
        vm.startPrank(chad);
        vm.expectRevert("not authorized");
        hodlTokenStrike2.transferFrom(alice, chad, 2 ether - 2);

        // Alice approves chad to transfer strike 2 tokens
        assertEq(hodlTokenStrike2.allowance(alice, chad), 0);
        vm.startPrank(alice);
        hodlTokenStrike2.approve(chad, 2 ether - 1);
        assertClose(hodlTokenStrike2.allowance(alice, chad), 2 ether, 10);
        vm.stopPrank();

        // Chad transferFroms strike 2 tokens from Alice
        vm.startPrank(chad);
        hodlTokenStrike2.transferFrom(alice, chad, 2 ether - 1);

        assertEq(hodlTokenStrike2.allowance(alice, chad), 0);

        // Chad can't transferFrom again
        vm.expectRevert("not authorized");
        hodlTokenStrike2.transferFrom(alice, chad, 2 ether - 2);

        vm.stopPrank();

        assertEq(vault.hodlMulti().balanceOf(alice, strike1), 0);
        assertEq(vault.hodlMulti().balanceOf(alice, strike2), 0);
        assertClose(vault.hodlMulti().balanceOf(bob, strike1), 3 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike2), 4 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(chad, strike1), 1 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(chad, strike2), 2 ether, 10);

        assertEq(hodlTokenStrike1.balanceOf(alice), 0);
        assertEq(hodlTokenStrike2.balanceOf(alice), 0);
        assertClose(hodlTokenStrike1.balanceOf(bob), 3 ether, 10);
        assertClose(hodlTokenStrike2.balanceOf(bob), 4 ether, 10);
        assertClose(hodlTokenStrike1.balanceOf(chad),  1 ether, 10);
        assertClose(hodlTokenStrike2.balanceOf(chad), 2 ether, 10);
    }
}
