// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/Strings.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { Ownable } from  "@openzeppelin/contracts/access/Ownable.sol";

import { Vault } from "../Vault.sol";
import { YMultiToken } from "./YMultiToken.sol";

contract HodlMultiToken is ERC1155, Ownable {

    uint256 public nextId = 1;
    mapping(uint256 => uint256) public totalSupply;
    mapping(address => bool) public authorized;

    // Events
    event Authorize(address indexed user);

    event Mint(address indexed user,
               uint256 indexed strike,
               uint256 amount);

    event Burn(address indexed user,
               uint256 indexed strike,
               uint256 amount);

    constructor(string memory uri_) ERC1155(uri_) Ownable(msg.sender) { }

    function name(uint256 strike) public view virtual returns (string memory) {
        if (strike % 1e8 == 0) {
            return string(abi.encodePacked("plETH @ ", Strings.toString(strike / 1e8)));
        } else {
            return string(abi.encodePacked("plETH @ ", Strings.toString(strike)));
        }
    }

    function symbol(uint256 strike) public view virtual returns (string memory) {
        return name(strike);
    }

    // authorize enables another contract to transfer tokens between accounts.
    // This is for use by deployed ERC20 tokens. See src/single/HodlToken.sol.
    function authorize(address operator) public onlyOwner {
        authorized[operator] = true;

        emit Authorize(operator);
    }

    function safeTransferFrom(address from,
                              address to,
                              uint256 strike,
                              uint256 amount,
                              bytes memory) public override {

        require(to != from, "hodl self transfer");
        require(amount > 0, "hodl zero value transfer");

        if (to == address(0)) {
            revert ERC1155InvalidReceiver(address(0));
        }
        if (from == address(0)) {
            revert ERC1155InvalidSender(address(0));
        }

        if (from != msg.sender &&
            !isApprovedForAll(from, msg.sender) &&
            !authorized[msg.sender]) {

            revert ERC1155MissingApprovalForAll(msg.sender, from);
        }

        uint256[] memory strikes = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        strikes[0] = strike;
        amounts[0] = amount;

        _update(from, to, strikes, amounts);
    }

    function mint(address user, uint256 strike, uint256 amount) public onlyOwner {
        totalSupply[strike] += amount;
        _mint(user, strike, amount, "");

        emit Mint(user, strike, amount);
    }

    function burn(address user, uint256 strike, uint256 amount) public onlyOwner {
        totalSupply[strike] -= amount;
        _burn(user, strike, amount);

        emit Burn(user, strike, amount);
    }
}
