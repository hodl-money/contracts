// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IOracle } from "../interfaces/IOracle.sol";

import { AggregatorV3Interface } from "../interfaces/chainlink/AggregatorV3Interface.sol";

contract ChainlinkOracle is IOracle {
    AggregatorV3Interface public immutable feed;

    constructor(address feed_) {
        require(feed_ != address(0));

        feed = AggregatorV3Interface(feed_);
    }

    // Returns price with 8 decimals
    function price(uint80 roundId_) external view returns (uint256) {
        if (roundId_ == 0) {
            ( , int256 result, , uint256 updatedAt, ) = feed.latestRoundData();
            require(block.timestamp - 24 hours <= updatedAt, "stale latest price");
            if (result < 0) return 0;
            return uint256(result);
        } else {
            ( , int256 result, , , ) = feed.getRoundData(roundId_);
            if (result < 0) return 0;
            return uint256(result);
        }
    }

    function timestamp(uint80 roundId_) external view returns (uint256) {
        if (roundId_ == 0) {
            ( , , , uint256 updatedAt, ) = feed.latestRoundData();
            require(block.timestamp - 24 hours <= updatedAt, "stale latest timestamp");
            return updatedAt;
        } else {
            ( , , , uint256 updatedAt, ) = feed.getRoundData(roundId_);
            return updatedAt;
        }
    }

    function roundId() external view returns (uint80) {
        (uint80 r, , , , ) = feed.latestRoundData();
        return r;
    }
}
