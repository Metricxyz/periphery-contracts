// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)

import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {IPriceProvider} from "@metric-core/interfaces/IPriceProvider/IPriceProvider.sol";
import {PoolExtensions, ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {PoolFeeConfig} from "@metric-core/types/FactoryStorage.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {ExtensionOrderTestLib} from "@metric-core-test/ExtensionOrderTestLib.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {LiquidityLadder} from "../contracts/libraries/LiquidityLadder.sol";
import {LiquidityLadderBinWalk} from "./helpers/LiquidityLadderBinWalk.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";
import {CapExtension} from "./mocks/extensions/CapExtension.sol";

/// @notice Runs the current `LiquidityLadder` (whole side first, then a binary search over funded bins).
contract SideFirstLadderLens {
  address internal immutable FACTORY;

  constructor(address factory) {
    FACTORY = factory;
  }

  function depth(address pool, uint8 maxBinsPerSide, uint128 bid, uint128 ask, uint128 ref)
    external
    returns (LiquidityLadder.LiquidityDepth memory)
  {
    return LiquidityLadder.build(pool, FACTORY, maxBinsPerSide, bid, ask, ref);
  }
}

/// @notice Runs the frozen bin-by-bin walk the current library replaced.
contract BinWalkLadderLens {
  address internal immutable FACTORY;

  constructor(address factory) {
    FACTORY = factory;
  }

  function depth(address pool, uint8 maxBinsPerSide, uint128 bid, uint128 ask, uint128 ref)
    external
    returns (LiquidityLadderBinWalk.LiquidityDepth memory)
  {
    return LiquidityLadderBinWalk.build(pool, FACTORY, maxBinsPerSide, bid, ask, ref);
  }
}

/// @title Whole-side-first ladder parity with the bin-by-bin walk
/// @notice For pools whose extensions refuse monotonically in trade size (here `CapExtension`, on the requested
///         amount or on the actual output), the side-first ladder must return the same rows as the bin-by-bin walk:
///         same length, bins, bounds, available, tradeable and cumulative output on every row, and the same
///         cumulative input wherever it reports one. It reports none (zero) only on a fully tradeable row before the
///         side's last simulated one.
contract MetricOmmPoolDataProviderDepthSideFirstParityTest is SimpleRouterTestBase {
  SideFirstLadderLens internal sideFirst;
  BinWalkLadderLens internal binWalk;
  CapExtension internal capExtension;
  MetricOmmPool internal cappedPool;

  function setUp() public override {
    super.setUp();
    sideFirst = new SideFirstLadderLens(address(factoryStub));
    binWalk = new BinWalkLadderLens(address(factoryStub));
    capExtension = new CapExtension();
    cappedPool = _deployCappedPool();
    _seedLiquidityPool(cappedPool, address(weth), address(token1), 2);
    lpContract.addLiquidityRange(address(cappedPool), 3, -4, 4, 1e12);
  }

  function testFuzz_matchesBinWalk(
    uint8 maxBinsPerSide,
    bool preSwapZeroForOne,
    uint256 preSwapBps,
    uint8 capKind,
    bool capBids,
    uint256 capBps
  ) public {
    maxBinsPerSide = uint8(bound(maxBinsPerSide, 1, 10));
    preSwapBps = bound(preSwapBps, 0, 9_000);
    capKind = uint8(bound(capKind, 0, 2));
    capBps = bound(capBps, 1, 10_500);

    LiquidityLadder.LiquidityDepth memory uncapped = _sideFirst(maxBinsPerSide);
    LiquidityLadder.DepthLevel[] memory preSide = preSwapZeroForOne ? uncapped.bids : uncapped.asks;
    if (preSwapBps > 0 && preSide.length > 0 && preSide[0].amountAvailableInBin > 0) {
      _swapExactOutput(preSwapZeroForOne, preSide[0].amountAvailableInBin * preSwapBps / 10_000);
    }

    // A cap as a share of the capped side's whole output: under 100% it lands inside some funded bin (or the
    // first one), over 100% it refuses nothing.
    LiquidityLadder.LiquidityDepth memory beforeCap = _sideFirst(maxBinsPerSide);
    LiquidityLadder.DepthLevel[] memory capped = capBids ? beforeCap.bids : beforeCap.asks;
    uint256 sideOut = capped.length == 0 ? 0 : capped[capped.length - 1].cumulativeOut;
    uint256 cap = sideOut * capBps / 10_000;
    if (capKind == 1) capExtension.setCap(cap);
    if (capKind == 2) capExtension.setOutputCap(cap);

    _assertSameLadder(maxBinsPerSide);
  }

  /// @notice A cap exactly at a funded bin boundary: the bin before it fills in full and the next one is refused
  ///         outright, the case where the binary search's last good prefix and the stop row meet.
  function test_capAtBinBoundary_matchesBinWalk() public {
    LiquidityLadder.LiquidityDepth memory uncapped = _sideFirst(6);
    assertGt(uncapped.asks.length, 2, "need at least three ask rows");
    capExtension.setOutputCap(uncapped.asks[1].cumulativeOut);
    _assertSameLadder(6);

    LiquidityLadder.LiquidityDepth memory capped = _sideFirst(6);
    LiquidityLadder.DepthLevel memory stop = capped.asks[capped.asks.length - 1];
    assertEq(stop.amountTradeableInBin, 0, "the bin past the cap trades nothing");
  }

  /// @notice An unrefused side is resolved by two simulations, its first funded row and the whole side: only those
  ///         two rows report a cumulative input, and trading the whole side's output costs exactly that input.
  function test_unrefusedSide_reportsTheWholeSideFromTwoSimulations() public {
    LiquidityLadder.LiquidityDepth memory depth = _sideFirst(6);
    LiquidityLadder.DepthLevel[] memory asks = depth.asks;
    uint256 lastFunded = type(uint256).max;
    for (uint256 i; i < asks.length; i++) {
      assertEq(asks[i].amountTradeableInBin, asks[i].amountAvailableInBin, "nothing is refused");
      if (asks[i].amountAvailableInBin > 0) lastFunded = i;
    }
    assertLt(lastFunded, asks.length, "need a funded ask row");
    uint256 firstFunded;
    while (asks[firstFunded].amountAvailableInBin == 0) firstFunded++;
    assertLt(firstFunded, lastFunded, "need two funded ask rows");
    assertGt(asks[firstFunded].cumulativeIn, 0, "the first funded row is simulated on its own");
    for (uint256 i = firstFunded + 1; i < lastFunded; i++) {
      if (asks[i].amountAvailableInBin > 0) assertEq(asks[i].cumulativeIn, 0, "rows in between are not simulated");
    }
    uint256 cost = _swapExactOutput(false, asks[lastFunded].cumulativeOut);
    assertEq(cost, asks[lastFunded].cumulativeIn, "the whole-side simulation's input is executable");
  }

  /// @notice A bin whose bounds cannot be priced (its cumulative distance is below -1e6) past the row a side stops
  ///         at must not revert the ladder: the bin-by-bin walk never reached it, so neither may the side-first one.
  function test_unpriceableBinPastTheStop_doesNotRevert() public {
    (uint256[] memory nn,) = _binPackedArrays();
    MetricOmmPool deep = _deployCappedPoolFrom(nn, _deepNegativeBinPackedArrays());
    _seedLiquidityPool(deep, address(weth), address(token1), 4);
    (uint128 bid, uint128 ask, uint128 ref) = IPriceProvider(address(oracle)).getQuote();

    // Unrefused, the bid side keeps every row down to the cap and has to price the far bins: both ladders revert.
    vm.expectRevert(LiquidityLadder.InvalidDistance.selector);
    sideFirst.depth(address(deep), 20, bid, ask, ref);
    vm.expectRevert(LiquidityLadderBinWalk.InvalidDistance.selector);
    binWalk.depth(address(deep), 20, bid, ask, ref);

    // Refused at the first funded bin, the side stops there and the far bins are never priced.
    capExtension.setCap(1);
    _assertSameLadder(address(deep), 20);
    assertLe(sideFirst.depth(address(deep), 20, bid, ask, ref).bids.length, 5, "bids stop inside the funded bins");
  }

  /// @notice A side refused at its first funded bin reads no bin state past that bin, as the bin-by-bin walk.
  function test_refusedAtFirstFundedBin_readsNoFurtherBins() public {
    MetricOmmPool wide = _deployCappedPoolFrom(_widePackedArrays(), _widePackedArrays());
    _seedLiquidityPool(wide, address(weth), address(token1), 5);
    lpContract.addLiquidityRange(address(wide), 6, -32, 32, 1e12);
    capExtension.setCap(1);
    (uint128 bid, uint128 ask, uint128 ref) = IPriceProvider(address(oracle)).getQuote();

    vm.record();
    LiquidityLadder.LiquidityDepth memory got = sideFirst.depth(address(wide), 32, bid, ask, ref);
    (bytes32[] memory reads,) = vm.accesses(address(wide));

    int16 lowestRead = got.bids[got.bids.length - 1].binIdx;
    int16 highestRead = got.asks[got.asks.length - 1].binIdx;
    assertLe(got.asks.length, 2, "asks stop at the first funded bin");
    assertLe(got.bids.length, 2, "bids stop at the first funded bin");
    for (int16 bin = -32; bin <= 32; bin++) {
      if (bin >= lowestRead && bin <= highestRead) continue;
      bytes32 slot = PoolStateLibrary._calculateBinStateSlot(bin);
      for (uint256 i; i < reads.length; i++) {
        assertTrue(reads[i] != slot, "read a bin past the stop");
      }
    }
    _assertSameLadder(address(wide), 32);
  }

  /// @notice Parity at oracle_api's depth (32 bins per side over 33 funded bins), refused at assorted rows, so the
  ///         binary search runs several steps.
  function testFuzz_wideSide_matchesBinWalk(uint256 stopRow, bool capBids, bool outputCap) public {
    MetricOmmPool wide = _deployCappedPoolFrom(_widePackedArrays(), _widePackedArrays());
    _seedLiquidityPool(wide, address(weth), address(token1), 5);
    lpContract.addLiquidityRange(address(wide), 6, -32, 32, 1e12);
    (uint128 bid, uint128 ask, uint128 ref) = IPriceProvider(address(oracle)).getQuote();
    LiquidityLadder.LiquidityDepth memory uncapped = sideFirst.depth(address(wide), 32, bid, ask, ref);
    LiquidityLadder.DepthLevel[] memory side = capBids ? uncapped.bids : uncapped.asks;
    stopRow = bound(stopRow, 0, side.length - 1);
    uint256 cap = side[stopRow].cumulativeOut + 1;
    if (outputCap) capExtension.setOutputCap(cap);
    else capExtension.setCap(cap);
    _assertSameLadder(address(wide), 32);
  }

  /// @dev 33 bins of length 100.
  function _widePackedArrays() internal pure returns (uint256[] memory packed) {
    packed = new uint256[](7);
    for (uint256 b; b < 33; b++) {
      packed[b / 5] |= uint256(100) << ((b % 5) * 48);
    }
  }

  function _assertSameLadder(uint8 maxBinsPerSide) internal {
    _assertSameLadder(address(cappedPool), maxBinsPerSide);
  }

  function _assertSameLadder(address pool, uint8 maxBinsPerSide) internal {
    (uint128 bid, uint128 ask, uint128 ref) = IPriceProvider(address(oracle)).getQuote();
    LiquidityLadder.LiquidityDepth memory got = sideFirst.depth(pool, maxBinsPerSide, bid, ask, ref);
    LiquidityLadderBinWalk.LiquidityDepth memory want = binWalk.depth(pool, maxBinsPerSide, bid, ask, ref);

    assertEq(got.effectiveCurrentAskX64, want.effectiveCurrentAskX64, "effective current ask");
    assertEq(got.effectiveCurrentBidX64, want.effectiveCurrentBidX64, "effective current bid");
    _assertSameSide(got.asks, want.asks, "asks");
    _assertSameSide(got.bids, want.bids, "bids");
  }

  function _assertSameSide(
    LiquidityLadder.DepthLevel[] memory got,
    LiquidityLadderBinWalk.DepthLevel[] memory want,
    string memory side
  ) internal pure {
    assertEq(got.length, want.length, string.concat(side, ": row count"));
    for (uint256 i; i < got.length; i++) {
      assertEq(got[i].binIdx, want[i].binIdx, string.concat(side, ": binIdx"));
      assertEq(got[i].lowerEffPriceX64, want[i].lowerEffPriceX64, string.concat(side, ": lower price"));
      assertEq(got[i].upperEffPriceX64, want[i].upperEffPriceX64, string.concat(side, ": upper price"));
      assertEq(got[i].amountAvailableInBin, want[i].amountAvailableInBin, string.concat(side, ": available"));
      assertEq(got[i].amountTradeableInBin, want[i].amountTradeableInBin, string.concat(side, ": tradeable"));
      assertEq(got[i].cumulativeOut, want[i].cumulativeOut, string.concat(side, ": cumulativeOut"));
      if (got[i].cumulativeOut > 0 && got[i].cumulativeIn == 0) {
        // Not simulated on its own: only allowed on a fully tradeable row that is not the side's last.
        assertEq(got[i].amountTradeableInBin, got[i].amountAvailableInBin, string.concat(side, ": unsimulated row"));
        assertLt(i + 1, got.length, string.concat(side, ": last row is always simulated"));
      } else {
        assertEq(got[i].cumulativeIn, want[i].cumulativeIn, string.concat(side, ": cumulativeIn"));
      }
    }
  }

  function _sideFirst(uint8 maxBinsPerSide) internal returns (LiquidityLadder.LiquidityDepth memory) {
    (uint128 bid, uint128 ask, uint128 ref) = IPriceProvider(address(oracle)).getQuote();
    return sideFirst.depth(address(cappedPool), maxBinsPerSide, bid, ask, ref);
  }

  function _swapExactOutput(bool zeroForOne, uint256 amountOut) internal returns (uint256) {
    if (amountOut == 0) return 0;
    vm.prank(swapper);
    return router.exactOutputSingle(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(cappedPool),
        tokenIn: zeroForOne ? address(weth) : address(token1),
        tokenOut: zeroForOne ? address(token1) : address(weth),
        zeroForOne: zeroForOne,
        amountOut: uint128(amountOut),
        amountInMaximum: type(uint128).max,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: _priceLimit(zeroForOne),
        extensionData: hex""
      })
    );
  }

  /// @dev 20 negative bins: four of length 100 (seeded with liquidity), then sixteen empty ones of the maximum
  ///      length, so the lowest bins' cumulative distance falls below -1e6.
  function _deepNegativeBinPackedArrays() internal pure returns (uint256[] memory neg) {
    neg = new uint256[](4);
    for (uint256 b; b < 20; b++) {
      uint256 lengthE6 = b < 4 ? 100 : type(uint16).max;
      neg[b / 5] |= lengthE6 << ((b % 5) * 48);
    }
  }

  function _deployCappedPool() internal returns (MetricOmmPool deployed) {
    (uint256[] memory nnPacked, uint256[] memory negPacked) = _binPackedArrays();
    return _deployCappedPoolFrom(nnPacked, negPacked);
  }

  function _deployCappedPoolFrom(uint256[] memory nnPacked, uint256[] memory negPacked)
    internal
    returns (MetricOmmPool deployed)
  {
    (BinState[] memory nnStates, BinState[] memory negStates) = _unpackBinStates(nnPacked, negPacked);
    (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier) =
      _getScaleMultipliers(address(weth), address(token1));

    PoolExtensions memory extensions;
    extensions.extension1 = address(capExtension);
    ExtensionOrders memory extensionOrders;
    extensionOrders.beforeSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);
    extensionOrders.afterSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);

    deployed = new MetricOmmPool(
      address(factoryStub),
      address(weth),
      address(token1),
      address(oracle),
      extensions,
      extensionOrders,
      true,
      token0ScaleMultiplier,
      token1ScaleMultiplier,
      INITIAL_TOKEN_0_DENSITY,
      INITIAL_TOKEN_1_DENSITY,
      MINIMAL_OPERATIONAL_LIQUIDITY,
      PROTOCOL_FEE + ADMIN_FEE,
      0,
      nnStates,
      negStates,
      0,
      type(uint16).max
    );

    factoryStub.registerPool(
      address(deployed),
      PoolFeeConfig({
        protocolSpreadFeeE6: PROTOCOL_FEE, adminSpreadFeeE6: ADMIN_FEE, protocolNotionalFeeE8: 0, adminNotionalFeeE8: 0
      }),
      makeAddr("parityAdminFeeDest"),
      address(this)
    );
  }
}
