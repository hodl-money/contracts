// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/console.sol"; 

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IStEth } from "../src/interfaces/IStEth.sol";

import { Vault } from  "../src/Vault.sol";
import { Router } from  "../src/Router.sol";
import { StETHERC4626 } from "../src/assets/StETHERC4626.sol";
import { StETHYieldSource } from "../src/sources/StETHYieldSource.sol";
import { HodlToken } from  "../src/single/HodlToken.sol";
import { ILiquidityPool } from "../src/interfaces/ILiquidityPool.sol";

// Uniswap interfaces
import { IUniswapV3Pool } from "../src/interfaces/uniswap/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "../src/interfaces/uniswap/IUniswapV3Factory.sol";
import { IWrappedETH } from "../src/interfaces/IWrappedETH.sol";
import { INonfungiblePositionManager } from "../src/interfaces/uniswap/INonfungiblePositionManager.sol";

// Aave interfaces
import { IPool } from "../src/interfaces/aave/IPool.sol";

import { BaseTest } from  "./BaseTest.sol";
import { FakeOracle } from  "./helpers/FakeOracle.sol";

contract RouterTest is BaseTest {
    Vault public vault;
    Router public router;
    FakeOracle public oracle;

    IUniswapV3Pool public uniswapV3Pool;
    INonfungiblePositionManager public manager;

    uint64 strike1 = 2000_00000000;

    function setUp() public {
        init();
    }

    function initRouter() public {
        // Set up: deploy vault, mint some hodl for alice, make it redeemable
        oracle = new FakeOracle();
        StETHERC4626 asset = new StETHERC4626(steth);
        StETHYieldSource source = new StETHYieldSource(steth);
        vault = new Vault(address(asset), address(source), address(oracle));
        oracle.setPrice(strike1 - 1);
        address hodl1 = vault.deployERC20(strike1);
        vm.startPrank(alice);
        vault.mint{value: 10 ether}(strike1);
        vm.stopPrank();
        oracle.setPrice(strike1 + 1);

        // Set up the pool
        (address token0, address token1) = hodl1 < weth
            ? (hodl1, weth)
            : (weth, hodl1);
        uniswapV3Pool = IUniswapV3Pool(IUniswapV3Factory(uniswapV3Factory).getPool(token0, token1, 3000));

        if (address(uniswapV3Pool) == address(0)) {
            uniswapV3Pool = IUniswapV3Pool(IUniswapV3Factory(uniswapV3Factory).createPool(token0, token1, 3000));
            uint160 initPrice = 73044756656988589698425290750;
            uint160 initPriceInv = 85935007831751276823975034880;
            IUniswapV3Pool(uniswapV3Pool).initialize(hodl1 < weth ? initPrice : initPriceInv);
        }

        router = new Router(address(vault),
                            address(weth),
                            address(steth),
                            address(wsteth),
                            uniswapV3Factory,
                            swapRouter,
                            nonfungiblePositionManager,
                            quoterV2,
                            aavePool);

        oracle.setPrice(strike1 - 1);
        router.addLiquidity{value: 10 ether}(strike1, 5 ether, 1800);
        oracle.setPrice(strike1 + 1);
    }

    function testGas_HodlBuys() public {
        initRouter();

        vm.deal(alice, 1 ether);
        vm.startPrank(alice);

        for (uint256 i = 0; i < 5; i++) {
            uint256 amountHodl = router.hodlBuy{value: 0.1 ether}(strike1, 0);
            router.vault().hodlStake(strike1, amountHodl, alice);
        }

        vm.stopPrank();
    }

    function testGas_YBuys() public {
        initRouter();

        oracle.setPrice(strike1 - 1);

        vm.deal(alice, 1 ether);
        vm.startPrank(alice);

        for (uint256 i = 0; i < 5; i++) {
            uint256 amount = 0.01 ether;
            (uint256 amountY, uint256 loan) = router.previewYBuy(strike1, amount);
            router.yBuy{value: amount}(strike1, loan, amountY - 10);
            router.vault().yStake(strike1, amountY, alice);
        }

        vm.stopPrank();
    }

    function testAddLiquidity() public {
        initRouter();

        oracle.setPrice(strike1 - 1);

        vm.deal(alice, 1 ether);

        IERC20 hodlToken = vault.deployments(strike1);
        (address token0, address token1) = address(hodlToken) < weth
            ? (address(hodlToken), weth)
            : (weth, address(hodlToken));
        uniswapV3Pool = IUniswapV3Pool(IUniswapV3Factory(uniswapV3Factory).getPool(token0, token1, 3000));

        vm.startPrank(alice);
        assertEq(uniswapV3Pool.liquidity(), 59065148190976308112);
        router.addLiquidity{value: 1 ether}(strike1, 0.5 ether, 1800);
        assertEq(uniswapV3Pool.liquidity(), 64971663010073938912);
        vm.stopPrank();
    }

    function testBuys() public {
        initRouter();

        uint256 previewOut = router.previewHodlBuy(strike1, 0.2 ether);

        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        uint256 out = router.hodlBuy{value: 0.2 ether}(strike1, 0);
        uint32 stakeId = router.vault().hodlStake(strike1, out, alice);
        vm.stopPrank();

        assertEq(out, 233732374240915488);
        assertEq(previewOut, 233732374240915488);

        vm.expectRevert("redeem user");
        vault.redeem(out, stakeId);

        uint256 before = IERC20(steth).balanceOf(alice);

        vm.startPrank(alice);
        vault.redeem(out, stakeId);
        vm.stopPrank();

        uint256 delta = IERC20(steth).balanceOf(alice) - before;
        assertEq(delta, out - 1);

        (uint256 amountY, uint256 loan) = router.previewYBuy(strike1, 0.2 ether);

        assertEq(amountY, 872715808468637986);
        assertEq(loan, 672715808468637986);

        oracle.setPrice(strike1 - 1);

        assertEq(vault.yMulti().balanceOf(alice, strike1), 0);

        vm.startPrank(alice);

        vm.expectRevert("y min out");
        router.yBuy{value: 0.2 ether}(strike1, loan, amountY + 1);

        uint256 outY = router.yBuy{value: 0.2 ether}(strike1, loan, amountY - 10);
        uint32 stake1 = router.vault().yStake(strike1, outY, alice);
        vm.stopPrank();

        assertClose(outY, amountY, 10);

        {
            ( , , , uint256 stakeY, , ) = vault.yStakes(stake1);
            assertClose(stakeY, amountY, 10);
        }

        {
            vm.deal(alice, 1 ether);
            vm.startPrank(alice);
            uint256 outHodl = router.hodlBuy{value: 0.3 ether}(strike1, 0);
            router.vault().hodlStake(strike1, outHodl, alice);
            vm.stopPrank();

            assertEq(outHodl, 356111361683170649);
        }
    }

    function testSells() public {
        initRouter();

        IERC20 token = vault.deployments(strike1);

        {
            uint256 previewOut = router.previewHodlSell(strike1, 0.2 ether);
            uint256 before = IERC20(address(weth)).balanceOf(alice);

            vm.startPrank(alice);
            token.approve(address(router), 0.2 ether);
            (uint256 out) = router.hodlSell(strike1, 0.2 ether, previewOut);
            vm.stopPrank();

            uint256 delta = IERC20(address(weth)).balanceOf(alice) - before;

            assertEq(out, 168964106533830031);
            assertEq(previewOut, 168964106533830031);
            assertEq(delta, 168964106533830031);
        }

        {
            (uint256 loan, uint256 previewProfit) = router.previewYSell(strike1, 0.2 ether);

            uint256 before = IERC20(address(weth)).balanceOf(alice);

            vm.startPrank(alice);
            vault.yMulti().setApprovalForAll(address(router), true);

            vm.expectRevert("y sell min out");
            router.ySell(strike1, loan, 0.2 ether, previewProfit + 1);

            uint256 out = router.ySell(strike1, loan, 0.2 ether, previewProfit - 1);
            vm.stopPrank();

            uint256 delta = IERC20(address(weth)).balanceOf(alice) - before;

            assertEq(previewProfit, 29751294189320052);
            assertClose(out, 29751294189320052, 1);
            assertClose(delta, 29751294189320052, 1);
        }
    }
}
