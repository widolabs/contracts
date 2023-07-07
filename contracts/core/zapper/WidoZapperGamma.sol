// SPDX-License-Identifier: GPLv2

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.

pragma solidity ^0.8.7;

import "./WidoZapper.sol";
import "@cryptoalgebra/periphery/contracts/interfaces/ISwapRouter.sol";
import "@cryptoalgebra/core/contracts/libraries/TickMath.sol";
import "@cryptoalgebra/periphery/contracts/libraries/LiquidityAmounts.sol";
import "@cryptoalgebra/core/contracts/interfaces/IAlgebraPool.sol";
import "forge-std/Test.sol";

interface Hypervisor {
    function whitelistedAddress() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function pool() external pure returns (address);

    function currentTick() external pure returns (int24);

    function baseLower() external pure returns (int24);

    function baseUpper() external pure returns (int24);
}

interface UniProxy {
    function deposit(uint256 deposit0, uint256 deposit1, address to, address pos, uint256[4] memory minIn) external returns (uint256);

    function getDepositAmount(
        address pos,
        address token,
        uint256 _deposit
    ) external view returns (uint256 amountStart, uint256 amountEnd);
}

/// @title Gamma pools Zapper
/// @notice Add or remove liquidity from Gamma pools using just one of the pool tokens
contract WidoZapperGamma is WidoZapper {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for uint160;
    using SafeERC20 for IERC20;

    /// @dev there's a point at which the gas cost doesn't compensate the dust value
    uint256 immutable public DUST_THRESHOLD = 1e10;

    struct Order {
        address tokenA;
        address tokenB;
        uint256 amountADesired;
        uint256 amountBDesired;
        bytes extra;
    }

    /// @inheritdoc WidoZapper
    function calcMinToAmountForZapIn(
        IUniswapV2Router02, //router,
        IUniswapV2Pair pair,
        address fromToken,
        uint256 amount,
        bytes calldata //extra
    ) external view virtual override returns (uint256 minToToken) {
        IAlgebraPool pool = IAlgebraPool(Hypervisor(address(pair)).pool());
        bool isZapFromToken0 = pool.token0() == fromToken;
        (uint160 sqrtPriceX96,,,,,,) = pool.globalState();

        (uint256 amount0, uint256 amount1) = _balancedAmounts(address(pair), sqrtPriceX96, amount, isZapFromToken0);

        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(Hypervisor(address(pair)).baseLower());
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(Hypervisor(address(pair)).baseUpper());

        minToToken = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            amount0,
            amount1
        );
    }

    /// @inheritdoc WidoZapper
    function calcMinToAmountForZapOut(
        IUniswapV2Router02, // router,
        IUniswapV2Pair pair,
        address toToken,
        uint256 amount,
        bytes calldata //extra
    ) external view virtual override returns (uint256 minToToken) {
        IAlgebraPool pool = IAlgebraPool(Hypervisor(address(pair)).pool());

        bool isZapToToken0 = pool.token0() == toToken;
        require(isZapToToken0 || pool.token1() == toToken, "Output token not present in liquidity pool");

        (uint160 sqrtPriceX96,,,,,,) = pool.globalState();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(Hypervisor(address(pair)).baseLower());
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(Hypervisor(address(pair)).baseUpper());

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            uint128(amount)
        );
        uint256 token0Price = FullMath.mulDiv(sqrtPriceX96 * 1e18, sqrtPriceX96, 2 ** 192);

        if (isZapToToken0) {
            minToToken = amount0 + (amount1 * 1e18) / token0Price;
        } else {
            minToToken = amount1 + (amount0 * token0Price) / 1e18;
        }
    }

    /// @inheritdoc WidoZapper
    function _swapAndAddLiquidity(
        IUniswapV2Router02, //router,
        IUniswapV2Pair pair,
        address tokenA,
        bytes memory extra
    ) internal override returns (uint256 liquidity) {
        IAlgebraPool pool = IAlgebraPool(Hypervisor(address(pair)).pool());
        (uint160 sqrtPriceX96,,,,,,) = pool.globalState();
        uint256 amount = IERC20(tokenA).balanceOf(address(this));
        bool fromToken0 = pool.token0() == tokenA;
        address tokenB = fromToken0 ? pool.token1() : pool.token0();

        Order memory order = Order(
            tokenA,
            tokenB,
            0, // will be filled in _deposit
            0, // will be filled in _deposit
            extra
        );

        liquidity = _deposit(address(pair), sqrtPriceX96, order, amount, fromToken0);

        liquidity = liquidity + _liquidateDust(pair, order, sqrtPriceX96);
    }

    /// @inheritdoc WidoZapper
    function _removeLiquidityAndSwap(
        IUniswapV2Router02, //router,
        IUniswapV2Pair pair,
        address toToken,
        bytes memory extra
    ) internal virtual override returns (uint256) {
        address token0 = pair.token0();
        address token1 = pair.token1();
        require(token0 == toToken || token1 == toToken, "Desired token not present in liquidity pair");

        IERC20(address(pair)).safeTransfer(
            address(pair),
            IERC20(address(pair)).balanceOf(address(this))
        );
        pair.burn(address(this));

        address fromToken = token1 == toToken
        ? token0
        : token1;

        (address swapRouter,) = abi.decode(extra, (address, uint256[4]));

        _swap(
            swapRouter,
            IERC20(fromToken).balanceOf(address(this)),
            fromToken,
            toToken
        );

        return IERC20(toToken).balanceOf(address(this));
    }

    /// @notice Computes `amount0` and `amount1` that equal to the `amount` of the given token
    function _balancedAmounts(
        address pool,
        uint160 sqrtPriceX96,
        uint256 amount,
        bool isZapFromToken0
    )
    private view
    returns (
        uint256 amount0,
        uint256 amount1
    ) {
        if (isZapFromToken0) {
            amount0 = amount;
            amount1 = _getPairAmount(pool, Hypervisor(pool).token0(), amount);
        }
        else {
            amount1 = amount;
            amount0 = _getPairAmount(pool, Hypervisor(pool).token1(), amount);
        }

        uint256 token0Price = FullMath.mulDiv(uint256(sqrtPriceX96).mul(uint256(sqrtPriceX96)), 1e18, 2 ** (96 * 2));

        uint256 optimalRatio;
        if (amount0 == 0) {
            optimalRatio = amount * token0Price;
        } else {
            optimalRatio = (amount1 * 1e18) / amount0;
        }

        if (isZapFromToken0) {
            amount0 = (amount * token0Price) / (optimalRatio + token0Price);
            amount1 = ((amount - amount0) * token0Price) / 1e18;
        } else {
            amount0 = (amount * 1e18) / (optimalRatio + token0Price);
            if (optimalRatio == 0) {
                amount1 = 0;
            } else {
                amount1 = amount - ((amount0 * token0Price) / 1e18);
            }
        }
    }

    /// @notice Re-balances `amount` of the input token, and deposits into the pool
    /// @param pool Address of the Hypervisor vault
    /// @param sqrtPriceX96 Current sqrtPrice
    /// @param order Order struct with the details of the deposit order
    /// @param amount Input amount of the token
    /// @param fromToken0 Indicates if the amount is of token0 or not
    /// @return liquidity Amount of added liquidity into the vault
    function _deposit(
        address pool,
        uint160 sqrtPriceX96,
        Order memory order,
        uint256 amount,
        bool fromToken0
    )
    private
    returns (uint256 liquidity) {

        // first we compute the ideal token balances that we should try to deposit,
        //  given the value of our input assets

        // obtain `amount0` and `amount1` that equal to `amount` of the given token
        (uint256 amountA, uint256 amountB) = _balancedAmounts(
            pool,
            sqrtPriceX96,
            amount,
            fromToken0
        );

        // now we know how much of each token we need, so we can sell the difference
        //  on what we have.
        // The swap is not always going to be exact, so afterwards we check how much
        //  token we received, and from that compute the pair amount in ratio.

        (address swapRouter,) = abi.decode(order.extra, (address, uint256[4]));

        if (fromToken0) {
            // swap excess amount of input token for the pair token
            _swap(
                swapRouter,
                amount - amountA,
                order.tokenA,
                order.tokenB
            );
            // get real amount of tokenB
            amountB = IERC20(order.tokenB).balanceOf(address(this));
            // get balanced amountA for the amount of tokenB we got
            amountA = _getPairAmount(pool, order.tokenB, amountB);
        }
        else {
            // swap excess amount of input token for the pair token
            _swap(
                swapRouter,
                amount - amountB,
                order.tokenB,
                order.tokenA
            );
            // get real amount of tokenA
            amountA = IERC20(order.tokenA).balanceOf(address(this));
            // get balanced amountB for the amount of tokenB we got
            amountB = _getPairAmount(pool, order.tokenA, amountA);
        }

        // pegging the amounts like this will generally leave some dust
        //  so we'll have to run this function more than once

        // override order amounts
        order.amountADesired = amountA;
        order.amountBDesired = amountB;

        // deposit liquidity into the pool

        (, uint256[4] memory inMin) = abi.decode(order.extra, (address, uint256[4]));

        _approveTokenIfNeeded(order.tokenA, pool, order.amountADesired);
        _approveTokenIfNeeded(order.tokenB, pool, order.amountBDesired);

        liquidity = UniProxy(
            Hypervisor(pool).whitelistedAddress()
        ).deposit(
            order.amountADesired,
            order.amountBDesired,
            msg.sender,
            pool,
            inMin
        );
    }

    /// @notice Computes the amount of the opposite asset that should be deposited to be a balanced deposit
    /// @param pool Address of the Hypervisor vault
    /// @param token Token address of the specified amount
    /// @param amount Amount of assets we know we want to input
    /// @return pairAmount Amount of the opposite token that needs to balance the position
    function _getPairAmount(address pool, address token, uint256 amount) private view returns (uint256 pairAmount) {
        (uint256 start, uint256 end) = UniProxy(
            Hypervisor(pool).whitelistedAddress()
        ).getDepositAmount(
            pool,
            token,
            amount
        );
        pairAmount = start + ((end - start) / 2);
    }

    /// @dev This will iterate and deposit remaining amount of any token
    function _liquidateDust(
        IUniswapV2Pair pair,
        Order memory order,
        uint160 sqrtPriceX96
    )
    internal
    returns (uint256 liquidity) {
        // check token0 dust
        uint256 dustBalance = IERC20(order.tokenA).balanceOf(address(this));
        while (dustBalance > DUST_THRESHOLD) {
            // re-balance and deposit
            liquidity = liquidity + _deposit(address(pair), sqrtPriceX96, order, dustBalance, true);
            // check remaining dust
            dustBalance = IERC20(order.tokenA).balanceOf(address(this));
        }

        // check token1 dust
        dustBalance = IERC20(order.tokenB).balanceOf(address(this));
        while (dustBalance > DUST_THRESHOLD) {
            // re-balance and deposit
            liquidity = liquidity + _deposit(address(pair), sqrtPriceX96, order, dustBalance, false);
            // check remaining dust
            dustBalance = IERC20(order.tokenB).balanceOf(address(this));
        }
    }

    /// @dev This function swap amountIn through the path
    function _swap(
        address router,
        uint256 amountIn,
        address tokenIn,
        address tokenOut
    )
    internal virtual
    returns (uint256 amountOut) {
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn : tokenIn,
            tokenOut : tokenOut,
            recipient : address(this),
            deadline : block.timestamp,
            amountIn : amountIn,
            amountOutMinimum : 0,
            limitSqrtPrice : 0
        });

        _approveTokenIfNeeded(tokenIn, router, amountIn);
        amountOut = ISwapRouter(router).exactInputSingle(params);
    }
}
