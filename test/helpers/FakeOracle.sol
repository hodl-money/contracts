// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IOracle } from  "../../src/interfaces/IOracle.sol";

contract FakeOracle is IOracle {
    uint80 public roundId = 1;

    uint256 _price;
    uint256 _timestamp;

    mapping(uint80 => uint256) roundToPrice;
    mapping(uint80 => uint256) roundToTimestamp;

    constructor() {
        setPrice(1, 0);
        setTimestamp(block.timestamp, 0);
    }

    function price(uint80 id) external view returns (uint256) {
        if (id == 0) {
            id = roundId;
        }

        return roundToPrice[id];
    }

    function timestamp(uint80 id) external view returns (uint256) {
        if (id == 0) {
            id = roundId;
        }

        return roundToTimestamp[id];
    }

    function setPrice(uint256 price_, uint80 id) public {
        if (id == 0) {
            id = roundId;
        }

        roundToPrice[id] = price_;
    }

    function setTimestamp(uint256 timestamp_, uint80 id) public {
        if (id == 0) {
            id = roundId;
        }

        roundToTimestamp[id] = timestamp_;
    }

    function setRound(uint80 roundId_) public {
        roundId = roundId_;
    }
}
