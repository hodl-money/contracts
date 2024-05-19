// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseTest } from  "./BaseTest.sol";
import { FakeOracle } from  "./helpers/FakeOracle.sol";

import { Vault } from  "../src/Vault.sol";
import { YMultiToken } from  "../src/multi/YMultiToken.sol";
import { StETHYieldSource } from "../src/sources/StETHYieldSource.sol";

contract YTokenTest is BaseTest {
    Vault vault;

    FakeOracle oracle;
    YMultiToken yMulti;

    uint64 strike1 = 2000_00000000;
    uint64 strike2 = 3000_00000000;

    function setUp() public {
        init();
    }

    function initVault() public {
        oracle = new FakeOracle();
        oracle.setPrice(1999_00000000, 0);
        StETHYieldSource source = new StETHYieldSource(steth);
        vault = new Vault(address(source), address(oracle), address(this));
        source.transferOwnership(address(vault));
        yMulti = vault.yMulti();
    }

    function testYTokenTransferChecks() public {
        initVault();

        // Mint tokens for Alice
        vm.startPrank(alice);
        vault.mint{value: 1 ether}(strike1);

        vault.yMulti().safeTransferFrom(alice, bob, strike1, 0.1 ether, "");

        vm.expectRevert("zero value transfer");
        yMulti.safeTransferFrom(alice, bob, strike1, 0, "");

        vm.expectRevert("insufficient balance");
        yMulti.safeTransferFrom(alice, bob, strike1, 10 ether, "");

        vm.stopPrank();
    }
}
