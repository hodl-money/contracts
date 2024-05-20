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
import { ChainlinkOracle } from  "../src/oracle/ChainlinkOracle.sol";


contract VaultTest is BaseTest {
    Vault vault;

    FakeOracle oracle;
    StETHYieldSource source;

    uint64 strike1 = 2000_00000000;
    uint64 strike2 = 3000_00000000;
    uint64 strike3 = 4000_00000000;

    address public treasury;

    function setUp() public {
        init();
    }

    function initVault() public {
        treasury = createUser(1000);
        oracle = new FakeOracle();
        oracle.setPrice(1999_00000000, 0);
        source = new StETHYieldSource(steth);
        vault = new Vault(address(source), address(oracle), treasury);
        source.transferOwnership(address(vault));
    }

    function testVault() public {
        initVault();

        // Mint hodl tokens
        vm.startPrank(alice);
        vault.mint{value: 3 ether}(strike1);
        uint48 epoch1 = vault.epochs(strike1);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.mint{value: 4 ether}(strike2);
        uint48 epoch2 = vault.epochs(strike2);
        vm.stopPrank();

        vm.startPrank(chad);
        vault.mint{value: 8 ether}(strike3);
        uint48 epoch3 = vault.epochs(strike3);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 3 ether, 10);
        assertEq(vault.hodlMulti().balanceOf(bob, strike1), 0);
        assertEq(vault.hodlMulti().balanceOf(chad, strike1), 0);
        assertClose(vault.yMulti().balanceOf(alice, strike1), 3 ether, 10);
        assertEq(vault.yMulti().balanceOf(bob, strike1), 0);
        assertEq(vault.yMulti().balanceOf(chad, strike1), 0);

        assertEq(vault.hodlMulti().balanceOf(alice, strike2), 0);
        assertClose(vault.hodlMulti().balanceOf(bob, strike2), 4 ether, 10);
        assertEq(vault.hodlMulti().balanceOf(chad, strike2), 0);
        assertEq(vault.yMulti().balanceOf(alice, strike2), 0);
        assertClose(vault.yMulti().balanceOf(bob, strike2), 4 ether, 10);
        assertEq(vault.yMulti().balanceOf(chad, strike2), 0);

        assertEq(vault.hodlMulti().balanceOf(alice, strike3), 0);
        assertEq(vault.hodlMulti().balanceOf(bob, strike3), 0);
        assertClose(vault.hodlMulti().balanceOf(chad, strike3), 8 ether, 10);
        assertEq(vault.yMulti().balanceOf(alice, strike3), 0);
        assertEq(vault.yMulti().balanceOf(bob, strike3), 0);
        assertClose(vault.yMulti().balanceOf(chad, strike3), 8 ether, 10);

        // Stake hodl tokens
        vm.startPrank(alice);
        uint48 stake1 = vault.hodlStake(strike1, 2 ether, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.hodlStake(strike2, 4 ether - 2, bob);
        vm.stopPrank();

        vm.startPrank(chad);
        uint48 stake3 = vault.hodlStake(strike3, 8 ether - 2, chad);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 1 ether, 10);
        assertClose(vault.yMulti().balanceOf(alice, strike1), 3 ether, 10);

        assertClose(vault.hodlMulti().balanceOf(bob, strike2), 0, 10);
        assertClose(vault.yMulti().balanceOf(bob, strike2), 4 ether, 10);

        assertClose(vault.hodlMulti().balanceOf(chad, strike3), 0, 10);
        assertClose(vault.yMulti().balanceOf(chad, strike3), 8 ether, 10);

        // Stake y token
        vm.startPrank(alice);
        uint48 stake4 = vault.yStake(strike1, 1 ether, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint48 stake5 = vault.yStake(strike2, 4 ether, bob);
        vm.stopPrank();

        vm.startPrank(chad);
        uint48 stake6 = vault.yStake(strike3, 8 ether - 1, chad);
        vm.stopPrank();

        assertClose(vault.yMulti().balanceOf(alice, strike1), 2 ether, 10);
        assertEq(vault.yMulti().balanceOf(bob, strike2), 0);
        assertEq(vault.yMulti().balanceOf(chad, strike3), 0);

        assertClose(vault.yStakedTotal(), 13 ether, 10);

        // Simulate yield, stETH balance grows, verify y token receives yield

        simulateYield(0.13 ether + 1);

        assertClose(vault.totalCumulativeYield(), 0.13 ether, 10);
        assertClose(vault.cumulativeYield(epoch1), 0.01 ether, 10);
        assertClose(vault.cumulativeYield(epoch2), 0.04 ether, 10);
        assertClose(vault.cumulativeYield(epoch3), 0.08 ether, 10);

        // Verify claimable yields + claim
        assertYStake(stake4, alice, 1 ether, 0.01 ether);
        assertYStake(stake5, bob, 4 ether, 0.04 ether);
        assertYStake(stake6, chad, 8 ether, 0.08 ether);

        vm.expectRevert("y claim user");
        vault.claim(stake4);

        claimAndVerify(stake4, alice, 0.01 ether, true);
        claimAndVerify(stake5, bob, 0.04 ether, true);
        claimAndVerify(stake6, chad, 0.08 ether, true);

        assertYStake(stake4, alice, 1 ether, 0);
        assertYStake(stake5, bob, 4 ether, 0);
        assertYStake(stake6, chad, 8 ether, 0);

        // Move price above strike1, verify redeem via hodl token

        vm.startPrank(alice);
        vm.expectRevert("cannot redeem");
        vault.redeem(stake1, 0, 1 ether);
        vm.stopPrank();

        oracle.setPrice(strike1 + 1, 0);

        assertClose(IERC20(steth).balanceOf(alice), 0 ether, 10);

        vm.startPrank(alice);
        vault.redeem(stake1, 0, 1 ether);
        vm.stopPrank();

        // Verify cannot y unstake closed epoch
        vm.startPrank(alice);
        vm.expectRevert("y unstake closed epoch");
        vault.yUnstake(stake4, alice);
        vm.stopPrank();
        assertEq(vault.yMulti().balanceOf(alice, strike1), 0);

        assertClose(vault.yStakedTotal(), 12 ether, 10);

        // Unstaked y tokens should be burned

        assertEq(vault.yMulti().balanceOf(alice, strike1), 0);

        assertClose(IERC20(steth).balanceOf(alice), 1 ether, 10);
        assertClose(IERC20(steth).balanceOf(bob), 0, 10);
        assertClose(IERC20(steth).balanceOf(chad), 0, 10);

        // Simulate more yield, verify only epoch2 and epoch3 get it

        simulateYield(0.12 ether);

        assertClose(vault.cumulativeYield(epoch1), 0.01 ether, 10);
        assertClose(vault.cumulativeYield(epoch2), 0.08 ether, 10);
        assertClose(vault.cumulativeYield(epoch3), 0.16 ether, 100);

        // Move price above both strike2 and strike3, but only strike3 claims

        oracle.setPrice(strike3 + 1, 0);

        assertClose(IERC20(steth).balanceOf(chad), 0 ether, 10);

        assertEq(vault.yStaked(epoch1), 0);
        assertClose(vault.yStaked(epoch2), 4 ether, 10);
        assertClose(vault.yStaked(epoch3), 8 ether, 10);
        assertClose(vault.yStakedTotal(), 12 ether, 10);

        vm.startPrank(chad);
        vault.redeem(stake3, 0, 4 ether);
        vm.stopPrank();

        assertEq(vault.yStaked(epoch1), 0);
        assertClose(vault.yStaked(epoch2), 4 ether, 10);
        assertEq(vault.yStaked(epoch3), 0);
        assertClose(vault.yStakedTotal(), 4 ether, 10);

        assertClose(IERC20(steth).balanceOf(alice), 1 ether, 10);
        assertClose(IERC20(steth).balanceOf(bob), 0, 10);
        assertClose(IERC20(steth).balanceOf(chad), 4 ether, 10);

        simulateYield(0.08 ether);

        assertClose(vault.cumulativeYield(epoch1), 0.01 ether, 100);
        assertClose(vault.cumulativeYield(epoch2), 0.16 ether, 100);  // Not redeemed, gets all the increase
        assertClose(vault.cumulativeYield(epoch3), 0.16 ether, 100);  // [strike3] redeemed, so no increase

        // Can mint at strike3 again, but only once price goes down
        vm.startPrank(chad);
        vm.expectRevert("strike too low");
        vault.mint{value: 4 ether}(strike3);
        vm.stopPrank();

        oracle.setPrice(strike3 - 1, 0);

        vm.startPrank(chad);
        vault.mint{value: 8 ether}(strike3);
        uint48 epoch4 = vault.epochs(strike3);
        assertClose(vault.hodlMulti().balanceOf(chad, strike3), 8 ether, 10);
        vm.stopPrank();

        // Epoch for strike3 unchanged until redeem
        assertClose(vault.cumulativeYield(epoch3), 0.16 ether, 100);

        // Degen gets some yield, verify address level accounting
        
        simulateYield(0.08 ether);

        assertEq(vault.yStaked(epoch1), 0);
        assertClose(vault.yStaked(epoch2), 4 ether, 10);
        assertEq(vault.yStaked(epoch3), 0);

        assertClose(vault.cumulativeYield(epoch1), 0.01 ether, 100);
        assertClose(vault.cumulativeYield(epoch2), 0.24 ether, 100);
        assertClose(vault.cumulativeYield(epoch3), 0.16 ether, 100);  // [strike3] redeemed, so no increase
        assertEq(vault.cumulativeYield(epoch4), 0);  // [strike3] unstaked, so no yield

        // Transfer y tokens, verify address level accounting

        vm.startPrank(chad);
        assertClose(vault.yMulti().balanceOf(chad, strike3), 8 ether, 100);
        vault.hodlStake(strike3, 8 ether - 1, chad);
        vault.yMulti().safeTransferFrom(chad, degen, strike3, 4 ether, "");
        assertClose(vault.yMulti().balanceOf(chad, strike3), 4 ether, 100);
        assertClose(vault.yMulti().balanceOf(degen, strike3), 4 ether, 100);
        vm.stopPrank();

        assertEq(vault.cumulativeYield(epoch4), 0);  // [strike3] unstaked, so no yield

        // Simulate yield after y token transfer, verify address level accounting
        vm.startPrank(degen);
        vault.yStake(strike3, 4 ether, degen);
        vm.stopPrank();

        assertClose(vault.yStakedTotal(), 8 ether, 10);
        assertEq(vault.cumulativeYield(epoch4), 0);  // [strike3] unstaked, so no yield

        simulateYield(0.08 ether);

        assertEq(vault.yStaked(epoch1), 0);
        assertClose(vault.yStaked(epoch2), 4 ether, 10);
        assertEq(vault.yStaked(epoch3), 0);
        assertClose(vault.yStaked(epoch4), 4 ether, 10);
        assertClose(vault.yStakedTotal(), 8 ether, 10);

        assertClose(vault.cumulativeYield(epoch1), 0.01 ether, 100);
        assertClose(vault.cumulativeYield(epoch2), 0.28 ether, 100);
        assertClose(vault.cumulativeYield(epoch3), 0.16 ether, 100);  // [strike3] redeemed, so no increase
        assertClose(vault.cumulativeYield(epoch4), 0.04 ether, 100);  // [strike3] staked in new epoch
    }

    function testWithChainlinkOracle() public {
        ChainlinkOracle chainlink = new ChainlinkOracle(ethPriceFeed);
        source = new StETHYieldSource(steth);
        vault = new Vault(address(source), address(chainlink), address(this));
        source.transferOwnership(address(vault));

        // Verify price at the forked block
        uint64 price = 172509460550;
        assertEq(chainlink.price(0), price);

        uint64 strikeBelow = price - 1;
        uint64 strikeAbove = price + 1;

        vm.startPrank(alice);
        vm.expectRevert("strike too low");
        vault.mint{value: 1 ether}(strikeBelow);

        vault.mint{value: 1 ether}(strikeAbove);
        vm.stopPrank();
    }

    function testERC20() public {
        initVault();

        // Mint hodl tokens
        vm.startPrank(alice);
        vault.mint{value: 1 ether}(strike1);
        vm.stopPrank();

        address hodl1Address = vault.deployERC20(strike1);

        // Can only deploy once
        vm.expectRevert("already deployed");
        vault.deployERC20(strike1);

        assertEq(hodl1Address, 0xA11d35fE4b9Ca9979F2FF84283a9Ce190F60Cd00);
        assertEq(hodl1Address, address(vault.deployments(strike1)));

        HodlToken hodl1 = HodlToken(hodl1Address);

        assertEq(vault.hodlMulti().totalSupply(strike1), hodl1.totalSupply());

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 1 ether, 10);

        assertEq(vault.hodlMulti().balanceOf(alice, strike1), hodl1.balanceOf(alice));
        assertEq(vault.hodlMulti().balanceOf(bob, strike1), hodl1.balanceOf(bob));
        assertEq(vault.hodlMulti().balanceOf(chad, strike1), hodl1.balanceOf(chad));
        assertEq(vault.hodlMulti().balanceOf(degen, strike1), hodl1.balanceOf(degen));

        vm.startPrank(alice);
        hodl1.transfer(bob, 0.1 ether);
        vm.stopPrank();

        assertClose(hodl1.balanceOf(alice), 0.9 ether, 10);
        assertEq(hodl1.balanceOf(bob), 0.1 ether);

        vm.startPrank(degen);
        vm.expectRevert("not authorized");
        hodl1.transferFrom(alice, chad, 0.2 ether);
        vm.stopPrank();

        vm.startPrank(alice);
        hodl1.approve(degen, 0.2 ether);
        vm.stopPrank();

        assertEq(hodl1.allowance(alice, degen), 0.2 ether);

        vm.startPrank(degen);
        vm.expectRevert("not authorized");
        hodl1.transferFrom(alice, chad, 0.3 ether);

        hodl1.transferFrom(alice, chad, 0.2 ether);

        vm.expectRevert("not authorized");
        hodl1.transferFrom(alice, chad, 0.2 ether);
        vm.stopPrank();

        assertClose(hodl1.balanceOf(alice), 0.7 ether, 10);
        assertEq(hodl1.balanceOf(bob), 0.1 ether);
        assertEq(hodl1.balanceOf(chad), 0.2 ether);
        assertEq(hodl1.balanceOf(degen), 0);

        assertEq(vault.hodlMulti().totalSupply(strike1), hodl1.totalSupply());

        assertEq(vault.hodlMulti().balanceOf(alice, strike1), hodl1.balanceOf(alice));
        assertEq(vault.hodlMulti().balanceOf(bob, strike1), hodl1.balanceOf(bob));
        assertEq(vault.hodlMulti().balanceOf(chad, strike1), hodl1.balanceOf(chad));
        assertEq(vault.hodlMulti().balanceOf(degen, strike1), hodl1.balanceOf(degen));
    }

    function testStrikeReuse() public {
        initVault();

        vm.startPrank(alice);

        // Mint hodl tokens
        vault.mint{value: 4 ether}(strike1);

        // Stake 2 of 4 before strike hits
        uint48 stake1 = vault.hodlStake(strike1, 2 ether, alice);

        // Strike hits
        oracle.setPrice(strike1 + 1, 0);

        // Redeem 1 of 2 staked
        vault.redeem(stake1, 0, 1 ether);

        // Go below strike
        oracle.setPrice(strike1 - 1, 0);

        // Redeem 1 remaining staked
        vault.redeem(stake1, 0, 1 ether);

        // Stake 1 at same strike
        uint48 stake2 = vault.hodlStake(strike1, 1 ether, alice);

        // The newly staked tokens cannot be redeemed
        vm.expectRevert("cannot redeem");
        vault.redeem(stake2, 0, 1 ether);

        // Strike hits
        oracle.setPrice(strike1 + 1, 0);

        // Redeem the one we staked, now that they hit the strike
        vault.redeem(stake2, 0, 1 ether);

        // Stake and redeem last 1 at that strike
        uint48 stake3 = vault.hodlStake(strike1, 1 ether - 10, alice);
        vault.redeem(stake3, 0, 1 ether - 10);

        assertClose(IERC20(steth).balanceOf(alice), 4 ether, 100);

        vm.stopPrank();
    }

    function testUnstakeY() public {
        initVault();

        // Mint hodl tokens
        vm.startPrank(alice);
        vault.mint{value: 4 ether}(strike1);
        vm.stopPrank();

        // Stake y token
        vm.startPrank(alice);
        uint48 stake1 = vault.yStake(strike1, 1 ether, alice);
        vm.stopPrank();

        // Verify it gets yield
        simulateYield(0.1 ether);

        assertClose(vault.totalCumulativeYield(), 0.1 ether, 100);
        assertClose(vault.claimable(stake1), 0.1 ether, 100);
        assertClose(vault.yMulti().balanceOf(alice, strike1), 3 ether, 100);

        // Unstake and verify no yield
        vm.startPrank(alice);
        vault.yUnstake(stake1, alice);
        vm.stopPrank();

        assertClose(vault.yMulti().balanceOf(alice, strike1), 4 ether, 100);

        simulateYield(0.1 ether);

        assertClose(vault.totalCumulativeYield(), 0.2 ether, 10);
        assertClose(vault.claimable(stake1), 0.1 ether, 10);

        // Lets do a bit more complicated: two stakes + unstake + multi yield events
        vm.startPrank(alice);
        vault.yMulti().safeTransferFrom(alice, bob, strike1, 2 ether, "");
        vm.stopPrank();

        assertClose(vault.yMulti().balanceOf(alice, strike1), 2 ether, 100);
        assertClose(vault.yMulti().balanceOf(bob, strike1), 2 ether, 100);

        // Alice stakes 2, bob stakes 1n
        vm.startPrank(alice);
        uint48 stake2 = vault.yStake(strike1, 2 ether - 2, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint48 stake3 = vault.yStake(strike1, 1 ether, bob);
        vm.stopPrank();

        assertClose(vault.yMulti().balanceOf(alice, strike1), 0, 100);
        assertClose(vault.yMulti().balanceOf(bob, strike1), 1 ether, 100);

        // Check yield distributes and claims correctly
        simulateYield(0.3 ether);

        assertClose(vault.totalCumulativeYield(), 0.5 ether, 100);

        assertClose(vault.claimable(stake1), 0.1 ether, 100);
        assertClose(vault.claimable(stake2), 0.2 ether, 100);
        assertClose(vault.claimable(stake3), 0.1 ether, 100);

        // Alice claims
        claimAndVerify(stake1, alice, 0.1 ether, true);
        claimAndVerify(stake2, alice, 0.2 ether, true);

        assertClose(vault.claimable(stake1), 0, 0);
        assertClose(vault.claimable(stake2), 0, 0);
        assertClose(vault.claimable(stake3), 0.1 ether, 100);

        // Alice unstakes her tokens, check that it still works
        vm.startPrank(alice);
        vault.yUnstake(stake2, alice);
        vm.stopPrank();

        assertClose(vault.claimable(stake1), 0, 0);
        assertClose(vault.claimable(stake2), 0, 0);
        assertClose(vault.claimable(stake3), 0.1 ether, 100);

        simulateYield(0.2 ether);

        assertClose(vault.claimable(stake1), 0, 0);
        assertClose(vault.claimable(stake2), 0, 100);
        assertClose(vault.claimable(stake3), 0.3 ether, 100);

        // Bob claims, then alice stakes for chad
        claimAndVerify(stake3, bob, 0.3 ether, true);

        // Stake y token
        vm.startPrank(alice);
        uint48 stake4 = vault.yStake(strike1, 1 ether, chad);
        vm.stopPrank();

        simulateYield(0.2 ether);

        assertClose(vault.claimable(stake1), 0, 0);
        assertClose(vault.claimable(stake2), 0, 100);
        assertClose(vault.claimable(stake3), 0.1 ether, 100);
        assertClose(vault.claimable(stake4), 0.1 ether, 100);

        // Everyone claims
        claimAndVerify(stake3, bob, 0.1 ether, true);
        claimAndVerify(stake4, chad, 0.1 ether, true);

        assertClose(vault.claimable(stake1), 0, 100);
        assertClose(vault.claimable(stake2), 0, 100);
        assertClose(vault.claimable(stake3), 0, 100);
        assertClose(vault.claimable(stake4), 0, 100);
    }

    function testUnstakeHodl() public {
        initVault();

        // Mint hodl tokens
        vm.startPrank(alice);
        vault.mint{value: 4 ether}(strike1);
        vm.stopPrank();

        // Stake hodl token
        vm.startPrank(alice);
        uint48 stake1 = vault.hodlStake(strike1, 2 ether, alice);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 2 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike1), 0, 10);
        {
            ( , , uint256 amount) = vault.hodlStakes(stake1);
            assertClose(amount, 2 ether, 10);
        }

        // Unstake 1 hodl to bob, then hit strike and check redemption
        vm.startPrank(alice);
        vault.hodlUnstake(stake1, 1 ether, bob);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 2 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike1), 1 ether, 10);

        vm.startPrank(bob);
        uint48 stake2 = vault.hodlStake(strike1, 1 ether, bob);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 2 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike1), 0, 10);

        {
            ( , , uint256 amount1) = vault.hodlStakes(stake1);
            ( , , uint256 amount2) = vault.hodlStakes(stake2);
            assertClose(amount1, 1 ether, 10);
            assertClose(amount2, 1 ether, 10);
        }

        oracle.setPrice(2001_00000000, 0);

        assertClose(IERC20(steth).balanceOf(alice), 0 ether, 10);
        assertClose(IERC20(steth).balanceOf(bob), 0 ether, 10);

        vm.startPrank(alice);
        vm.expectRevert("redeem amount");
        vault.redeem(stake1, 0, 1.1 ether);
        vault.redeem(stake1, 0, 1 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.redeem(stake2, 0, 1 ether);
        vm.stopPrank();

        assertClose(IERC20(steth).balanceOf(alice), 1 ether, 10);
        assertClose(IERC20(steth).balanceOf(bob), 1 ether, 10);

        {
            ( , , uint256 amount1) = vault.hodlStakes(stake1);
            ( , , uint256 amount2) = vault.hodlStakes(stake2);
            assertClose(amount1, 0, 10);
            assertClose(amount2, 0, 10);
        }

        vm.startPrank(alice);
        vm.expectRevert("redeem amount");
        vault.redeem(stake1, 0, 1 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert("redeem amount");
        vault.redeem(stake2, 0, 1 ether);
        vm.stopPrank();
    }

    function testRedeem() public {
        initVault();

        // Alice mints hodl
        vm.startPrank(alice);
        vault.mint{value: 1 ether}(strike1);
        uint48 epoch1 = vault.epochs(strike1);
        vm.stopPrank();

        // Bob mints hodl
        vm.startPrank(bob);
        vault.mint{value: 2 ether}(strike1);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 1 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike1), 2 ether, 10);
        assertClose(vault.yMulti().balanceOf(alice, strike1), 1 ether, 10);
        assertClose(vault.yMulti().balanceOf(bob, strike1), 2 ether, 10);

        // Alice stakes hodl + y
        vm.startPrank(alice);
        uint48 aliceHodlStake = vault.hodlStake(strike1, 1 ether - 2, alice);
        vault.yStake(strike1, 1 ether - 2, alice);
        vm.stopPrank();

        // Bob stakes hodl + y
        vm.startPrank(bob);
        uint48 bobHodlStake = vault.hodlStake(strike1, 2 ether - 2, bob);
        vault.yStake(strike1, 2 ether - 2, bob);
        vm.stopPrank();

        assertClose(vault.yStaked(epoch1), 3 ether, 10);
        assertClose(vault.yStakedTotal(), 3 ether, 10);

        // Price moves to above strike1
        oracle.setPrice(strike1 + 1, 0);

        // Alice claims staked hodl
        vm.startPrank(alice);
        vault.redeem(aliceHodlStake, 0, 1 ether - 2);
        vm.stopPrank();

        // Price moves back below strike1
        oracle.setPrice(strike1 - 1, 0);

        // Chad mints hodl tokens
        vm.startPrank(chad);
        vault.mint{value: 4 ether}(strike1);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(chad, strike1), 4 ether, 10);
        assertClose(vault.yMulti().balanceOf(chad, strike1), 4 ether, 10);

        // Bob claims stake from epoch 1, we are currently in epoch 2
        vm.startPrank(bob);
        vault.redeem(bobHodlStake, 0, 2 ether - 2);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(chad, strike1), 4 ether, 10);
        assertClose(vault.yMulti().balanceOf(chad, strike1), 4 ether, 10);
    }

    function testRedeemTokens() public {
        initVault();

        oracle.setPrice(strike1 - 1, 0);

        // Mint hodl tokens
        vm.startPrank(alice);
        vault.mint{value: 4 ether}(strike1);

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 4 ether, 10);

        vm.expectRevert("below strike");
        vault.redeemTokens(strike1, 2 ether);

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 4 ether, 10);
        vm.stopPrank();

        oracle.setPrice(strike1 + 1, 0);

        uint256 before = IERC20(steth).balanceOf(alice);

        vm.startPrank(alice);
        vault.redeemTokens(strike1, 2 ether);

        vm.expectRevert("redeem tokens balance");
        vault.redeemTokens(strike1, 10 ether);

        vault.redeemTokens(strike1, 2 ether - 2);
        vm.stopPrank();

        uint256 delta = IERC20(steth).balanceOf(alice) - before;
        assertClose(delta, 4 ether, 10);
    }

    function testMultipleRedeems() public {
        initVault();
        oracle.setPrice(strike1 - 1, 0);

        // Alice mints + stakes hodl
        vm.startPrank(alice);
        vault.mint{value: 4 ether}(strike1);
        uint48 epoch1 = vault.epochs(strike1);
        uint48 stake1 = vault.hodlStake(strike1, 3 ether, alice);
        vm.stopPrank();

        // Bob mints hodl, doesn't stake
        vm.startPrank(bob);
        vault.mint{value: 4 ether}(strike1);
        vm.stopPrank();

        // Alice cannot redeem
        vm.startPrank(alice);
        vm.expectRevert("cannot redeem");
        vault.redeem(stake1, 0, 1 ether);
        vm.stopPrank();

        // Alice stakes y tokens for Degen
        vm.startPrank(alice);
        uint48 stake2 = vault.yStake(strike1, 1 ether, degen);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 1 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike1), 4 ether, 10);
        assertEq(IERC20(steth).balanceOf(alice), 0);
        assertEq(IERC20(steth).balanceOf(bob), 0);
        assertEq(IERC20(steth).balanceOf(degen), 0);
        assertHodlStake(stake1, alice, 3 ether);
        assertYStake(stake2, degen, 1 ether, 0);

        // Simulate yield
        simulateYield(0.1 ether);

        // Strike hits
        oracle.setPrice(strike1 + 1, 0);

        // Alice redeems
        vm.startPrank(alice);
        vault.redeem(stake1, 0, 1 ether);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 1 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike1), 4 ether, 10);
        assertClose(IERC20(steth).balanceOf(alice), 1 ether, 10);
        assertEq(IERC20(steth).balanceOf(bob), 0);
        assertHodlStake(stake1, alice, 2 ether);

        assertClose(vault.totalCumulativeYield(), 0.1 ether, 10);
        assertClose(vault.cumulativeYield(epoch1), 0.1 ether, 10);
        assertYStake(stake2, degen, 1 ether, 0.1 ether);

        // Bob redeems some
        vm.startPrank(bob);
        vault.redeemTokens(strike1, 1 ether);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 1 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike1), 3 ether, 10);
        assertClose(IERC20(steth).balanceOf(alice), 1 ether, 10);
        assertClose(IERC20(steth).balanceOf(bob), 1 ether, 10);
        assertHodlStake(stake1, alice, 2 ether);

        vm.startPrank(degen);
        vm.expectRevert("y unstake closed epoch");
        vault.yUnstake(stake2, degen);
        vm.stopPrank();

        // Price falls below strike
        oracle.setPrice(strike1 - 1, 0);

        // Simulate yield, it should be on a new epoch
        vm.startPrank(alice);
        uint48 epoch2 = vault.epochs(strike1);
        vault.mint{value: 4 ether}(strike1);
        uint48 stake3 = vault.yStake(strike1, 1 ether, degen);
        vm.stopPrank();

        assertYStake(stake3, degen, 1 ether, 0);

        assertClose(vault.totalCumulativeYield(), 0.1 ether, 10);
        assertClose(vault.cumulativeYield(epoch1), 0.1 ether, 10);
        assertClose(vault.cumulativeYield(epoch2), 0 ether, 10);

        simulateYield(0.1 ether);

        assertClose(vault.totalCumulativeYield(), 0.2 ether, 10);
        assertClose(vault.cumulativeYield(epoch1), 0.1 ether, 10);
        assertClose(vault.cumulativeYield(epoch2), 0.1 ether, 10);

        assertYStake(stake3, degen, 1 ether, 0.1 ether);

        // Bob cannot redeem now
        vm.startPrank(bob);
        vm.expectRevert("below strike");
        vault.redeemTokens(strike1, 1 ether);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 5 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike1), 3 ether, 10);
        assertClose(IERC20(steth).balanceOf(alice), 1 ether, 10);
        assertClose(IERC20(steth).balanceOf(bob), 1 ether, 10);
        assertHodlStake(stake1, alice, 2 ether);

        simulateYield(0.1 ether);
        assertClose(vault.totalCumulativeYield(), 0.3 ether, 10);
        assertClose(vault.cumulativeYield(epoch1), 0.1 ether, 10);
        assertClose(vault.cumulativeYield(epoch2), 0.2 ether, 10);

        // Alice can still redeem
        vm.startPrank(alice);
        vault.redeem(stake1, 0, 1 ether);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 5 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike1), 3 ether, 10);
        assertClose(IERC20(steth).balanceOf(alice), 2 ether, 10);
        assertClose(IERC20(steth).balanceOf(bob), 1 ether, 10);
        assertHodlStake(stake1, alice, 1 ether);

        // Alice's redemption should not impact new epoch
        simulateYield(0.1 ether);
        assertClose(vault.totalCumulativeYield(), 0.4 ether, 10);
        assertClose(vault.cumulativeYield(epoch1), 0.1 ether, 10);
        assertClose(vault.cumulativeYield(epoch2), 0.3 ether, 10);

        // Chad mints hodl, stakes, fails to redeem
        vm.startPrank(chad);
        vault.mint{value: 4 ether}(strike1);
        uint48 stake4 = vault.hodlStake(strike1, 2 ether, chad);
        vm.expectRevert("cannot redeem");
        vault.redeem(stake4, 0, 1 ether);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 5 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike1), 3 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(chad, strike1), 2 ether, 10);
        assertClose(IERC20(steth).balanceOf(alice), 2 ether, 10);
        assertClose(IERC20(steth).balanceOf(bob), 1 ether, 10);
        assertEq(IERC20(steth).balanceOf(chad), 0);
        assertHodlStake(stake1, alice, 1 ether);
        assertHodlStake(stake4, chad, 2 ether);

        // Degen mints hodl, fails to redeem
        vm.startPrank(degen);
        vault.mint{value: 4 ether}(strike1);
        vm.expectRevert("below strike");
        vault.redeemTokens(strike1, 1 ether);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 5 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike1), 3 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(chad, strike1), 2 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(degen, strike1), 4 ether, 10);
        assertClose(IERC20(steth).balanceOf(alice), 2 ether, 10);
        assertClose(IERC20(steth).balanceOf(bob), 1 ether, 10);
        assertEq(IERC20(steth).balanceOf(chad), 0);
        assertEq(IERC20(steth).balanceOf(degen), 0);
        assertHodlStake(stake1, alice, 1 ether);
        assertHodlStake(stake4, chad, 2 ether);

        // Strike hits again
        oracle.setPrice(strike1 + 1, 0);

        // Redemption for all
        vm.startPrank(alice);
        vault.redeem(stake1, 0, 1 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.redeemTokens(strike1, 1 ether);
        vm.stopPrank();

        vm.startPrank(chad);
        vault.redeem(stake4, 0, 1 ether);
        vm.stopPrank();

        vm.startPrank(degen);
        vault.redeemTokens(strike1, 1 ether);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 5 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike1), 2 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(chad, strike1), 2 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(degen, strike1), 3 ether, 10);
        assertClose(IERC20(steth).balanceOf(alice), 3 ether, 10);
        assertClose(IERC20(steth).balanceOf(bob), 2 ether, 10);
        assertClose(IERC20(steth).balanceOf(chad), 1 ether, 10);
        assertClose(IERC20(steth).balanceOf(degen), 1 ether, 10);
        assertHodlStake(stake1, alice, 0);
        assertHodlStake(stake4, chad, 1 ether);
        assertFalse(vault.canRedeem(stake1, 0));
    }

    function testMerge() public {
        initVault();

        // Alice mints tokens: 1ETH @ strike1
        vm.startPrank(alice);
        vault.mint{value: 1 ether}(strike1);
        vm.stopPrank();

        // Bob mints tokens: 2ETH @ strike2
        vm.startPrank(bob);
        vault.mint{value: 2 ether}(strike2);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 1 ether, 10);
        assertClose(vault.yMulti().balanceOf(alice, strike1), 1 ether, 10);

        assertClose(vault.hodlMulti().balanceOf(bob, strike2), 2 ether, 10);
        assertClose(vault.yMulti().balanceOf(bob, strike2), 2 ether, 10);

        // Alice merges strike 1 tokens
        vm.startPrank(alice);
        vault.merge(strike1, 1 ether - 1);
        vm.stopPrank();

        assertEq(vault.hodlMulti().balanceOf(alice, strike1), 0);
        assertEq(vault.yMulti().balanceOf(alice, strike1), 0);
        assertClose(IERC20(steth).balanceOf(alice), 1 ether, 10);

        // Bob merges half of his strike 2 tokens
        vm.startPrank(bob);
        vault.merge(strike2, 1 ether);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(bob, strike2), 1 ether, 10);
        assertClose(vault.yMulti().balanceOf(bob, strike2), 1 ether, 10);
        assertClose(IERC20(steth).balanceOf(bob), 1 ether, 10);

        // Bob can't merge more tokens than he has
        vm.startPrank(bob);
        vm.expectRevert("merge hodl balance");
        vault.merge(strike2, 2 ether);
    }

    function testFees() public {
        initVault();

        // Drain treasury
        vm.startPrank(treasury);
        payable(0).transfer(treasury.balance);
        vm.stopPrank();

        {
            (uint256 value, uint256 feeValue) = vault.previewMint(10 ether);
            assertEq(value, 10 ether);
            assertEq(feeValue, 0);
        }

        // Mint with 0 fees hodl tokens
        vm.startPrank(alice);
        vault.mint{value: 3 ether}(strike1);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.mint{value: 4 ether}(strike2);
        vm.stopPrank();

        vm.startPrank(chad);
        vault.mint{value: 8 ether}(strike3);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 3 ether, 10);
        assertClose(vault.yMulti().balanceOf(alice, strike1), 3 ether, 10);

        assertClose(vault.hodlMulti().balanceOf(bob, strike2), 4 ether, 10);
        assertClose(vault.yMulti().balanceOf(bob, strike2), 4 ether, 10);

        assertClose(vault.hodlMulti().balanceOf(chad, strike3), 8 ether, 10);
        assertClose(vault.yMulti().balanceOf(chad, strike3), 8 ether, 10);

        assertEq(treasury.balance, 0);

        // Set a fee, verify balances
        vm.startPrank(alice);
        vm.expectRevert();
        vault.setTreasury(alice);
        vm.stopPrank();

        vm.expectRevert("zero address");
        vault.setTreasury(address(0));

        vm.expectRevert("max fee");
        vault.setFee(15_01);

        vault.setFee(10_00);

        {
            (uint256 value, uint256 feeValue) = vault.previewMint(10 ether);
            assertEq(value, 9 ether);
            assertEq(feeValue, 1 ether);
        }

        vm.startPrank(alice);
        vault.mint{value: 30 ether}(strike1);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.mint{value: 40 ether}(strike2);
        vm.stopPrank();

        vm.startPrank(chad);
        vault.mint{value: 80 ether}(strike3);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 30 ether, 10);
        assertClose(vault.yMulti().balanceOf(alice, strike1), 30 ether, 10);

        assertClose(vault.hodlMulti().balanceOf(bob, strike2), 40 ether, 10);
        assertClose(vault.yMulti().balanceOf(bob, strike2), 40 ether, 10);

        assertClose(vault.hodlMulti().balanceOf(chad, strike3), 80 ether, 10);
        assertClose(vault.yMulti().balanceOf(chad, strike3), 80 ether, 10);

        assertEq(treasury.balance, 15 ether);
    }

    // https://github.com/code-423n4/2024-05-hodl-findings/issues/39
    function testYStakePrecision() public {
        initVault();

        // Mint hodl tokens
        vm.startPrank(alice);
        vault.mint{value: 4 ether}(strike1);
        vm.stopPrank();

        // Stake first batch of y tokens
        vm.startPrank(alice);
        uint48 stake1 = vault.yStake(strike1, 1 ether, alice);
        vm.stopPrank();

        simulateYield(1 ether);

        ( , , , uint256 claimed1, ) = vault.yStakes(stake1);
        assertEq(claimed1, 1);

        // Stake more y tokens
        vm.startPrank(alice);
        uint48 stake2 = vault.yStake(strike1, 1 ether, alice);
        vm.stopPrank();

        ( , , , uint256 claimed2, ) = vault.yStakes(stake2);
        assertEq(claimed2, 1 ether);

        assertEq(vault.claimable(stake1), 1 ether - 2);
        assertEq(vault.claimable(stake2), 0);
    }

    // https://github.com/code-423n4/2024-05-hodl-findings/issues/20
    function testSeqIncrement() public {
        initVault();

        // Alice mints hodl
        vm.startPrank(alice);
        vault.mint{value: 1 ether}(strike1);
        vm.stopPrank();

        // Bob mints hodl
        vm.startPrank(bob);
        vault.mint{value: 2 ether}(strike2);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 1 ether, 10);
        assertClose(vault.hodlMulti().balanceOf(bob, strike2), 2 ether, 10);
        assertClose(vault.yMulti().balanceOf(alice, strike1), 1 ether, 10);
        assertClose(vault.yMulti().balanceOf(bob, strike2), 2 ether, 10);

        // Alice stakes hodl
        vm.startPrank(alice);
        uint48 aliceHodlStake = vault.hodlStake(strike1, 1 ether - 2, alice);
        vm.stopPrank();

        // Bob stakes hodl
        vm.startPrank(bob);
        uint48 bobHodlStake = vault.hodlStake(strike2, 1 ether - 2, bob);
        vm.stopPrank();

        // Price moves to above strike1
        oracle.setPrice(strike2 + 1, 0);

        // Seq before should be 1
        assertEq(vault.yMulti().strikeSeqs(strike1), 1);
        assertEq(vault.yMulti().strikeSeqs(strike2), 2);

        // Alice claims staked hodl
        vm.startPrank(alice);
        vault.redeem(aliceHodlStake, 0, 1 ether - 2);
        vm.stopPrank();

        // Bob claims staked hodl
        vm.startPrank(bob);
        vault.redeem(bobHodlStake, 0, 1 ether - 2);
        vm.stopPrank();

        assertEq(vault.yMulti().balanceOf(alice, strike1), 0);
        assertEq(vault.yMulti().balanceOf(bob, strike2), 0);

        // Seq before should be 3 and 4, because two redemptions happened
        assertEq(vault.yMulti().strikeSeqs(strike1), 3);
        assertEq(vault.yMulti().strikeSeqs(strike2), 4);
    }

    // https://github.com/code-423n4/2024-05-hodl-findings/issues/17
    function testPriceMovement() public {
        initVault();

        // Price was above strike before, and then dropped below
        oracle.setPrice(strike1 + 1, 100);
        oracle.setTimestamp(block.timestamp - 2 days, 100);
        oracle.setPrice(strike1 - 1, 200);
        oracle.setTimestamp(block.timestamp, 200);

        // Strike hits 1 day from now, then drops below again
        oracle.setPrice(strike1 + 1, 300);
        oracle.setTimestamp(block.timestamp + 1 days, 300);
        oracle.setPrice(strike1 - 1, 400);
        oracle.setTimestamp(block.timestamp + 2 days, 400);

        // We are on round 200, where price = strike - 1
        oracle.setRound(200);

        vm.startPrank(alice);

        // Mint hodl tokens
        vault.mint{value: 2 ether}(strike1);

        // Stake before strike hits
        uint48 stake1 = vault.hodlStake(strike1, 2 ether - 1, alice);

        // Verify timestamps + price, then move forward
        assertEq(block.timestamp, 1696215371);
        assertEq(oracle.timestamp(0), block.timestamp);
        assertEq(oracle.price(0), strike1 - 1);

        vm.warp(block.timestamp + 2 days);
        oracle.setRound(400);

        // Verify price touched above strike, then dipped below
        assertEq(block.timestamp, 1696388171);
        assertEq(oracle.timestamp(0), block.timestamp);
        assertEq(oracle.price(0), strike1 - 1);
        assertEq(oracle.roundId(), 400);

        // Cannot redeem at current price
        assertEq(oracle.price(0), strike1 - 1);
        vm.expectRevert("cannot redeem");
        vault.redeem(stake1, 0, 1 ether);

        // Cannot redeem via old round before epoch
        vm.expectRevert("cannot redeem");
        vault.redeem(stake1, 100, 1 ether);

        // Can via old round *after* epoch
        vault.redeem(stake1, 300, 1 ether);

        vm.stopPrank();
    }

    // https://github.com/code-423n4/2024-05-hodl-findings/issues/35
    function testMergeNegativeYield() public {
        initVault();

        // Alice mints tokens: 1ETH @ strike1
        vm.startPrank(alice);
        vm.deal(alice, 15 ether);
        vault.mint{value: 15 ether}(strike1);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.deal(bob, 10 ether);
        vault.mint{value: 10 ether}(strike1);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 15 ether, 10);
        assertClose(vault.yMulti().balanceOf(alice, strike1), 15 ether, 10);

        // negative rebase happened, e.g. massive slashing of Lido nodes
        simulateNegativeYield(3 ether);

        // Bob merges strike 1 tokens
        vm.startPrank(bob);
        vault.merge(strike1, 10 ether - 1);
        vm.stopPrank();

        // Alice merges strike 1 tokens
        vm.startPrank(alice);
        vault.merge(strike1, 15 ether - 2);
        vm.stopPrank();

        // Verify proportional accounting for negative yield
        assertEq(vault.hodlMulti().balanceOf(alice, strike1), 0);
        assertEq(vault.yMulti().balanceOf(alice, strike1), 0);
        assertEq(IERC20(steth).balanceOf(bob), 10 ether * 22 / 25 - 3);
        assertEq(IERC20(steth).balanceOf(alice), 15 ether * 22 / 25 - 1);
    }

    // https://github.com/code-423n4/2024-05-hodl-findings/issues/26
    function testAccountingNegativeYield() public {
        initVault();

        vm.startPrank(alice);
        vm.deal(alice, 15 ether);
        vault.mint{value: 15 ether}(strike1);
        uint48 stake1 = vault.yStake(strike1, 5 ether, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.deal(bob, 10 ether);
        vault.mint{value: 10 ether}(strike1);
        uint48 stake2 = vault.yStake(strike1, 5 ether, bob);
        vm.stopPrank();

        assertClose(vault.hodlMulti().balanceOf(alice, strike1), 15 ether, 10);
        assertClose(vault.yMulti().balanceOf(alice, strike1), 10 ether, 10);

        simulateYield(1 ether);

        assertEq(vault.totalCumulativeYield(), 1 ether);
        assertEq(vault.yieldPerToken(), 0.1 ether);

        // Trigger checkpoint to save `cumulativeYieldAcc`
        vm.startPrank(bob);
        uint48 stake3 = vault.yStake(strike1, 1 wei, bob);
        vm.stopPrank();

        assertEq(vault.claimable(stake1), 0.5 ether - 1);
        assertEq(vault.claimable(stake2), 0.5 ether - 1);

        // Alice unstakes to lock in her claimable value
        vm.startPrank(alice);
        vault.yUnstake(stake1, alice);
        vm.stopPrank();

        // Negative rebase happened, e.g. massive slashing of Lido nodes
        simulateNegativeYield(3 ether);

        assertEq(vault.totalCumulativeYield(), 0);
        assertEq(vault.yieldPerToken(), 0);

        // Unstaking locked in claimable
        assertEq(vault.claimable(stake1), 0.5 ether - 1);

        // Still staked, so hit by negative rebase
        assertEq(vault.claimable(stake2), 0);

        // Alice claims, check accounting
        vm.startPrank(alice);
        vault.claim(stake1);
        ( , , , uint256 claimed, ) = vault.yStakes(stake1);
        assertEq(claimed, 0.5 ether - 1);
        assertEq(vault.claimed(), 0.5 ether - 1);
        vm.stopPrank();
    }

    function testStakeAfterStrikeHits() public {
        initVault();

        // Alice mints hodl
        vm.startPrank(alice);

        vault.mint{value: 2 ether}(strike1);

        uint48 stake1 = vault.hodlStake(strike1, 1 ether, alice);

        vm.expectRevert("cannot redeem");
        vault.redeem(stake1, 0, 1 ether);

        oracle.setPrice(strike1 + 1, 0);

        // Stake before a redeem
        uint48 stake2 = vault.hodlStake(strike1, 0.1 ether, alice);

        vault.redeem(stake1, 0, 1 ether);

        // Stake after a redeem
        uint48 stake3 = vault.hodlStake(strike1, 0.1 ether, alice);
        vault.redeem(stake3, 0, 0.1 ether);

        // Stake after a redeem and after price drop
        oracle.setPrice(strike1 - 1, 0);
        uint48 stake4 = vault.hodlStake(strike1, 0.1 ether, alice);

        // Redeem stake2, which was staked during price strike + 1
        vault.redeem(stake2, 0, 0.1 ether);

        // Cannot redeem stake5, which was staked at price strike - 1
        vm.expectRevert("cannot redeem");
        vault.redeem(stake4, 0, 0.1 ether);

        vm.stopPrank();
    }


    function simulateYield(uint256 amount) internal {
        IStEth(steth).submit{value: amount}(address(0));
        IERC20(steth).transfer(address(vault.source()), amount);
    }

    function simulateNegativeYield(uint256 amount) internal {
        vm.startPrank(address(vault));
        source.transferOwnership(address(this));
        vm.stopPrank();
        source.withdraw(amount, address(this));
        source.transferOwnership(address(vault));
    }

    function claimAndVerify(uint48 stakeId, address user, uint256 amount, bool dumpCoins) internal {
        assertClose(vault.claimable(stakeId), amount, 10);

        uint256 before = IERC20(steth).balanceOf(user);

        vm.startPrank(user);
        vault.claim(stakeId);
        vm.stopPrank();

        uint256 delta = IERC20(steth).balanceOf(user) - before;
        assertClose(delta, amount, 10);

        assertClose(vault.claimable(stakeId), 0, 10);

        vm.startPrank(user);
        vault.claim(stakeId);
        vm.stopPrank();

        delta = IERC20(steth).balanceOf(user) - before;
        assertClose(delta, amount, 10);

        if (dumpCoins) {
            vm.startPrank(user);
            IERC20(steth).transfer(address(123), delta);
            vm.stopPrank();
            assertClose(IERC20(steth).balanceOf(user), before, 10);
        }
    }

    function assertHodlStake(uint48 stakeId, address expectedUser, uint256 expectedAmount) public {
        (address user, , uint256 amount) = vault.hodlStakes(stakeId);
        assertEq(expectedUser, user);
        assertClose(expectedAmount, amount, 10);
    }

    function assertYStake(uint48 stakeId,
                          address expectedUser,
                          uint256 expectedAmount,
                          uint256 expectedClaimable) public {

        (address user, , uint256 amount, , ) = vault.yStakes(stakeId);
        assertEq(expectedUser, user);
        assertClose(expectedAmount, amount, 10);
        assertClose(vault.claimable(stakeId), expectedClaimable, 10);
    }
}
