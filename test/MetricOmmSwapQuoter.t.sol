// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmSwapQuoter} from "../contracts/lens/MetricOmmSwapQuoter.sol";
import {IMetricOmmSwapQuoter} from "../contracts/interfaces/IMetricOmmSwapQuoter.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";
import {WrongOutputPoolForSimpleRouter} from "./mocks/RouterPoolMocks.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";

contract MetricOmmSwapQuoterTest is SimpleRouterTestBase {
  MetricOmmSwapQuoter internal swapQuoter;

  function setUp() public override {
    super.setUp();
    swapQuoter = new MetricOmmSwapQuoter();
  }

  function test_quoteLiveExactInSingle_matchesRouterSwap() public {
    uint128 amountIn = 2_500;
    uint128 priceLimit = _priceLimit(true);

    (uint256 quotedIn, uint256 quotedOut) =
      swapQuoter.quoteLiveExactInSingle(address(pool), address(0), recipient, true, amountIn, priceLimit, hex"");

    assertEq(quotedIn, amountIn, "quoted amountIn");
    assertGt(quotedOut, 0, "quoted amountOut");

    vm.prank(swapper);
    uint256 actualOut = router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountIn: amountIn,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: priceLimit,
        extensionData: ""
      })
    );

    assertEq(quotedOut, actualOut, "quote matches swap");
  }

  function test_quoteLiveExactOutSingle_matchesRouterSwap() public {
    uint128 amountOut = 1_500;
    uint128 priceLimit = _priceLimit(true);

    (uint256 quotedIn, uint256 quotedOut) =
      swapQuoter.quoteLiveExactOutSingle(address(pool), address(0), recipient, true, amountOut, priceLimit, hex"");

    assertEq(quotedOut, amountOut, "quoted amountOut");
    assertGt(quotedIn, 0, "quoted amountIn");

    vm.prank(swapper);
    uint256 actualIn = router.exactOutputSingle(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountOut: amountOut,
        amountInMaximum: type(uint128).max,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: priceLimit,
        extensionData: ""
      })
    );

    assertEq(quotedIn, actualIn, "quote matches swap");
  }

  function test_quoteLiveExactIn_twoHop_matchesRouter() public {
    uint128 amountIn = 2_000;

    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool12);

    bytes[] memory extensionDatas = new bytes[](2);

    (uint256 quotedIn, uint256 quotedOut) = swapQuoter.quoteLiveExactIn(
      address(0),
      IMetricOmmSwapQuoter.QuoteExactInputParams({
        pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: 3, amountIn: amountIn
      })
    );

    assertEq(quotedIn, amountIn, "quoted amountIn");
    assertGt(quotedOut, 0, "quoted amountOut");

    address[] memory tokens = new address[](3);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    tokens[2] = address(token2);

    vm.prank(swapper);
    uint256 actualOut = router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 3,
        amountIn: amountIn,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline()
      })
    );

    assertEq(quotedOut, actualOut, "quote matches swap");
  }

  function test_quoteLiveExactOut_twoHop_matchesRouter() public {
    uint128 amountOut = 1_000;

    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool12);

    bytes[] memory extensionDatas = new bytes[](2);

    (uint256 quotedIn, uint256 quotedOut) = swapQuoter.quoteLiveExactOut(
      address(0),
      IMetricOmmSwapQuoter.QuoteExactOutputParams({
        pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: 3, amountOut: amountOut
      })
    );

    assertEq(quotedOut, amountOut, "quoted amountOut");
    assertGt(quotedIn, 0, "quoted amountIn");

    address[] memory tokens = new address[](3);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    tokens[2] = address(token2);

    vm.prank(swapper);
    uint256 actualIn = router.exactOutput(
      IMetricOmmSimpleRouter.ExactOutputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 3,
        amountOut: amountOut,
        amountInMaximum: 10_000,
        recipient: recipient,
        deadline: _deadline()
      })
    );

    assertEq(quotedIn, actualIn, "quote matches swap");
  }

  function test_quoteHypotheticalExactInput_twoHop_matchesRouter() public {
    uint128 amountIn = 2_000;

    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool12);

    bytes[] memory extensionDatas = new bytes[](2);

    uint128[] memory bidPrices = new uint128[](2);
    bidPrices[0] = TEST_BID_X64;
    bidPrices[1] = TEST_BID_X64;

    uint128[] memory askPrices = new uint128[](2);
    askPrices[0] = TEST_ASK_X64;
    askPrices[1] = TEST_ASK_X64;

    uint128[] memory refPrices = new uint128[](2);
    refPrices[0] = TEST_BID_X64; // bid≈ask so any in-range ref works; use bid
    refPrices[1] = TEST_BID_X64;

    (uint256 quotedIn, uint256 quotedOut) = swapQuoter.quoteHypotheticalExactInput(
      address(0),
      IMetricOmmSwapQuoter.QuoteHypotheticalExactInputParams({
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 3,
        amountIn: amountIn,
        bidPricesX64: bidPrices,
        askPricesX64: askPrices,
        referencePricesX64: refPrices
      })
    );

    assertEq(quotedIn, amountIn, "quoted amountIn");
    assertGt(quotedOut, 0, "quoted amountOut");

    address[] memory tokens = new address[](3);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    tokens[2] = address(token2);

    vm.prank(swapper);
    uint256 actualOut = router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 3,
        amountIn: amountIn,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline()
      })
    );

    assertEq(quotedOut, actualOut, "quote matches swap");
  }

  function test_quoteLiveExactIn_revertsInvalidPath_disconnectedPools() public {
    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool);

    bytes[] memory extensionDatas = new bytes[](2);

    vm.expectRevert(IMetricOmmSwapQuoter.InvalidPath.selector);
    swapQuoter.quoteLiveExactIn(
      address(0),
      IMetricOmmSwapQuoter.QuoteExactInputParams({
        pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: 3, amountIn: 2000
      })
    );
  }

  function test_quoteLiveExactIn_revertsInvalidInputAmountAtHop() public {
    WrongOutputPoolForSimpleRouter wrongPool =
      new WrongOutputPoolForSimpleRouter(address(weth), address(token1), address(oracle), 400, -300);

    address[] memory pools = new address[](2);
    pools[0] = address(wrongPool);
    pools[1] = address(pool12);

    bytes[] memory extensionDatas = new bytes[](2);

    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmSwapQuoter.InvalidInputAmountAtHop.selector, uint8(0), uint256(400), uint256(2000)
      )
    );
    swapQuoter.quoteLiveExactIn(
      address(0),
      IMetricOmmSwapQuoter.QuoteExactInputParams({
        pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: 3, amountIn: 2000
      })
    );
  }

  function test_quoteLiveExactOut_revertsInvalidOutputAmountAtHop() public {
    WrongOutputPoolForSimpleRouter wrongPool =
      new WrongOutputPoolForSimpleRouter(address(token1), address(token2), address(oracle), 600, -400);

    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(wrongPool);

    bytes[] memory extensionDatas = new bytes[](2);

    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmSwapQuoter.InvalidOutputAmountAtHop.selector, uint8(1), uint256(400), uint256(500)
      )
    );
    swapQuoter.quoteLiveExactOut(
      address(0),
      IMetricOmmSwapQuoter.QuoteExactOutputParams({
        pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: 3, amountOut: 500
      })
    );
  }

  // ============ Paused pools ============

  function test_quoteLiveExactInSingle_revertsWhenPoolPaused() public {
    _setPause(pool, 1);

    vm.expectRevert(abi.encodeWithSelector(IMetricOmmSwapQuoter.PoolPaused.selector, address(pool), uint8(1)));
    swapQuoter.quoteLiveExactInSingle(address(pool), address(0), recipient, true, 2_500, _priceLimit(true), hex"");
  }

  function test_quoteLiveExactOutSingle_revertsWhenPoolProtocolPaused() public {
    _setPause(pool, 2);

    vm.expectRevert(abi.encodeWithSelector(IMetricOmmSwapQuoter.PoolPaused.selector, address(pool), uint8(2)));
    swapQuoter.quoteLiveExactOutSingle(address(pool), address(0), recipient, true, 1_500, _priceLimit(true), hex"");
  }

  function test_quoteLiveExactIn_revertsWhenLaterHopPaused() public {
    _setPause(pool12, 1);

    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool12);

    vm.expectRevert(abi.encodeWithSelector(IMetricOmmSwapQuoter.PoolPaused.selector, address(pool12), uint8(1)));
    swapQuoter.quoteLiveExactIn(
      address(0),
      IMetricOmmSwapQuoter.QuoteExactInputParams({
        pools: pools, extensionDatas: new bytes[](2), zeroForOneBitMap: 3, amountIn: 2_000
      })
    );
  }

  function test_quoteLiveExactOut_revertsWhenFirstHopPaused() public {
    _setPause(pool, 1);

    address[] memory pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool12);

    vm.expectRevert(abi.encodeWithSelector(IMetricOmmSwapQuoter.PoolPaused.selector, address(pool), uint8(1)));
    swapQuoter.quoteLiveExactOut(
      address(0),
      IMetricOmmSwapQuoter.QuoteExactOutputParams({
        pools: pools, extensionDatas: new bytes[](2), zeroForOneBitMap: 3, amountOut: 1_000
      })
    );
  }

  function test_quoteHypotheticalExactInputSingle_ignoresPause() public {
    (, uint256 activeOut) = swapQuoter.quoteHypotheticalExactInputSingle(
      address(pool), address(0), true, 2_500, _priceLimit(true), TEST_BID_X64, TEST_ASK_X64, TEST_BID_X64
    );

    _setPause(pool, 1);

    (, uint256 pausedOut) = swapQuoter.quoteHypotheticalExactInputSingle(
      address(pool), address(0), true, 2_500, _priceLimit(true), TEST_BID_X64, TEST_ASK_X64, TEST_BID_X64
    );
    assertGt(pausedOut, 0, "paused hypothetical out");
    assertEq(pausedOut, activeOut, "pause does not change hypothetical quote");
  }

  function test_quoteLiveExactInSingle_succeedsAfterUnpause() public {
    (, uint256 activeOut) =
      swapQuoter.quoteLiveExactInSingle(address(pool), address(0), recipient, true, 2_500, _priceLimit(true), hex"");

    _setPause(pool, 1);
    _setPause(pool, 0);

    (, uint256 resumedOut) =
      swapQuoter.quoteLiveExactInSingle(address(pool), address(0), recipient, true, 2_500, _priceLimit(true), hex"");
    assertEq(resumedOut, activeOut, "quote restored after unpause");
  }

  function _setPause(MetricOmmPool target, uint8 level) internal {
    vm.prank(address(factoryStub));
    target.setPause(level);
  }
}
