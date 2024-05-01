// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/console.sol";
import "forge-std/Script.sol";
import "forge-std/StdJson.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract BaseScript is Script {
    using SafeERC20 for IERC20;
    using stdJson for string;

    uint256 pk;

    address deployerAddress;

    // Addresses that vary by network
    address weth;
    address steth;
    address wsteth;
    address ethPriceFeed;

    function eq(string memory str1, string memory str2) public pure returns (bool) {
        return keccak256(abi.encodePacked(str1)) == keccak256(abi.encodePacked(str2));
    }

    function init() public {
        if (eq(vm.envString("NETWORK"), "mainnet")) {
            pk = vm.envUint("MAINNET_PRIVATE_KEY");

            steth = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
            wsteth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
            ethPriceFeed = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
            weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

        } else if (eq(vm.envString("NETWORK"), "localhost")) {
            pk = vm.envUint("LOCALHOST_PRIVATE_KEY");

            // Mainnet addresses
            steth = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
            wsteth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
            ethPriceFeed = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
            weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

        } else if (eq(vm.envString("NETWORK"), "fork")) {
            pk = vm.envUint("FORK_PRIVATE_KEY");

            // Mainnet addresses
            steth = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
            wsteth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
            ethPriceFeed = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
            weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        }
        deployerAddress = vm.addr(pk);
    }
}
