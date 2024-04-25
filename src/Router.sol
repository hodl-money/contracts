// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/console.sol"; 

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* import { TickMath } from "@v3-core/contracts/libraries/TickMath.sol"; */

import { Vault } from  "./Vault.sol";

import { IWrappedETH } from "./interfaces/IWrappedETH.sol";
import { IWstETH } from "./interfaces/IWstETH.sol";
import { ISwapRouter } from "./interfaces/uniswap/ISwapRouter.sol";
import { IQuoterV2 } from "./interfaces/uniswap/IQuoterV2.sol";
import { IUniswapV3Factory } from "./interfaces/uniswap/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "./interfaces/uniswap/IUniswapV3Pool.sol";
import { INonfungiblePositionManager } from "../src/interfaces/uniswap/INonfungiblePositionManager.sol";
import { TickMath } from "../src/interfaces/uniswap/TickMath.sol";
import { IPool } from "../src/interfaces/aave/IPool.sol";


contract Router {
    using SafeERC20 for IERC20;

    uint8 public constant LOAN_Y_BUY = 1;
    uint8 public constant LOAN_Y_SELL = 2;
    uint24 public constant FEE = 3000;
    uint256 public constant SEARCH_TOLERANCE = 1e9;

    Vault public vault;
    IWrappedETH public weth;
    IERC20 public steth;
    IWstETH public wsteth;

    // Uniswap
    IUniswapV3Factory public uniswapV3Factory;
    ISwapRouter public swapRouter;
    IQuoterV2 public quoterV2;
    INonfungiblePositionManager public manager;

    // Aave
    IPool public aavePool;

    constructor(address vault_,
                address weth_,
                address steth_,
                address wsteth_,
                address uniswapV3Factory_,
                address swapRouter_,
                address manager_,
                address quoterV2_,
                address aavePool_) {

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

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function pool(uint64 strike) public view returns (address) {
        IERC20 hodlToken = IERC20(vault.deployments(strike));
        (address token0, address token1) = address(hodlToken) < address(weth)
            ? (address(hodlToken), address(weth))
            : (address(weth), address(hodlToken));

        return uniswapV3Factory.getPool(token0, token1, FEE);
    }

    function addLiquidity(uint64 strike, uint256 mintAmount, uint24 tick) public payable {
        IERC20 hodlToken = IERC20(vault.deployments(strike));
        require(address(hodlToken) != address(0), "no deployed ERC20");

        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint256 token0Amount;
        uint256 token1Amount;

        uint256 before = hodlToken.balanceOf(address(this));
        vault.mint{value: mintAmount}(strike);
        uint256 delta = hodlToken.balanceOf(address(this)) - before;

        uint256 wethAmount = msg.value - mintAmount;
        weth.deposit{value: wethAmount}();

        if (address(hodlToken) < address(weth)) {
            token0 = address(hodlToken);
            token1 = address(weth);
            tickLower = -int24(tick);
            tickUpper = 0;
            token0Amount = delta;
            token1Amount = wethAmount;
        } else {
            token0 = address(weth);
            token1 = address(hodlToken);
            tickLower = 0;
            tickUpper = int24(tick);
            token0Amount = wethAmount;
            token1Amount = delta;
        }

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: token0Amount,
            amount1Desired: token1Amount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: msg.sender,
            deadline: block.timestamp + 1 });

        IERC20(params.token0).approve(address(manager), token0Amount);
        IERC20(params.token1).approve(address(manager), token1Amount);

        manager.mint(params);
    }

    function previewHodlBuy(uint64 strike, uint256 amount) public returns (uint256) {
        IERC20 token = IERC20(vault.deployments(strike));
        require(address(token) != address(0), "no deployed ERC20");
        address uniPool = pool(strike);
        require(uniPool != address(0), "no uni pool");

        IQuoterV2.QuoteExactInputSingleParams memory params = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(token),
            amountIn: amount,
            fee: FEE,
            sqrtPriceLimitX96: 0 });

        (uint256 amountOut, , , ) = quoterV2.quoteExactInputSingle(params);

        return amountOut;
    }

    function hodlBuy(uint64 strike, uint256 minOut) public payable returns (uint256) {
        IERC20 token = IERC20(vault.deployments(strike));
        require(address(token) != address(0), "no deployed ERC20");
        address uniPool = pool(strike);
        require(uniPool != address(0), "no uni pool");

        weth.deposit{value: msg.value}();

        IERC20(address(weth)).approve(address(address(swapRouter)), 0);
        IERC20(address(weth)).approve(address(address(swapRouter)), msg.value);

        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(token),
                fee: FEE,
                recipient: address(this),
                deadline: block.timestamp + 1,
                amountIn: msg.value,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0 });

        uint256 out = swapRouter.exactInputSingle(params);

        return out;
    }

    function previewHodlSell(uint64 strike, uint256 amount) public returns (uint256) {
        IERC20 token = IERC20(vault.deployments(strike));
        require(address(token) != address(0), "no deployed ERC20");
        address uniPool = pool(strike);
        require(uniPool != address(0), "no uni pool");

        IQuoterV2.QuoteExactInputSingleParams memory params = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: address(token),
            tokenOut: address(weth),
            amountIn: amount,
            fee: FEE,
            sqrtPriceLimitX96: 0 });

        (uint256 out, , , ) = quoterV2.quoteExactInputSingle(params);

        return out;
    }

    function hodlSell(uint64 strike, uint256 amount, uint256 minOut) public payable returns (uint256) {
        IERC20 token = IERC20(vault.deployments(strike));
        require(address(token) != address(0), "no deployed ERC20");
        address uniPool = pool(strike);
        require(uniPool != address(0), "no uni pool");

        token.transferFrom(msg.sender, address(this), amount);

        token.approve(address(address(swapRouter)), 0);
        token.approve(address(address(swapRouter)), amount);

        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token),
                tokenOut: address(weth),
                fee: FEE,
                recipient: msg.sender,
                deadline: block.timestamp + 1,
                amountIn: amount,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0 });

        uint256 out = swapRouter.exactInputSingle(params);

        return out;
    }

    function _searchLoanSize(uint64 strike,
                             uint256 value,
                             uint256 lo,
                             uint256 hi,
                             uint256 n) private returns (uint256) {

        if (n == 0) {
            return 0;
        }

        IERC20 token = IERC20(vault.deployments(strike));
        uint256 loan = (hi + lo) / 2;
        uint256 fee = _flashLoanFee(loan);
        uint256 debt = loan + fee;

        IQuoterV2.QuoteExactInputSingleParams memory params = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: address(token),
            tokenOut: address(weth),
            amountIn: value + loan,
            fee: FEE,
            sqrtPriceLimitX96: 0 });

        (uint256 out, , , ) = quoterV2.quoteExactInputSingle(params);

        if (out > debt) {

            // Output is enough to payoff loan + fee, can take larger loan
            uint256 diff = out - debt;
            if (diff < SEARCH_TOLERANCE) {
                return loan;
            }

            return _searchLoanSize(strike, value, loan, hi, n -1);
        } else {

            // Output to small to payoff loan + fee, reduce loan size
            return _searchLoanSize(strike, value, lo, loan, n - 1);
        }
    }

    function _flashLoanFee(uint256 loan) private view returns (uint256) {
        uint256 percent = aavePool.FLASHLOAN_PREMIUM_TOTAL();
        return loan * percent / 10_000;
    }

    function previewYBuy(uint64 strike, uint256 value) public returns (uint256, uint256) {
        IERC20 token = IERC20(vault.deployments(strike));
        require(address(token) != address(0), "no deployed ERC20");
        address uniPool = pool(strike);
        require(uniPool != address(0), "no uni pool");

        uint256 loan = _searchLoanSize(strike, value, 0, 1000 * value, 64);

        // amount of y tokens output
        uint256 out = value + loan;

        return (out, loan);
    }

    function yBuy(uint64 strike, uint256 loan, uint256 minOut) public payable returns (uint256) {
        uint256 value = msg.value;
        bytes memory data = abi.encode(LOAN_Y_BUY, msg.sender, strike, value + loan, minOut);

        uint256 before = vault.yMulti().balanceOf(address(this), strike);
        aavePool.flashLoanSimple(address(this), address(weth), loan, data, 0);
        uint256 delta = vault.yMulti().balanceOf(address(this), strike) - before;
        require(delta >= minOut, "y min out");

        vault.yMulti().safeTransferFrom(address(this), msg.sender, strike, delta, "");

        return delta;
    }

    function _yBuyViaLoan(uint256 loan,
                          uint256 fee,
                          address user,
                          uint64 strike,
                          uint256 amount) private returns (bool) {

        IERC20 token = IERC20(vault.deployments(strike));
        require(address(token) != address(0), "no deployed ERC20");

        // mint hodl + y tokens
        weth.withdraw(loan);

        require(address(this).balance == amount, "expected balance == amount");
        uint256 before = token.balanceOf(address(this));
        vault.mint{value: amount}(strike);
        uint256 delta = token.balanceOf(address(this)) - before;

        // handle steth off by 1 error
        amount = _assertMaxDiffAndTakeSmaller(amount, delta, 1e6);

        // sell hodl tokens to repay debt
        token.approve(address(swapRouter), 0);
        token.approve(address(swapRouter), amount);

        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(token),
                tokenOut: address(weth),
                fee: FEE,
                recipient: address(this),
                deadline: block.timestamp + 1,
                amountIn: amount,
                amountOutMinimum: loan + fee,
                sqrtPriceLimitX96: 0 });
        swapRouter.exactInputSingle(params);

        // approve repayment
        IERC20(address(weth)).approve(address(aavePool), loan + fee);

        return true;
    }

    function previewYSell(uint64 strike, uint256 amount) public returns (uint256, uint256) {
        IERC20 token = IERC20(vault.deployments(strike));

        // The y token sale works by buying hodl tokens and merging
        // y + hodl into steth. we'll do a preview of both steps.

        // Step 1: weth -> hodl swap.
        // 
        // Here, we figure out the loan size needed to buy `amount` of
        // hodl tokens. when we have `amount` hodl tokens, we'll be able
        // to merge them with `amount` y tokens to get steth for step 2.
        //
        // The quote we're obtaining is for the weth -> hodl token swap,
        // which tells us the amount of weth we need, and therefore this
        // quote is the loan size.
        IQuoterV2.QuoteExactOutputSingleParams memory params = IQuoterV2.QuoteExactOutputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(token),
            amount: amount, // Amount means quantity hodl tokens output
            fee: FEE,
            sqrtPriceLimitX96: 0 });
        (uint256 loan, , , ) = quoterV2.quoteExactOutputSingle(params);

        // Step 2: wsteth -> weth
        // 
        // The actual sale will merge y + hodl tokens for steth, but the
        // flash loan was in weth. We'll need to convert steth -> weth
        // to repay the flash loan. The remainder after loan repayment
        // is what goes to the user.
        uint256 amountWsteth = wsteth.getWstETHByStETH(amount);
        IQuoterV2.QuoteExactInputSingleParams memory paramsWeth = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: address(wsteth),
            tokenOut: address(weth),
            amountIn: amountWsteth,
            fee: 500,
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
                   uint256 minOut) public returns (uint256) {

        bytes memory data = abi.encode(LOAN_Y_SELL, msg.sender, strike, amount);

        uint256 before = IERC20(address(weth)).balanceOf(address(this));
        aavePool.flashLoanSimple(address(this), address(weth), loan, data, 0);
        uint256 profit = IERC20(address(weth)).balanceOf(address(this)) - before;
        require(profit >= minOut, "y sell min out");

        IERC20(address(weth)).transfer(msg.sender, profit);

        return profit;
    }

    function _ySellViaLoan(uint256 loan,
                           uint256 fee,
                           address user,
                           uint64 strike,
                           uint256 amount) private returns (bool) {

        IERC20 token = IERC20(vault.deployments(strike));
        require(address(token) != address(0), "no deployed ERC20");

        // use loaned weth to buy hodl token
        IERC20(address(weth)).approve(address(swapRouter), 0);
        IERC20(address(weth)).approve(address(swapRouter), amount);
        ISwapRouter.ExactOutputSingleParams memory params  =
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(token),
                fee: FEE,
                recipient: address(this),
                deadline: block.timestamp + 1,
                amountOut: amount,
                amountInMaximum: loan,
                sqrtPriceLimitX96: 0 });
        swapRouter.exactOutputSingle(params);

        // transfer the y token from user
        vault.yMulti().safeTransferFrom(user, address(this), strike, amount, "");

        // merge y + hodl for steth, wrap into wsteth
        vault.hodlMulti().setApprovalForAll(address(vault), true);
        vault.yMulti().setApprovalForAll(address(vault), true);
        vault.merge(strike, amount);
        vault.hodlMulti().setApprovalForAll(address(vault), false);
        vault.yMulti().setApprovalForAll(address(vault), false);
        uint256 bal = steth.balanceOf(address(this));
        steth.approve(address(wsteth), bal);
        wsteth.wrap(bal);

        // sell wsteth for weth
        bal = IERC20(wsteth).balanceOf(address(this));
        wsteth.approve(address(swapRouter), bal);
        ISwapRouter.ExactInputSingleParams memory swapParams =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(wsteth),
                tokenOut: address(weth),
                fee: 500,
                recipient: address(this),
                deadline: block.timestamp + 1,
                amountIn: bal,
                amountOutMinimum: 0,  // TODO
                sqrtPriceLimitX96: 0 });
        swapRouter.exactInputSingle(swapParams);

        // approve repayment using funds from sale, remainder will go to user
        IERC20(address(weth)).approve(address(aavePool), loan + fee);

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
                              address,
                              bytes calldata params) external payable returns (bool) {

        require(msg.sender == address(aavePool), "only aave");

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

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public virtual returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory) public virtual returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    receive() external payable {}

    fallback() external payable {}
}
