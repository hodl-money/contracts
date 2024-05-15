// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/Strings.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { Ownable } from  "@openzeppelin/contracts/access/Ownable.sol";

import { Vault } from "../Vault.sol";

contract YMultiToken is ERC1155, Ownable {

    Vault public immutable vault;

    uint256 public nextId = 1;

    // seq -> address -> balance
    mapping (uint256 strikeSeq => mapping(address user => uint256 balance)) public balances;

    // strike -> active seq
    mapping (uint256 strike => uint256 strikeSeq) public strikeSeqs;

    mapping (uint256 => uint256) public totalSupply;

    // Events
    event Mint(address indexed user,
               uint256 indexed strike,
               uint256 amount);

    event Burn(address indexed user,
               uint256 indexed strike,
               uint256 amount);

    event BurnStrike(uint256 indexed strike,
                     uint256 seq);

    constructor(string memory uri_, address vault_) Ownable(msg.sender) ERC1155(uri_) {
        require(vault_ != address(0));

        vault = Vault(vault_);
    }

    function mint(address user, uint256 strike, uint256 amount) public onlyOwner {
        uint256[] memory strikes = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        strikes[0] = strike;
        amounts[0] = amount;
        _update(address(0), user, strikes, amounts);
        totalSupply[strike] += amount;

        emit Mint(user, strike, amount);
    }

    function burn(address user, uint256 strike, uint256 amount) public onlyOwner {
        uint256[] memory strikes = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        strikes[0] = strike;
        amounts[0] = amount;
        _update(user, address(0), strikes, amounts);
        totalSupply[strike] -= amount;

        emit Burn(user, strike, amount);
    }

    function balanceOf(address user, uint256 strike) public override view returns (uint256) {
        uint256 seq = strikeSeqs[strike];
        return balances[seq][user];
    }

    function burnStrike(uint256 strike) public {
        require(msg.sender == address(vault), "only vault");

        strikeSeqs[strike] = nextId++;

        emit BurnStrike(strike, strikeSeqs[strike] - 1);
    }

    // This function is lifted from OZ's ERC1155.sol contract, modified
    // to access balances based on seq number.
    function _update(address from,
                     address to,
                     uint256[] memory strikes,
                     uint256[] memory values) internal override {

        require(strikes.length == values.length, "mismatched update length");

        for (uint256 i = 0; i < strikes.length; ++i) {
            uint256 strike = strikes[i];
            if (strikeSeqs[strike] == 0) {
                strikeSeqs[strike] = nextId++;
            }

            uint256 value = values[i];
            uint256 seq = strikeSeqs[strike];

            if (from != address(0)) {
                uint256 fromBalance = balances[seq][from];
                require(fromBalance >= value, "insufficient balance");
                unchecked {
                    balances[seq][from] = fromBalance - value;
                }
            }

            if (to != address(0)) {
                balances[seq][to] += value;
            }
        }

        if (strikes.length == 1) {
            uint256 strike = strikes[0];
            uint256 value = values[0];
            emit TransferSingle(msg.sender, from, to, strike, value);
        } else {
            emit TransferBatch(msg.sender, from, to, strikes, values);
        }
    }
}
