// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from  "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from  "@openzeppelin/contracts/access/Ownable.sol";

import { Vault } from  "./Vault.sol";

import { IWrappedETH } from "./interfaces/IWrappedETH.sol";
import { IWstETH } from "./interfaces/IWstETH.sol";
import { ISwapRouter } from "./interfaces/uniswap/ISwapRouter.sol";
import { IQuoterV2 } from "./interfaces/uniswap/IQuoterV2.sol";
import { IUniswapV3Factory } from "./interfaces/uniswap/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "./interfaces/uniswap/IUniswapV3Pool.sol";
import { INonfungiblePositionManager } from "../src/interfaces/uniswap/INonfungiblePositionManager.sol";
import { IPool } from "../src/interfaces/aave/IPool.sol";


// Router implements some common user actions with easy interfaces. These same
// user actions could be achieved by interfacing directly with Vault, but they
// are more easily accomplished here:
//
//  - Adding liquidity
//  - Buying/selling hodl tokens
//  - Buying/selling y tokens
//
contract Router is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint8 public constant LOAN_Y_BUY = 1;
    uint8 public constant LOAN_Y_SELL = 2;
    uint256 public constant SEARCH_TOLERANCE = 1e9;
    uint256 public constant REFUND_DUST_LIMIT = 1e6;

    uint24 public hodlPoolFee = 3000;
    uint24 public wstethWethPoolFee = 100;

    Vault public immutable vault;
    IWrappedETH public immutable weth;
    IERC20 public immutable steth;
    IWstETH public immutable wsteth;

    // Uniswap
    IUniswapV3Factory public uniswapV3Factory;
    ISwapRouter public swapRouter;
    IQuoterV2 public quoterV2;
    INonfungiblePositionManager public manager;

    // Aave
    IPool public aavePool;

    // Events
    event AddLiquidity(address indexed user,
                       uint64 indexed strike,
                       uint256 hodlAmount,
                       uint256 wethAmount);

    event HodlBuy(address indexed user,
                  uint64 indexed strike,
                  uint256 amountIn,
                  uint256 amountOut,
                  uint48 stakeId);

    event HodlSell(address indexed user,
                   uint64 indexed strike,
                   uint256 amountIn,
                   uint256 amountOut);

    event YBuy(address indexed user,
               uint64 indexed strike,
               uint256 amountIn,
               uint256 amountOut,
               uint256 loan);

    event YSell(address indexed user,
                uint64 indexed strike,
                uint256 amountIn,
                uint256 amountOut,
                uint256 loan);

    event SetHodlPoolFee(uint24 fee);
    event SetWstethWethPoolFee(uint24 fee);

    constructor(address vault_,
                address weth_,
                address steth_,
                address wsteth_,
                address uniswapV3Factory_,
                address swapRouter_,
                address manager_,
                address quoterV2_,
                address aavePool_)
        ReentrancyGuard()
        Ownable(msg.sender) {

        require(vault_ != address(0));
        require(weth_ != address(0));
        require(steth_ != address(0));
        require(wsteth_ != address(0));
        require(uniswapV3Factory_ != address(0));
        require(swapRouter_ != address(0));
        require(manager_ != address(0));
        require(quoterV2_ != address(0));
        require(aavePool_ != address(0));

        vault = Vault(vault_);
        weth = IWrappedETH(weth_);
        steth = IERC20(steth_);
        wsteth = IWstETH(wsteth_);
        uniswapV3Factory = IUniswapV3Factory(uniswapV3Factory_);
        swapRouter = ISwapRouter(swapRouter_);
        manager = INonfungiblePositionManager(manager_);
        quoterV2 = IQuoterV2(quoterV2_);
        aavePool = IPool(aavePool_);
    }

    function pool(uint64 strike) public view returns (address) {
        IERC20 hodlToken = vault.deployments(strike);
        (address token0, address token1) = address(hodlToken) < address(weth)
            ? (address(hodlToken), address(weth))
            : (address(weth), address(hodlToken));

        return uniswapV3Factory.getPool(token0, token1, hodlPoolFee);
    }

    function setWstethWethPoolFee(uint24 wstethWethPoolFee_) external onlyOwner {
        require(uniswapV3Factory(address(wsteth), address(weth)) != address(0),
                "no uniswap pool");

        wstethWethPoolFee = wstethWethPoolFee_;

        emit SetWstethWethPoolFee(wstethWethPoolFee);
    }

    function setHodlPoolFee(uint24 hodlPoolFee_) external onlyOwner {
        hodlPoolFee = hodlPoolFee_;

        emit SetHodlPoolFee(hodlPoolFee);
    }

    // Add liquidity respecting the fact that 1 hodl token should never trade
    // above a price of 1 ETH.
    function addLiquidity(uint64 strike,
                          uint256 mintAmount,
                          uint256 amountHodlMin,
                          uint256 amountWethMin,
                          uint24 tick) external nonReentrant payable {

        IERC20 hodlToken = vault.deployments(strike);
        require(address(hodlToken) != address(0), "no deployed ERC20");

        uint256 delta = vault.mint{value: mintAmount}(strike);

        // y isn't used for liquidity, give it to the user
        vault.yMulti().safeTransferFrom(address(this), msg.sender, strike, delta, "");

        uint256 wethAmount = msg.value - mintAmount;
        weth.deposit{value: wethAmount}();

        INonfungiblePositionManager.MintParams memory params;
        if (address(hodlToken) < address(weth)) {
            params = INonfungiblePositionManager.MintParams({
                token0: address(hodlToken),
                token1: address(weth),
                fee: hodlPoolFee,
                tickLower: -int24(tick),
                tickUpper: 0,
                amount0Desired: delta,
                amount1Desired: wethAmount,
                amount0Min: amountHodlMin,
                amount1Min: amountWethMin,
                recipient: msg.sender,
                deadline: block.timestamp });
        } else {
            params = INonfungiblePositionManager.MintParams({
                token0: address(weth),
                token1: address(hodlToken),
                fee: hodlPoolFee,
                tickLower: 0,
                tickUpper: int24(tick),
                amount0Desired: wethAmount,
                amount1Desired: delta,
                amount0Min: amountWethMin,
                amount1Min: amountHodlMin,
                recipient: msg.sender,
                deadline: block.timestamp });
        }

        IERC20(params.token0).forceApprove(address(manager), params.amount0Desired);
        IERC20(params.token1).forceApprove(address(manager), params.amount1Desired);

        manager.mint(params);

        _refundLeftoverWeth();

        emit AddLiquidity(msg.sender, strike, delta, wethAmount);
    }

    function previewHodlBuy(uint64 strike, uint256 amount) external returns (uint256) {
        IERC20 token = vault.deployments(strike);
        require(address(token) != address(0), "no deployed ERC20");
        address uniPool = pool(strike);
        require(uniPool != address(0), "no uni pool");

        IQuoterV2.QuoteExactInputSingleParams memory params = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(token),
            amountIn: amount,
            fee: hodlPoolFee,
            sqrtPriceLimitX96: 0 });

        (uint256 amountOut, , , ) = quoterV2.quoteExactInputSingle(params);

        return amountOut;
    }

    function hodlBuy(uint64 strike, uint256 minOut, bool shouldStake) external nonReentrant payable returns (uint256, uint48) {
        IERC20 token = vault.deployments(strike);
        require(address(token) != address(0), "no deployed ERC20");
        address uniPool = pool(strike);
        require(uniPool != address(0), "no uni pool");

        weth.deposit{value: msg.value}();

        IERC20(address(weth)).forceApprove(address(address(swapRouter)), msg.value);

        address receiver = shouldStake ? address(this) : msg.sender;

        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(token),
                fee: hodlPoolFee,
                recipient: receiver,
                deadline: block.timestamp,
                amountIn: msg.value,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0 });

        uint256 out = swapRouter.exactInputSingle(params);
        uint48 stakeId = 0;

        if (shouldStake) {
            stakeId = vault.hodlStake(strike, out, msg.sender);
        }

        _refundLeftoverWeth();

        emit HodlBuy(msg.sender, strike, msg.value, out, stakeId);

        return (out, stakeId);
    }

    function previewHodlSell(uint64 strike, uint256 amount) external returns (uint256) {
        IERC20 token = vault.deployments(strike);
        require(address(token) != address(0), "no deployed ERC20");
        address uniPool = pool(strike);
        require(uniPool != address(0), "no uni pool");

        IQuoterV2.QuoteExactInputSingleParams memory params = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: address(token),
            tokenOut: address(weth),
            amountIn: amount,
            fee: hodlPoolFee,
            sqrtPriceLimitX96: 0 });

        (uint256 out, , , ) = quoterV2.quoteExactInputSingle(params);

        return out;
    }

    function hodlSell(uint64 strike, uint256 amount, uint256 minOut) external nonReentrant payable returns (uint256) {
        IERC20 token = vault.deployments(strike);
        require(address(token) != address(0), "no deployed ERC20");
        address uniPool = pool(strike);
        require(uniPool != address(0), "no uni pool");

        token.safeTransferFrom(msg.sender, address(this), amount);
        token.forceApprove(address(address(swapRouter)), amount);

        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token),
                tokenOut: address(weth),
                fee: hodlPoolFee,
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0 });

        uint256 out = swapRouter.exactInputSingle(params);

        emit HodlSell(msg.sender, strike, amount, out);

        return out;
    }

    // Find the appropriate loan size for a y token purchase of `value` ETH.
    function _searchLoanSize(uint64 strike,
                             uint256 value,
                             uint256 lo,
                             uint256 hi,
                             uint256 n) private returns (uint256, uint256) {

        if (n == 0) {
            return (0, 0);
        }

        IERC20 token = vault.deployments(strike);
        uint256 loan = (hi + lo) / 2;
        uint256 fee = _flashLoanFee(loan);
        uint256 debt = loan + fee;

        (uint256 afterFees, ) = vault.previewMint(value + loan);

        IQuoterV2.QuoteExactInputSingleParams memory params = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: address(token),
            tokenOut: address(weth),
            amountIn: afterFees,
            fee: hodlPoolFee,
            sqrtPriceLimitX96: 0 });

        (uint256 out, , , ) = quoterV2.quoteExactInputSingle(params);

        if (out > debt) {
            // Output is enough to payoff loan + fee, can take larger loan
            if (out - debt < SEARCH_TOLERANCE) {
                return (loan, afterFees);
            }
            return _searchLoanSize(strike, value, loan, hi, n - 1);

        } else {
            // Output to small to payoff loan + fee, reduce loan size
            return _searchLoanSize(strike, value, lo, loan, n - 1);
        }
    }

    function _flashLoanFee(uint256 loan) private view returns (uint256) {
        uint256 percent = aavePool.FLASHLOAN_PREMIUM_TOTAL();
        return loan * percent / 10_000;
    }

    function previewYBuy(uint64 strike, uint256 value) external returns (uint256, uint256) {
        IERC20 token = vault.deployments(strike);
        require(address(token) != address(0), "no deployed ERC20");
        address uniPool = pool(strike);
        require(uniPool != address(0), "no uni pool");

        (uint256 loan, uint256 out) = _searchLoanSize(strike, value, 0, 1000 * value, 64);

        return (out, loan);
    }

    function yBuy(uint64 strike,
                  uint256 loan,
                  uint256 minOut) external nonReentrant payable returns (uint256) {

        uint256 value = msg.value;
        bytes memory data = abi.encode(LOAN_Y_BUY, msg.sender, strike, value + loan, minOut);

        uint256 before = vault.yMulti().balanceOf(address(this), strike);
        aavePool.flashLoanSimple(address(this), address(weth), loan, data, 0);
        uint256 delta = vault.yMulti().balanceOf(address(this), strike) - before;
        require(delta >= minOut, "y min out");

        vault.yMulti().safeTransferFrom(address(this), msg.sender, strike, delta, "");

        _refundLeftoverWeth();

        emit YBuy(msg.sender, strike, msg.value, delta, loan);

        return delta;
    }

    function _yBuyViaLoan(uint256 loan,
                          uint256 fee,
                          address,
                          uint64 strike,
                          uint256 amount) private returns (bool) {

        IERC20 token = vault.deployments(strike);
        require(address(token) != address(0), "no deployed ERC20");

        // mint hodl + y tokens
        weth.withdraw(loan);

        require(address(this).balance >= amount, "expected balance >= amount");
        amount = vault.mint{value: amount}(strike);

        // sell hodl tokens to repay debt
        token.forceApprove(address(swapRouter), amount);

        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token),
                tokenOut: address(weth),
                fee: hodlPoolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0 });
        swapRouter.exactInputSingle(params);

        // approve repayment
        IERC20(address(weth)).forceApprove(address(aavePool), loan + fee);

        return true;
    }

    function previewYSell(uint64 strike, uint256 amount) external returns (uint256, uint256) {
        IERC20 token = vault.deployments(strike);

        // The y token sale works by buying hodl tokens and merging y + hodl
        // into steth. We'll do a preview of both steps.

        // Step 1: weth -> hodl swap.
        // 
        // Here, we figure out the loan size needed to buy `amount` of hodl
        // tokens. when we have `amount` hodl tokens, we'll be able to merge
        // them with `amount` y tokens to get steth for step 2.
        //
        // The quote we're obtaining is for the weth -> hodl token swap, which
        // tells us the amount of weth we need, and therefore this quote is the
        // loan size.
        IQuoterV2.QuoteExactOutputSingleParams memory params = IQuoterV2.QuoteExactOutputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(token),
            amount: amount, // Amount means quantity hodl tokens output
            fee: hodlPoolFee,
            sqrtPriceLimitX96: 0 });
        (uint256 loan, , , ) = quoterV2.quoteExactOutputSingle(params);

        // Step 2: wsteth -> weth
        // 
        // The actual sale will merge y + hodl tokens for steth, but the flash
        // loan was in weth. We'll need to convert steth -> weth to repay the
        // flash loan. The remainder after loan repayment is what goes to the
        // user.
        uint256 amountWsteth = wsteth.getWstETHByStETH(amount);
        IQuoterV2.QuoteExactInputSingleParams memory paramsWeth = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: address(wsteth),
            tokenOut: address(weth),
            amountIn: amountWsteth,
            fee: wstethWethPoolFee,
            sqrtPriceLimitX96: 0 });
        (uint256 amountOutWeth, , , ) = quoterV2.quoteExactInputSingle(paramsWeth);

        // It's possible the LP gives is negative profit on the sale.
        if (amountOutWeth < _flashLoanFee(loan) + loan) {
            return (0, 0);
        }

        uint256 profit = amountOutWeth - _flashLoanFee(loan) - loan;

        return (loan, profit);
    }

    function ySell(uint64 strike,
                   uint256 loan,
                   uint256 amount,
                   uint256 minOut) external nonReentrant returns (uint256) {

        // The y token sale has these steps:
        //
        //  1. Obtain flash loan of weth
        //  2. Use flash loan to purchase hodl tokens
        //  3. Merge y + hodl into steth
        //  4. Sell steth to pay back flash loan
        //  5. Remaining steth is profit for user
        //
        // The loan size required is determined via `previewYSell.`

        bytes memory data = abi.encode(LOAN_Y_SELL, msg.sender, strike, amount);

        uint256 before = IERC20(address(weth)).balanceOf(address(this));
        aavePool.flashLoanSimple(address(this), address(weth), loan, data, 0);
        uint256 profit = IERC20(address(weth)).balanceOf(address(this)) - before;
        require(profit >= minOut, "y sell min out");

        IERC20(address(weth)).safeTransfer(msg.sender, profit);

        emit YSell(msg.sender, strike, amount, profit, loan);

        return profit;
    }

    function _ySellViaLoan(uint256 loan,
                           uint256 fee,
                           address user,
                           uint64 strike,
                           uint256 amount) private returns (bool) {

        IERC20 token = vault.deployments(strike);
        require(address(token) != address(0), "no deployed ERC20");

        // Use loaned weth to buy hodl token
        IERC20(address(weth)).forceApprove(address(swapRouter), loan);
        ISwapRouter.ExactOutputSingleParams memory params  =
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(token),
                fee: hodlPoolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountOut: amount,
                amountInMaximum: loan,
                sqrtPriceLimitX96: 0 });
        swapRouter.exactOutputSingle(params);

        // Transfer the y token from user
        vault.yMulti().safeTransferFrom(user, address(this), strike, amount, "");

        // Merge y + hodl for steth, wrap into wsteth
        vault.merge(strike, amount);
        uint256 bal = steth.balanceOf(address(this));
        steth.forceApprove(address(wsteth), bal);
        wsteth.wrap(bal);

        // Sell wsteth for weth
        bal = IERC20(wsteth).balanceOf(address(this));
        IERC20(wsteth).forceApprove(address(swapRouter), bal);
        ISwapRouter.ExactInputSingleParams memory swapParams =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(wsteth),
                tokenOut: address(weth),
                fee: wstethWethPoolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: bal,
                amountOutMinimum: 0, // Zero since `profit >= minOut` is checked in `ySell`
                sqrtPriceLimitX96: 0 });
        swapRouter.exactInputSingle(swapParams);

        // Approve repayment using funds from sale, remainder will go to user
        IERC20(address(weth)).forceApprove(address(aavePool), loan + fee);

        return true;
    }

    function _assertMaxDiffAndTakeSmaller(uint256 a,
                                          uint256 b,
                                          uint256 maxDiff) internal pure returns (uint256) {

        (uint256 hi, uint256 lo) = (a > b) ? (a, b) : (b, a);
        uint256 diff = hi - lo;
        require(diff < maxDiff, "diff too high");
        return lo;
    }

    function executeOperation(address,
                              uint256 loan,
                              uint256 fee,
                              address initiator,
                              bytes calldata params) external payable returns (bool) {

        require(msg.sender == address(aavePool), "only aave");
        require(initiator == address(this), "only from router");

        (uint8 op,
         address user,
         uint64 strike,
         uint256 amount) = abi.decode(params, (uint8, address, uint64, uint256));

        if (op == LOAN_Y_BUY) {
            return _yBuyViaLoan(loan, fee, user, strike, amount);
        } else if (op == LOAN_Y_SELL) {
            return _ySellViaLoan(loan, fee, user, strike, amount);
        } else {
            return false;
        }
    }

    function _refundLeftoverWeth() internal {
        uint256 leftover = IERC20(address(weth)).balanceOf(address(this));
        if (leftover > REFUND_DUST_LIMIT) {
            IERC20(address(weth)).transfer(msg.sender, leftover);
        }
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public virtual returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory) public virtual returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    receive() external payable {}

    fallback() external payable {}
}
