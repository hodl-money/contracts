// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/console.sol"; 

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IStEth } from "./interfaces/IStEth.sol";
import { IOracle } from "./interfaces/IOracle.sol";

import { HodlMultiToken } from "./HodlMultiToken.sol";
import { YMultiToken } from "./YMultiToken.sol";

contract Vault {
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION_FACTOR = 1 ether;

    uint256 public nextId = 1;

    IStEth public immutable stEth;
    IOracle public immutable oracle;

    HodlMultiToken public immutable hodlMulti;
    YMultiToken public immutable yMulti;

    struct YStake {
        address user;
        uint256 timestamp;
        uint256 strike;
        uint256 epochId;
        uint256 amount;
        uint256 yieldPerTokenClaimed;
    }
    mapping (uint256 => YStake) public yStakes;
    mapping (uint256 => uint256) public yStaked;
    mapping (uint256 => uint256) public terminalYieldPerToken;
    uint256 public yStakedTotal;

    struct HodlStake {
        address user;
        uint256 timestamp;
        uint256 strike;
        uint256 amount;
    }
    mapping (uint256 => HodlStake) public hodlStakes;
    uint256 public hodlStakedTotal;

    uint256 public deposits;
    bool public didTrigger = false;

    /* mapping (uint256 => uint256) public activeEpochs; */
    /* mapping (uint256 => uint256) public epochEnds; */

    uint256 public claimed;

    // Track yield on per-epoch basis to support cumulativeYield(uint256)
    uint256 public yieldPerTokenAcc;
    uint256 public cumulativeYieldAcc;
    struct EpochInfo {
        uint256 strike;
        uint256 yieldPerTokenAcc;
        uint256 cumulativeYieldAcc;
    }
    mapping (uint256 => EpochInfo) infos;

    // Map strike to active epoch ID
    mapping (uint256 => uint256) public epochs;

    event Triggered(uint256 indexed strike,
                    uint256 indexed epoch,
                    uint256 timestamp);


    constructor(address stEth_,
                address oracle_) {
        stEth = IStEth(stEth_);
        oracle = IOracle(oracle_);

        hodlMulti = new HodlMultiToken("");
        yMulti = new YMultiToken("", address(this));
    }

    function _min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }

    /* function trigger(uint256 strike, uint80 roundId) external { */
    /*     uint256 epochId = activeEpochs[strike]; */
    /*     require(epochEnds[epochId] == 0, "V: already triggered"); */
    /*     require(oracle.timestamp(roundId) >= epochEnds[epochId - 1], "V: old round"); */
    /*     require(oracle.price(roundId) >= strike, "V: price low"); */
    /*     epochEnds[epochId] = block.timestamp; */
    /*     activeEpochs[strike] += 1; */
    /*     emit Triggered(strike, block.timestamp); */
    /* } */

    function _checkpoint(uint256 epoch) internal {
        uint256 ypt = yieldPerToken();
        uint256 total = totalCumulativeYield();

        infos[epoch].cumulativeYieldAcc = cumulativeYield(epoch);
        infos[epoch].yieldPerTokenAcc = ypt;

        yieldPerTokenAcc = ypt;
        cumulativeYieldAcc = total;
    }

    function mint(uint256 strike) external payable {
        require(oracle.price(0) <= strike, "strike too low");

        uint256 before = stEth.balanceOf(address(this));
        stEth.submit{value: msg.value}(address(0));
        uint256 delta = stEth.balanceOf(address(this)) - before;
        deposits += delta;

        // create the epoch if needed
        console.log("minting, check if need new epoch", epochs[strike], strike);
        if (epochs[strike] == 0) {
            console.log("set new epoch");
            infos[nextId].strike = strike;
            epochs[strike] = nextId++;
        }

        // track per-epoch yield accumulation
        _checkpoint(epochs[strike]);

        // mint hodl, y is minted on hodl stake
        hodlMulti.mint(msg.sender, strike, delta);
    }

    function redeem(uint256 strike,
                    uint256 amount,
                    uint256 stakeId) external {

        if (stakeId == 0) {
            // Redeem via tokens
            require(hodlMulti.balanceOf(msg.sender, strike) >= amount);
            require(yMulti.balanceOf(msg.sender, strike) >= amount);

            hodlMulti.burn(msg.sender, strike, amount);
            yMulti.burn(msg.sender, strike, amount);
        } else {
            console.log("redeem via staked", strike, stakeId);

            // Redeem via staked hodl token
            HodlStake storage stk = hodlStakes[stakeId];

            require(stk.user == msg.sender, "redeem user");
            require(stk.amount >= amount, "redeem amount");
            require(stk.strike == strike, "redeem strike");
            require(block.timestamp >= stk.timestamp, "redeem timestamp");
            require(oracle.price(0) >= stk.strike, "redeem price");

            // burn the specified hodl stake
            stk.amount -= amount;
            hodlStakedTotal -= amount;

            uint256 epochId = epochs[strike];

            console.log("the epochId is", epochId);

            if (epochId != 0) {
                // checkpoint this strike, to prevent yield accumulation
                _checkpoint(epochId);

                terminalYieldPerToken[epochId] = yieldPerToken();

                // update accounting for total staked y token
                yStakedTotal -= yStaked[epochId];
                yStaked[epochId] = 0;

                // don't checkpoint again, trigger new epoch
                console.log("set strike epochId->0", strike);
                epochs[strike] = 0;
            }

            /* // update accounting for total staked y token */
            /* yStakedTotal -= amount; */

            // burn all staked y tokens at that strike
            yMulti.burnStrike(strike);
        }

        amount = _min(amount, stEth.balanceOf(address(this)));
        stEth.transfer(msg.sender, amount);

        deposits -= amount;
    }

    function yStake(uint256 strike, uint256 amount) public returns (uint256) {

        require(yMulti.balanceOf(msg.sender, strike) >= amount, "y stake balance");
        uint256 epochId = epochs[strike];

        _checkpoint(epochId);

        yMulti.burn(msg.sender, strike, amount);
        uint256 id = nextId++;

        uint256 ypt = yieldPerToken();
        yStakes[id] = YStake({
            user: msg.sender,
            timestamp: block.timestamp,
            strike: strike,
            epochId: epochId,
            amount: amount,
            yieldPerTokenClaimed: ypt });
        yStaked[epochId] += amount;
        yStakedTotal += amount;

        return id;
    }

    function claimable(uint256 stakeId) public view returns (uint256) {
        YStake storage stk = yStakes[stakeId];
        uint256 ypt;

        if (epochs[stk.strike] == stk.epochId) {
            // active epoch
            ypt = yieldPerToken() - stk.yieldPerTokenClaimed;
        } else {
            // passed epoch
            ypt = terminalYieldPerToken[stk.epochId] - stk.yieldPerTokenClaimed;
        }

        return ypt * stk.amount;
    }

    function hodlStake(uint256 strike, uint256 amount) public returns (uint256) {
        require(hodlMulti.balanceOf(msg.sender, strike) >= amount, "hodl stake balance");

        hodlMulti.burn(msg.sender, strike, amount);
        yMulti.mint(msg.sender, strike, amount);

        uint256 id = nextId++;
        hodlStakes[id] = HodlStake({
            user: msg.sender,
            timestamp: block.timestamp,
            strike: strike,
            amount: amount });
        hodlStakedTotal += amount;  // TODO: can omit?

        /* emit HodlStaked(msg.sender, */
        /*             id, */
        /*             block.timestamp, */
        /*             strike, */
        /*             amount); */

        return id;
    }

    /* function _hodlBurnStake(uint256 stakeId, uint256 amount) internal { */
    /*     HodlStake storage stk = stakes[id];  */
    /*     require(stk.amount >= amount, "YMT: amount"); */
    /*     stk.amount -= amount; */
    /* } */

    function disburse(address recipient, uint256 amount) external {
        require(msg.sender == address(yMulti));

        IERC20(stEth).safeTransfer(recipient, amount);
        claimed += amount;
    }

    function yieldPerToken() public view returns (uint256) {
        if (yStakedTotal == 0) return 0;
        uint256 deltaCumulative = totalCumulativeYield() - cumulativeYieldAcc;
        uint256 incr = deltaCumulative * PRECISION_FACTOR / yStakedTotal;
        return yieldPerTokenAcc + incr;
    }

    function cumulativeYield(uint256 epochId) public view returns (uint256) {
        require(epochId < nextId, "invalid epoch");

        uint256 ypt;
        uint256 strike = infos[epochId].strike;
        if (epochs[strike] == epochId) {
            console.log("compute for active epoch", strike, epochId);
            uint256 y = yieldPerToken();
            console.log("-ypt()", y);
            console.log("-acc  ", infos[epochId].yieldPerTokenAcc);
            console.log("-cum  ", infos[epochId].cumulativeYieldAcc);
            console.log("-num  ", yStaked[epochId]);

            // active epoch
            ypt = (y
                   - infos[epochId].yieldPerTokenAcc);
        } else {
            console.log("compute for passed epoch", strike, epochId);

            // passed epoch
            ypt = (terminalYieldPerToken[epochId]
                   - infos[epochId].yieldPerTokenAcc);
        }

        return (infos[epochId].cumulativeYieldAcc +
                yStaked[epochId] * ypt / PRECISION_FACTOR);
    }

    function totalCumulativeYield() public view returns (uint256) {
        uint256 delta = stEth.balanceOf(address(this)) - deposits;
        uint256 result = delta + claimed;
        return result;
    }
}
