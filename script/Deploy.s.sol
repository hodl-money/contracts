// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Vault } from  "../src/Vault.sol";
import { Router } from  "../src/Router.sol";

import { BaseScript } from "./BaseScript.sol";
import { FakeOracle } from  "../test/helpers/FakeOracle.sol";

// Uniswap interfaces
import { IUniswapV3Pool } from "../src/interfaces/uniswap/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "../src/interfaces/uniswap/IUniswapV3Factory.sol";
import { IWrappedETH } from "../src/interfaces/IWrappedETH.sol";
import { INonfungiblePositionManager } from "../src/interfaces/uniswap/INonfungiblePositionManager.sol";

contract DeployScript is BaseScript {
    using SafeERC20 for IERC20;

    Vault public vault;

    uint256 strike1 = 2000_00000000;

    // Uniswap mainnet addresses
    address public mainnet_UniswapV3Factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address public mainnet_NonfungiblePositionManager = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address public mainnet_SwapRouter = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public mainnet_QuoterV2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address public mainnet_weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    IUniswapV3Pool public uniswapV3Pool;
    INonfungiblePositionManager public manager;

    function run() public {
        init();

        vm.startBroadcast(pk);

        console.log("deploy");
        FakeOracle oracle = new FakeOracle();
        oracle.setPrice(1999_00000000);
        console.log("oracle deployed to", address(oracle));
        vault = new Vault(stEth, address(oracle));

        if (true) {
            deployUniswap();
        }

        Router router = new Router(address(vault),
                                   address(weth),
                                   mainnet_UniswapV3Factory,
                                   mainnet_SwapRouter,
                                   mainnet_QuoterV2);

        uint256 previewOut = router.previewHodl(strike1, 0.2 ether);
        console.log("preview out:", previewOut);

        vm.stopBroadcast();

        {
            string memory objName = string.concat("deploy");
            string memory json;

            json = vm.serializeAddress(objName, "address_oracle", address(oracle));
            json = vm.serializeAddress(objName, "address_vault", address(vault));
            json = vm.serializeAddress(objName, "address_router", address(router));
            json = vm.serializeAddress(objName, "address_yMulti", address(vault.yMulti()));
            json = vm.serializeAddress(objName, "address_hodlMulti", address(vault.hodlMulti()));

            json = vm.serializeString(objName, "contractName_oracle", "IOracle");
            json = vm.serializeString(objName, "contractName_vault", "Vault");
            json = vm.serializeString(objName, "contractName_router", "Router");
            json = vm.serializeString(objName, "contractName_yMulti", "YMultiToken");
            json = vm.serializeString(objName, "contractName_hodlMulti", "HodlMultiToken");

            vm.writeJson(json, string.concat("./json/deploy-eth.",
                                             vm.envString("NETWORK"),
                                             ".json"));
        }
    }

    function deployUniswap() public {
        address hodl1 = vault.deployERC20(strike1);

        (address token0, address token1) = address(hodl1) < address(weth)
            ? (address(hodl1), address(weth))
            : (address(weth), address(hodl1));

        console.log("weth ", weth);
        console.log("hodl1", hodl1);

        uniswapV3Pool = IUniswapV3Pool(IUniswapV3Factory(mainnet_UniswapV3Factory).getPool(token0, token1, 3000));

        if (address(uniswapV3Pool) == address(0)) {
            uniswapV3Pool = IUniswapV3Pool(IUniswapV3Factory(mainnet_UniswapV3Factory).createPool(token0, token1, 3000));
            IUniswapV3Pool(uniswapV3Pool).initialize(79228162514264337593543950336);
        }

        console.log("deployed uniswapV3Pool", address(uniswapV3Pool));

        // Get some tokens
        uint256 amount = 1 ether;

        console.log("my balance:", deployerAddress.balance);
        console.log("amount:    ", amount);

        IWrappedETH(address(weth)).deposit{value: amount}();
        vault.mint{value: amount + 100}(strike1);  // Add 100 for stETH off-by-one

        console.log("token0 balance", IERC20(token0).balanceOf(deployerAddress));
        console.log("token1 balance", IERC20(token1).balanceOf(deployerAddress));
        console.log("amount:       ", amount);

        // Add initial liquidity
        manager = INonfungiblePositionManager(mainnet_NonfungiblePositionManager);
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: 3000,
            tickLower: -1800,
            tickUpper: 2220,
            amount0Desired: amount,
            amount1Desired: amount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: deployerAddress,
            deadline: block.timestamp + 1 days });
        IERC20(params.token0).approve(address(manager), amount);
        IERC20(params.token1).approve(address(manager), amount);
        manager.mint(params);

        
    }
}