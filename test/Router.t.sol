// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/console.sol"; 

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IStEth } from "../src/interfaces/IStEth.sol";

import { Vault } from  "../src/Vault.sol";
import { Router } from  "../src/Router.sol";
import { StETHERC4626 } from "../src/assets/StETHERC4626.sol";
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
        vault = new Vault(address(asset), address(oracle));
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

        vm.deal(alice, 100 ether);

        vm.startPrank(alice);
        IWrappedETH(address(weth)).deposit{value: 100 ether}();
        vm.stopPrank();

        uint256 token0Amount = 5 ether;
        uint256 token1Amount = 5 ether;

        // Add initial liquidity
        manager = INonfungiblePositionManager(nonfungiblePositionManager);
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: 3000,
            tickLower: -1800,
            tickUpper: 2220,
            amount0Desired: token0Amount,
            amount1Desired: token1Amount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: alice,
            deadline: block.timestamp + 1 });

        vm.startPrank(alice);
        IERC20(params.token0).approve(address(manager), token0Amount);
        IERC20(params.token1).approve(address(manager), token1Amount);
        manager.mint(params);
        vm.stopPrank();

        router = new Router(address(vault),
                            address(weth),
                            address(steth),
                            address(wsteth),
                            uniswapV3Factory,
                            swapRouter,
                            quoterV2,
                            aavePool);
    }

    function testGas_HodlBuys() public {
        initRouter();

        vm.deal(alice, 1 ether);
        vm.startPrank(alice);

        for (uint256 i = 0; i < 5; i++) {
            uint256 amountHodl = router.hodl{value: 0.1 ether}(strike1, 0);
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
            (uint256 amountY, uint256 loan) = router.previewY(strike1, amount);
            router.y{value: amount}(strike1, loan, amountY - 10);
            router.vault().yStake(strike1, amountY, alice);
        }

        vm.stopPrank();
    }

    function testBuys() public {
        initRouter();

        uint256 previewOut = router.previewHodl(strike1, 0.2 ether);

        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        uint256 out = router.hodl{value: 0.2 ether}(strike1, 0);
        uint32 stakeId = router.vault().hodlStake(strike1, out, alice);
        vm.stopPrank();

        assertEq(out, 232678867527217383);
        assertEq(previewOut, 232678867527217383);

        vm.expectRevert("redeem user");
        vault.redeem(out, stakeId);

        uint256 before = IERC20(steth).balanceOf(alice);

        vm.startPrank(alice);
        vault.redeem(out, stakeId);
        vm.stopPrank();

        uint256 delta = IERC20(steth).balanceOf(alice) - before;
        assertEq(delta, out - 1);

        (uint256 amountY, uint256 loan) = router.previewY(strike1, 0.2 ether);

        assertEq(amountY, 610549117077607658);
        assertEq(loan, 410549117077607658);

        oracle.setPrice(strike1 - 1);

        assertEq(vault.yMulti().balanceOf(alice, strike1), 0);

        vm.startPrank(alice);

        vm.expectRevert("y min out");
        router.y{value: 0.2 ether}(strike1, loan, amountY + 1);

        uint256 outY = router.y{value: 0.2 ether}(strike1, loan, amountY - 10);
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
            uint256 out = router.hodl{value: 0.3 ether}(strike1, 0);
            router.vault().hodlStake(strike1, out, alice);
            vm.stopPrank();

            // TODO: verify something
        }
    }

    function testSells() public {
        initRouter();

        IERC20 token = IERC20(vault.deployments(strike1));

        {
            uint256 previewOut = router.previewHodlSell(strike1, 0.2 ether);
            uint256 before = IERC20(address(weth)).balanceOf(alice);

            vm.startPrank(alice);
            token.approve(address(router), 0.2 ether);
            (uint256 out) = router.hodlSell(strike1, 0.2 ether, previewOut);
            vm.stopPrank();

            uint256 delta = IERC20(address(weth)).balanceOf(alice) - before;

            assertEq(out, 168315976172535283);
            assertEq(previewOut, 168315976172535283);
            assertEq(delta, 168315976172535283);
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

            assertEq(previewProfit, 30401693884080840);
            assertClose(out, 30401693884080840, 1);
            assertClose(delta, 30401693884080840, 1);
        }
    }
}
