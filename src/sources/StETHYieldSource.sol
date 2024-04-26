// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/console.sol";

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from  "@openzeppelin/contracts/access/Ownable.sol";

import { IStEth } from "../interfaces/IStEth.sol";
import { IYieldSource } from "../interfaces/IYieldSource.sol";

contract StETHYieldSource is IYieldSource, Ownable {
    using SafeERC20 for IERC20;

    address public immutable asset;

    constructor(address asset_) Ownable(msg.sender) {
        asset = asset_;
    }

    function balance() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function deposit() external onlyOwner payable returns (uint256) {
        uint256 before = IERC20(asset).balanceOf(address(this));
        IStEth(asset).submit{value: msg.value}(address(0));
        uint256 delta = IERC20(asset).balanceOf(address(this)) - before;
        return delta;
    }

    function withdraw(uint256 amount, address receiver) external onlyOwner {
        IERC20(asset).safeTransfer(receiver, amount);
    }
}
