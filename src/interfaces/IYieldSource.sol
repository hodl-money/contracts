// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/console.sol";

interface IYieldSource {

    function asset() external view returns (address);
    function balance() external view returns (uint256);
    function wrap(uint256 amount) external payable;
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount, address receiver) external;

}
