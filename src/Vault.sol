// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from  "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from  "@openzeppelin/contracts/access/Ownable.sol";

import { IOracle } from "./interfaces/IOracle.sol";
import { IYieldSource } from "./interfaces/IYieldSource.sol";

import { HodlMultiToken } from "./multi/HodlMultiToken.sol";
import { YMultiToken } from "./multi/YMultiToken.sol";
import { HodlToken } from  "./single/HodlToken.sol";

// Vault is the core contract for HODL.money. It contains most of the accounting
// logic around token mechanics and yield.
//
// The protocol is based on two complementary tokens, plETH and ybETH, which
// represent long and short positions. The plETH tokens (long position) redeem
// into the underlying token (eg. stETH) after a particular strike price has
// been reached. The ybETH tokens (short position) receive yield from the
// underlying *until* the strike price is reached.
//
// The plETH side makes more profit the faster the strike hits, whereas ybETH
// side wants the strike price to hit as long in the future as possible, ideally
// never.
//
// For more information, visit https://docs.hodl.money/
//
// Technical details:
//
// * Minting
// The plETH and ybETH tokens are minted by the Vault. The user transfers some
// amount of ETH into the contract, and he mints the same amount of plETH and
// ybETH as he transferred, less fees. For example, a deposit of 1 ETH gives
// the user 1 plETH and 1 ybETH at the strike he chose.
//
// * Staking plETH
// Users may stake plETH in anticipation of the strike price hitting. If the
// the user stakes his plETH, he can redeem that stake for underlying stETH once
// the strike hits. The benefit of staking is that he can do the redemption even
// if the price later falls back down below the strike.
//
// * Staking ybETH
// Users need to stake ybETH to receive yield. Staked ybETH receives yield until
// the strike price hits. Staking is used to track how much yield each user is
// entitled to. Unstaked ybETH does not get yield, and overflow yield is evenly
// distributed across the other staked positions.
//
// * Epochs
// Strikes are tracked on a per-epoch basis. This is to account for the
// possibility that the price rises above a strike, then back below, then back
// above again. Multiple crosses across a strike price *may* result in multiple
// epochs.
//
// Each epoch has a start time, and is associated with a strike price. When the
// price rises above the strike, plETH redemption is enabled in that epoch. This
// means all staked plETH within that epoch can be redeemed. In addition, once
// redemption is enabled for particular epoch, ybETH in that epoch stops
// accumulating yield.
//
// * Burning ybETH
// When a strike price hits, all ybETH stakes at that strike stop accumulating
// yield. In addition, all ybETH at that strike is burned, meaning user balances
// go to zero.
//
// * Merging
// Another way to recover the underlying is to merge equal parts plETH and
// ybETH. This is called merging.
//
// * ERC-1155 tokens and ERC-20 wrappers
// The plETH and ybETH tokens are each implemented using the ERC-1155 standard
// for semi-fungible tokens. The tokens are fungible within a strike, eg. all
// plETH at strike of $10,000 are fungible. However, $9,999 is non-fungible with
// $10,000.
//
// For compatibility with broader Defi, an ERC-20 wrapper can be deployed for
// the plETH token at any strike. For example, you can deploy a ERC-20 token
// that represents plETH at strike of $10,000. The token contracts let the
// ERC-20 wrapper make transfers within the ERC-1155 contract.
//
// * Naming
// In code, 'hodl' tokens refer to plETH, and 'y' tokens refer to ybETH.
//
contract Vault is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION_FACTOR = 1 ether;

    uint256 public constant FEE_BASIS = 100_00;
    uint256 public constant MAX_FEE = 10_00;  // 10%

    uint48 public nextId = 1;
    uint256 public fee = 0;

    IYieldSource public immutable source;
    IOracle public immutable oracle;

    HodlMultiToken public immutable hodlMulti;
    YMultiToken public immutable yMulti;

    address public treasury;

    // Keep track of deployed erc20 hodl tokens
    mapping (uint64 strike => IERC20 token) public deployments;

    // Track staked hodl tokens, which are eligible for redemption
    struct HodlStake {
        address user;
        uint48 epochId;
        uint256 amount;
    }
    mapping (uint48 stakedId => HodlStake) public hodlStakes;

    struct YStake {
        address user;
        uint48 epochId;
        uint256 amount;
        uint256 claimed;
        uint256 acc;
    }
    mapping (uint48 stakeId => YStake) public yStakes;

    // Amount of y tokens staked in an epoch
    mapping (uint48 epochId => uint256 amount) public yStaked;

    // Amount of y tokens staked in total
    uint256 public yStakedTotal;

    // For terminated epoch, the final yield per token
    mapping (uint48 epochId => uint256 ypt) public terminalYieldPerToken;

    // Amount of total deposits
    uint256 public deposits;

    // Amount of yield claimed
    uint256 public claimed;

    // Checkpointed yield per token, updated when deposits go up/down
    uint256 public yieldPerTokenAcc;

    // Checkpointed cumulative yield, updated when deposits go up/down
    uint256 public cumulativeYieldAcc;

    // Track yield per token and cumulative yield on a per epoch basis
    struct EpochInfo {
        uint64 strike;
        bool closed;
        uint256 timestamp;
        uint256 yieldPerTokenAcc;
        uint256 cumulativeYieldAcc;
    }
    mapping (uint48 epochId => EpochInfo) infos;

    // Map strike to active epoch ID
    mapping (uint64 strike => uint48 epochId) public epochs;

    // Events
    event SetTreasury(address treasury);

    event SetFee(uint256 fee);

    event DeployERC20(uint64 indexed strike,
                      address token);

    event Mint(address indexed user,
               uint256 indexed strike,
               uint256 amount);

    event Merge(address indexed user,
                uint64 indexed strike,
                uint256 amount);

    event Redeem(address indexed user,
                 uint64 indexed strike,
                 uint48 indexed stakeId,
                 uint256 amount);

    event RedeemTokens(address indexed user,
                       uint64 indexed strike,
                       uint256 amount);

    event HodlStaked(address indexed user,
                     uint64 indexed strike,
                     uint48 indexed stakeId,
                     uint256 amount);

    event HodlUnstake(address indexed user,
                      uint64 indexed strike,
                      uint48 indexed stakeId,
                      uint256 amount);

    event YStaked(address indexed user,
                  uint64 indexed strike,
                  uint48 indexed stakeId,
                  uint256 amount);

    event YUnstake(address indexed user,
                   uint64 indexed strike,
                   uint48 indexed stakeId,
                   uint256 amount);

    event Claim(address indexed user,
                uint64 indexed strike,
                uint48 indexed stakeId,
                uint256 amount);

    constructor(address source_,
                address oracle_,
                address treasury_) ReentrancyGuard() Ownable(msg.sender) {
        require(source_ != address(0));
        require(oracle_ != address(0));
        require(treasury_ != address(0));

        source = IYieldSource(source_);
        oracle = IOracle(oracle_);
        treasury = treasury_;

        hodlMulti = new HodlMultiToken("");
        yMulti = new YMultiToken("", address(this));
    }

    function setTreasury(address treasury_) external nonReentrant onlyOwner {
        require(treasury_ != address(0), "zero address");

        treasury = treasury_;

        emit SetTreasury(treasury);
    }

    function setFee(uint256 fee_) external nonReentrant onlyOwner {
        require(fee_ <= MAX_FEE, "max fee");

        fee = fee_;

        emit SetFee(fee);
    }

    function deployERC20(uint64 strike) external nonReentrant returns (address) {
        require(address(deployments[strike]) == address(0), "already deployed");

        HodlToken hodl = new HodlToken(address(hodlMulti), strike);
        hodlMulti.authorize(address(hodl));

        deployments[strike] = hodl;

        emit DeployERC20(strike, address(hodl));

        return address(hodl);
    }

    function _min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }

    function _checkpoint(uint48 epochId) internal {
        uint256 ypt = yieldPerToken();
        uint256 total = totalCumulativeYield();

        infos[epochId].cumulativeYieldAcc = cumulativeYield(epochId);
        infos[epochId].yieldPerTokenAcc = ypt;

        yieldPerTokenAcc = ypt;
        cumulativeYieldAcc = total;
    }

    function previewMint(uint256 value) external view returns (uint256, uint256) {
        if (fee == 0) {
            return (value, 0);
        } else {
            uint256 feeValue = value * fee / FEE_BASIS;
            return (value - feeValue, feeValue);
        }
    }

    function _createEpoch(uint64 strike) internal {
        infos[nextId].strike = strike;
        infos[nextId].timestamp = oracle.timestamp(0);
        epochs[strike] = nextId++;
    }

    function mint(uint64 strike) external nonReentrant payable returns (uint256) {
        require(oracle.price(0) < strike, "strike too low");

        uint256 value = msg.value;
        uint256 feeValue = value * fee / FEE_BASIS;
        if (feeValue > 0) {
            payable(treasury).transfer(feeValue);
            value -= feeValue;
        }

        // Account get the actual amount after deposit into underlying
        uint256 amount = source.deposit{value: value}();
        deposits += amount;

        // Create the epoch if needed
        if (epochs[strike] == 0) {
            _createEpoch(strike);
        }

        // Mint hodl + y
        hodlMulti.mint(msg.sender, strike, amount);
        yMulti.mint(msg.sender, strike, amount);

        emit Mint(msg.sender, strike, amount);

        return amount;
    }

    function canRedeem(uint48 stakeId, uint80 roundId) public view returns (bool) {
        HodlStake storage stk = hodlStakes[stakeId];

        // Check if there is anything to redeem
        if (stk.amount == 0) {
            return false;
        }

        // Check the two conditions that enable redemption:

        // (1) If price is currently above strike
        uint64 strike = infos[stk.epochId].strike;
        if (oracle.price(roundId) >= strike &&
            oracle.timestamp(roundId) >= infos[stk.epochId].timestamp) {

            return true;
        }

        // (2) If this is a passed epoch
        if (infos[stk.epochId].closed) {
            return true;
        }

        // Neither is true, so can't redeem
        return false;
    }

    // _withdraw computes and executes a withdraw. It handles negative rebases,
    // and returns the actual number of tokens sent to the user.
    function _withdraw(uint256 amount, address user) private returns (uint256) {
        uint256 actual = amount;

        // Compute proportional share in case of negative rebase
        if (source.balance() < deposits) {
            actual = amount * source.balance() / deposits;
        }

        actual = _min(actual, source.balance());
        source.withdraw(actual, user);
        return actual;
    }

    // merge combines equal parts y + hodl tokens into the underlying asset.
    function merge(uint64 strike, uint256 amount) external nonReentrant {
        require(hodlMulti.balanceOf(msg.sender, strike) >= amount, "merge hodl balance");
        require(yMulti.balanceOf(msg.sender, strike) >= amount, "merge y balance");

        hodlMulti.burn(msg.sender, strike, amount);
        yMulti.burn(msg.sender, strike, amount);

        uint256 actual = _withdraw(amount, msg.sender);
        deposits -= amount;

        emit Merge(msg.sender, strike, actual);
    }

    // redeem converts a stake into the underlying tokens if the price has
    // touched the strike. The redemption can happen even if the price later
    // dips below.
    function redeem(uint48 stakeId, uint80 roundId, uint256 amount) external nonReentrant {
        HodlStake storage stk = hodlStakes[stakeId];

        require(stk.user == msg.sender, "redeem user");
        require(stk.amount >= amount, "redeem amount");
        require(canRedeem(stakeId, roundId), "cannot redeem");

        // Burn the specified hodl stake
        stk.amount -= amount;

        // Close out before updating `deposits`
        _closeOutEpoch(stk.epochId);

        uint256 actual = _withdraw(amount, msg.sender);
        deposits -= amount;

        emit Redeem(msg.sender, infos[stk.epochId].strike, stakeId, actual);
    }

    // redeemTokens redeems unstaked tokens if the price is currently above the
    // strike. Unlike redeemStake, the redemption cannot happen if the price
    // later dips below.
    function redeemTokens(uint64 strike, uint256 amount) external nonReentrant {
        require(oracle.price(0) >= strike, "below strike");
        require(hodlMulti.balanceOf(msg.sender, strike) >= amount, "redeem tokens balance");

        hodlMulti.burn(msg.sender, strike, amount);

        // Close out before updating `deposits`
        _closeOutEpoch(epochs[strike]);

        uint256 actual = _withdraw(amount, msg.sender);
        deposits -= amount;

        emit RedeemTokens(msg.sender, strike, actual);
    }

    function _closeOutEpoch(uint48 epochId) private {
        if (infos[epochId].closed) {
            return;
        }

        EpochInfo storage info = infos[epochId];
        require(info.strike != 0, "cannot close epoch 0");

        // Checkpoint this strike, to prevent yield accumulation
        _checkpoint(epochId);

        // Record the ypt at redemption time
        terminalYieldPerToken[epochId] = yieldPerToken();

        // Update accounting for staked y tokens
        yStakedTotal -= yStaked[epochId];
        yStaked[epochId] = 0;

        // Burn all staked y tokens at that strike
        yMulti.burnStrike(info.strike);

        // Don't checkpoint again, trigger new epoch
        _createEpoch(info.strike);

        // Remember that we closed this epoch
        info.closed = true;
    }

    // yStake takes y tokens and stakes them, which makes those tokens receive
    // yield. Only staked y tokens receive yield. This is to enable proper yield
    // accounting in relation to hodl token redemptions.
    function yStake(uint64 strike, uint256 amount, address user) external nonReentrant returns (uint48) {
        require(yMulti.balanceOf(msg.sender, strike) >= amount, "y stake balance");
        uint48 epochId = epochs[strike];

        _checkpoint(epochId);

        yMulti.burn(msg.sender, strike, amount);
        uint48 id = nextId++;

        uint256 ypt = yieldPerToken();
        yStakes[id] = YStake({
            user: user,
            epochId: epochId,
            amount: amount,
            // + 1 to tip rounding error in protocol favor
            claimed: (ypt * amount / PRECISION_FACTOR) + 1,
            acc: 0 });

        yStaked[epochId] += amount;
        yStakedTotal += amount;

        emit YStaked(user, strike, id, amount);

        return id;
    }

    // yUnstake takes a stake and returns all the y tokens to the user. For
    // simplicity, partial unstakes are not possible. The user may unstake
    // entirely, and then re-stake a portion of his tokens.
    function yUnstake(uint48 stakeId, address user) external nonReentrant {
        YStake storage stk = yStakes[stakeId];
        require(stk.user == msg.sender, "y unstake user");
        require(stk.amount > 0, "y unstake zero");
        require(terminalYieldPerToken[stk.epochId] == 0, "y unstake closed epoch");

        uint256 amount = stk.amount;

        _checkpoint(stk.epochId);

        stk.acc = stk.claimed + claimable(stakeId);
        yStaked[stk.epochId] -= amount;
        yStakedTotal -= amount;
        stk.amount = 0;

        uint64 strike = infos[stk.epochId].strike;
        yMulti.mint(user, strike, amount);

        emit YUnstake(user, strike, stakeId, amount);
    }

    // _stakeYpt somputes the yield per token of a particular stake of y tokens.
    function _stakeYpt(uint48 stakeId) internal view returns (uint256) {
        YStake storage stk = yStakes[stakeId];
        if (epochs[infos[stk.epochId].strike] == stk.epochId) {
            // Active epoch
            return yieldPerToken();
        } else {
            // Closed epoch
            return terminalYieldPerToken[stk.epochId];
        }
    }

    // claimable computes the amount of underlying available to claim for a
    // particular stake.
    function claimable(uint48 stakeId) public view returns (uint256) {
        YStake storage stk = yStakes[stakeId];

        uint256 c;
        if (stk.amount == 0) {
            // Unstaked, use saved value
            c = stk.acc;
        } else {
            // Staked, use live value
            assert(stk.acc == 0);  // Only set when unstaking
            uint256 ypt = _stakeYpt(stakeId);
            c = ypt * stk.amount / PRECISION_FACTOR;
        }

        return stk.claimed > c ? 0 : c - stk.claimed;
    }

    // claim transfers to the user his claimable yield.
    function claim(uint48 stakeId) external nonReentrant {
        YStake storage stk = yStakes[stakeId];
        require(stk.user == msg.sender, "y claim user");

        uint256 amount = _withdraw(claimable(stakeId), msg.sender);
        stk.claimed += amount;
        claimed += amount;

        emit Claim(msg.sender, infos[stk.epochId].strike, stakeId, amount);
    }

    // hodlStake takes some hodl tokens, and stakes them. This make them
    // eligible for redemption when the strike price hits.
    function hodlStake(uint64 strike, uint256 amount, address user) external nonReentrant returns (uint48) {
        require(hodlMulti.balanceOf(msg.sender, strike) >= amount, "hodl stake balance");

        hodlMulti.burn(msg.sender, strike, amount);

        uint48 id = nextId++;
        hodlStakes[id] = HodlStake({
            user: user,
            epochId: epochs[strike],
            amount: amount });

        emit HodlStaked(user, strike, id, amount);

        return id;
    }

    // hodlUnstake can be used to return some portion of staked tokens to the
    // user.
    function hodlUnstake(uint48 stakeId, uint256 amount, address user) external nonReentrant {
        HodlStake storage stk = hodlStakes[stakeId];
        require(stk.user == msg.sender, "hodl unstake user");
        require(stk.amount >= amount, "hodl unstake amount");

        uint64 strike = infos[stk.epochId].strike;
        hodlMulti.mint(user, strike, amount);

        stk.amount -= amount;

        emit HodlUnstake(user, strike, stakeId, amount);
    }

    // yieldPerToken computes the global yield per token, meaning how much
    // yield every y token has accumulated thus far.
    function yieldPerToken() public view returns (uint256) {
        uint256 total = totalCumulativeYield();
        if (total < cumulativeYieldAcc) return 0;
        uint256 deltaCumulative = total - cumulativeYieldAcc;
        
        if (yStakedTotal == 0) return yieldPerTokenAcc;
        uint256 incr = deltaCumulative * PRECISION_FACTOR / yStakedTotal;
        return yieldPerTokenAcc + incr;
    }

    // cumulativeYield calculates the total amount of yield a particular epoch
    // is entitled to. This yield is split accordingly among the staked y
    // tokens.
    function cumulativeYield(uint48 epochId) public view returns (uint256) {
        require(epochId < nextId, "invalid epoch");

        uint256 ypt;

        if (infos[epochId].closed) {
            // Passed epoch
            ypt = terminalYieldPerToken[epochId] - infos[epochId].yieldPerTokenAcc;
        } else {
            // Active epoch
            ypt = yieldPerToken() - infos[epochId].yieldPerTokenAcc;
        }

        return (infos[epochId].cumulativeYieldAcc +
                yStaked[epochId] * ypt / PRECISION_FACTOR);
    }

    // totalCumulativeYield calculates the total amount of yield for this vault,
    // accross all epochs and strikes.
    function totalCumulativeYield() public view returns (uint256) {
        uint256 balance = source.balance();
        uint256 delta = balance < deposits ? 0 : balance - deposits;
        uint256 result = delta + claimed;
        return result;
    }
}
