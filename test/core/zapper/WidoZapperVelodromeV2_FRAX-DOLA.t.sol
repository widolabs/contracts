// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.7;

import "forge-std/Test.sol";
import "forge-std/StdUtils.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../../shared/OptimismForkTest.sol";
import "../../../contracts/core/zapper/WidoZapperVelodromeV2.sol";

contract WidoZapperVelodromeV2Test is OptimismForkTest {
    using SafeMath for uint256;

    WidoZapperVelodromeV2 zapper;

    address constant VELO_V2_ROUTER = address(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);
    address constant DOLA_FRAX_LP = address(0x1f8b46abe1EAbF5A60CbBB5Fb2e4a6A46fA0b6e6);
    address constant DOLA = address(0x8aE125E8653821E851F12A49F7765db9a9ce7384);
    address constant FRAX = address(0x2E3D870790dC77A83DD1d18184Acc7439A53f475);

    function setUp() public {
        setUpBase();

        zapper = new WidoZapperVelodromeV2();
        vm.label(address(zapper), "Zapper");

        vm.label(VELO_V2_ROUTER, "VELO_V2_ROUTER");
        vm.label(DOLA_FRAX_LP, "DOLA_FRAX_LP");
        vm.label(DOLA, "DOLA");
    }

    function test_zapFRAXForLP() public {
        /** Arrange */

        uint256 amount = 5e18;
        address fromAsset = FRAX;
        address toAsset = DOLA_FRAX_LP;

        /** Act */

        uint256 minToToken = _zapIn(zapper, fromAsset, amount);

        /** Assert */

        uint256 finalFromBalance = IERC20(fromAsset).balanceOf(user1);
        uint256 finalToBalance = IERC20(toAsset).balanceOf(user1);

        assertLe(IERC20(DOLA).balanceOf(address(zapper)), 0, "Dust");
        assertLe(IERC20(FRAX).balanceOf(address(zapper)), 2, "Dust");

        assertLt(finalFromBalance, amount, "From balance incorrect");
        assertGe(finalToBalance, minToToken, "To balance incorrect");
    }

    function test_zapDOLAForLP() public {
        /** Arrange */

        uint256 amount = 8e18;
        address fromAsset = DOLA;
        address toAsset = DOLA_FRAX_LP;

        /** Act */

        uint256 minToToken = _zapIn(zapper, fromAsset, amount);

        /** Assert */

        uint256 finalFromBalance = IERC20(fromAsset).balanceOf(user1);
        uint256 finalToBalance = IERC20(toAsset).balanceOf(user1);

        assertLe(IERC20(DOLA).balanceOf(address(zapper)), 2, "Dust");
        assertLe(IERC20(FRAX).balanceOf(address(zapper)), 0, "Dust");

        assertEq(finalFromBalance, 0, "From balance incorrect");
        assertGe(finalToBalance, minToToken, "To balance incorrect");
    }

    function test_zapLPForFRAX() public {
        /** Arrange */

        _zapIn(zapper, FRAX, 50e18);

        address fromAsset = DOLA_FRAX_LP;
        address toAsset = FRAX;
        uint256 amount = IERC20(fromAsset).balanceOf(user1);

        /** Act */

        uint256 minToToken = _zapOut(zapper, fromAsset, toAsset, amount);

        /** Assert */

        uint256 finalFromBalance = IERC20(fromAsset).balanceOf(user1);
        uint256 finalToBalance = IERC20(toAsset).balanceOf(user1);

        assertLe(IERC20(DOLA).balanceOf(address(zapper)), 0, "Dust");
        assertLe(IERC20(FRAX).balanceOf(address(zapper)), 2, "Dust");

        assertEq(finalFromBalance, 0, "From balance incorrect");
        assertGe(finalToBalance, minToToken, "To balance incorrect");
    }

    function test_zapLPForDOLA() public {
        /** Arrange */

        _zapIn(zapper, DOLA, 10e18);

        address fromAsset = DOLA_FRAX_LP;
        address toAsset = DOLA;
        uint256 amount = IERC20(fromAsset).balanceOf(user1);

        /** Act */

        uint256 minToToken = _zapOut(zapper, fromAsset, toAsset, amount);

        /** Assert */

        uint256 finalFromBalance = IERC20(fromAsset).balanceOf(user1);
        uint256 finalToBalance = IERC20(toAsset).balanceOf(user1);

        assertLe(IERC20(DOLA).balanceOf(address(zapper)), 2, "Dust");
        assertLe(IERC20(FRAX).balanceOf(address(zapper)), 0, "Dust");

        assertEq(finalFromBalance, 0, "From balance incorrect");
        assertGe(finalToBalance, minToToken, "To balance incorrect");
    }

    function test_revertWhen_zapDOLAForLP_HasHighSlippage() public {
        /** Arrange */

        uint256 amount = 200_000;
        address fromAsset = DOLA;
        deal(fromAsset, user1, amount);

        uint256 minToToken = zapper.calcMinToAmountForZapIn(
            IUniswapV2Router02(VELO_V2_ROUTER),
            IUniswapV2Pair(DOLA_FRAX_LP),
            fromAsset,
            amount,
            abi.encode(true)
        )
        .mul(1001)
        .div(1000);

        vm.startPrank(user1);

        IERC20(fromAsset).approve(address(zapper), amount);

        /** Act & Assert */

        vm.expectRevert();

        zapper.zapIn(
            IUniswapV2Router02(VELO_V2_ROUTER),
            IUniswapV2Pair(DOLA_FRAX_LP),
            fromAsset,
            user1,
            amount,
            minToToken,
            abi.encode(true)
        );
    }

    function test_revertWhen_zapDOLAForLP_NoApproval() public {
        /** Arrange */

        uint256 amount = 200_000;
        address fromAsset = DOLA;
        deal(fromAsset, user1, amount);

        uint256 minToToken = zapper.calcMinToAmountForZapIn(
            IUniswapV2Router02(VELO_V2_ROUTER),
            IUniswapV2Pair(DOLA_FRAX_LP),
            fromAsset,
            amount,
            abi.encode(true)
        )
        .mul(998)
        .div(1000);

        vm.startPrank(user1);

        /** Act & Assert */

        vm.expectRevert();

        zapper.zapIn(
            IUniswapV2Router02(VELO_V2_ROUTER),
            IUniswapV2Pair(DOLA_FRAX_LP),
            fromAsset,
            user1,
            amount,
            minToToken,
            abi.encode(true)
        );
    }

    function test_revertWhen_zapLPForDOLA_NoBalance() public {
        /** Arrange */

        address fromAsset = DOLA_FRAX_LP;
        address toAsset = DOLA;
        uint256 amount = 1 ether;

        uint256 minToToken = zapper.calcMinToAmountForZapOut(
            IUniswapV2Router02(VELO_V2_ROUTER),
            IUniswapV2Pair(DOLA_FRAX_LP),
            toAsset,
            amount,
            abi.encode(true)
        )
        .mul(998)
        .div(1000);

        vm.startPrank(user1);

        IERC20(fromAsset).approve(address(zapper), amount);

        /** Act & Assert */

        vm.expectRevert();

        zapper.zapOut(
            IUniswapV2Router02(VELO_V2_ROUTER),
            IUniswapV2Pair(DOLA_FRAX_LP),
            amount,
            toAsset,
            minToToken,
            abi.encode(true)
        );
    }

    function _zapIn(
        WidoZapperUniswapV2 _zapper,
        address _fromAsset,
        uint256 _amountIn
    ) internal returns (uint256 minToToken){
        deal(_fromAsset, user1, _amountIn);
        vm.startPrank(user1);

        minToToken = _zapper.calcMinToAmountForZapIn(
            IUniswapV2Router02(VELO_V2_ROUTER),
            IUniswapV2Pair(DOLA_FRAX_LP),
            _fromAsset,
            _amountIn,
            abi.encode(true)
        )
        .mul(995)
        .div(1000);

        IERC20(_fromAsset).approve(address(_zapper), _amountIn);
        _zapper.zapIn(
            IUniswapV2Router02(VELO_V2_ROUTER),
            IUniswapV2Pair(DOLA_FRAX_LP),
            _fromAsset,
            user1,
            _amountIn,
            minToToken,
            abi.encode(true)
        );
    }

    function _zapOut(
        WidoZapperUniswapV2 _zapper,
        address _fromAsset,
        address _toAsset,
        uint256 _amountIn
    ) internal returns (uint256 minToToken){
        minToToken = _zapper.calcMinToAmountForZapOut(
            IUniswapV2Router02(VELO_V2_ROUTER),
            IUniswapV2Pair(DOLA_FRAX_LP),
            _toAsset,
            _amountIn,
            abi.encode(true)
        )
        .mul(998)
        .div(1000);

        IERC20(_fromAsset).approve(address(_zapper), _amountIn);
        _zapper.zapOut(
            IUniswapV2Router02(VELO_V2_ROUTER),
            IUniswapV2Pair(DOLA_FRAX_LP),
            _amountIn,
            _toAsset,
            minToToken,
            abi.encode(true)
        );
    }
}
