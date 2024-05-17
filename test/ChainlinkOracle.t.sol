// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ChainlinkOracle } from  "../src/oracle/ChainlinkOracle.sol";
import { AggregatorV3Interface } from "../src/interfaces/chainlink/AggregatorV3Interface.sol";

import { BaseTest } from  "./BaseTest.sol";

contract ChainlinkOracleTest is BaseTest {

    function setUp() public {
        init();
    }

    function testChainlinkOracle() public {
        ChainlinkOracle oracle = new ChainlinkOracle(ethPriceFeed);

        assertEq(oracle.price(0), 172509460550);
        assertEq(oracle.timestamp(0), 1696211723);

        uint80 roundId = 110680464442257315708;
        assertEq(oracle.price(roundId), 168606000000);
        assertEq(oracle.timestamp(roundId), 1696154123);
    }
}
