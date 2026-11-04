// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMetricOmmPool, PoolImmutables} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmPoolFactory} from "@metric-core/interfaces/IMetricOmmPoolFactory/IMetricOmmPoolFactory.sol";
import {FeeMath} from "@metric-core/libraries/FeeMath.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {SwapMath} from "@metric-core/libraries/SwapMath.sol";
import {MetricOmmSwapPath} from "./MetricOmmSwapPath.sol";
import {MetricOmmSwapInputs} from "./MetricOmmSwapInputs.sol";
import {MetricOmmSwapQuoteDecode} from "./MetricOmmSwapQuoteDecode.sol";

/// @title LiquidityLadder
/// @notice Builds a pool's bid/ask depth ladder for `MetricOmmPoolDataProvider`.
/// @dev Depth ladder rows are sized from raw bin balances (the amount to fully cross each bin, from `slot0` and
///      per-bin state) and priced two ways: `lowerEffPriceX64`/`upperEffPriceX64` mirror the pool's own
///      per-bin execution-price formula (`MetricOmmPool._swapAcrossBins`: fee-adjust each bound, then interpolate
///      only for the in-bin current position), while `cumulativeOut`/`cumulativeIn` come from actually running the
///      cumulative amount through `simulateSwapAndRevert` - never re-derived swap math for the traded amounts.
///      Simulations use the data provider as both sender and recipient, with empty extension data; depth is
///      therefore evaluated in the provider's extension context, not a particular trader's or router's.
///      A side stops at the first bin whose full-crossing cumulative amount does not fill in full (e.g. an extension
///      gate reverts it). That bin is found by simulating the first funded bin, then the whole side, then
///      binary-searching the rest (see `_resolveSide`), rather than simulating every bin's cumulative amount in turn.
///      This relies on refusals being monotone in trade size. Only the rows kept are priced. In the stop bin the
///      ladder bisects (from the bin's midpoint, up to `MAX_BINARY_SEARCH_ITERATIONS` probes) the maximal amount that
///      still succeeds - any larger amount is assumed to keep failing the same way.
library LiquidityLadder {
  using SafeCast for uint256;
  using SafeCast for int256;

  // ============ Errors ============

  /// @notice Oracle quote is invalid (`bid == 0`, `bid > ask`, or reference outside `[bid, ask]`).
  error InvalidOraclePrice();
  /// @notice Combined notional fee is greater than or equal to 100%.
  error InvalidNotionalFee();
  /// @notice Distance-based price conversion received a negative distance lower than -1e6.
  error InvalidDistance();
  /// @notice `maxBinsPerSide` was zero.
  error MaxBinsPerSideZero();
  /// @notice `simulateSwapAndRevert` completed without a `SimulateSwap` revert (violates its own contract).
  error SimulateSwapDidNotRevert();

  // ============ Types ============

  /// @notice One depth step on the ask (buy token0) or bid (sell token0) side.
  /// @param lowerEffPriceX64 Fee-adjusted execution price at the bin's lower bound.
  /// @param upperEffPriceX64 Fee-adjusted execution price at the bin's upper bound.
  /// @param amountAvailableInBin Raw amount tradeable in this bin per pool state, ignoring extensions (partial for the current bin).
  /// @param amountTradeableInBin Amount actually reachable in this bin once extension gates are accounted for; `< amountAvailableInBin` only on the row where the ladder stops.
  /// @param cumulativeOut Cumulative amount received by the trader through this bin (token0 for asks, token1 for bids).
  /// @param cumulativeIn Cumulative amount paid by the trader through this bin (token1 for asks, token0 for bids), or
  ///        zero when the cumulative trade through this bin was not simulated on its own (a row before the last one a
  ///        side simulated; see `_resolveSide`). A non-zero `cumulativeOut` with a zero `cumulativeIn` marks such a row.
  struct DepthLevel {
    int16 binIdx;
    uint256 lowerEffPriceX64;
    uint256 upperEffPriceX64;
    uint256 amountAvailableInBin;
    uint256 amountTradeableInBin;
    uint256 cumulativeOut;
    uint256 cumulativeIn;
  }

  /// @notice Full depth snapshot for a pool.
  /// @param oracleBidX64 Bid price used for the snapshot.
  /// @param oracleAskX64 Ask price used for the snapshot.
  /// @param oracleReferenceX64 Reference price used for the snapshot.
  /// @param effectiveCurrentBidX64 Fee-adjusted sell price at the pool's exact current position, rounded up (the pool
  ///        rounds sell-side interpolation down, so this may exceed the pool's price by 1 wei); zero if `bids` is empty.
  /// @param effectiveCurrentAskX64 Fee-adjusted buy price at the pool's exact current position; zero if `asks` is empty.
  /// @param asks Ask rows ordered from the current bin upward.
  /// @param bids Bid rows ordered from the current bin downward.
  struct LiquidityDepth {
    uint128 oracleBidX64;
    uint128 oracleAskX64;
    uint128 oracleReferenceX64;
    uint128 effectiveCurrentBidX64;
    uint128 effectiveCurrentAskX64;
    DepthLevel[] asks;
    DepthLevel[] bids;
  }

  /// @dev Bundles the per-side simulate-call parameters so ladder building and binary search pass one
  ///      memory pointer instead of four stack slots (keeps the via-IR build's stack shallow).
  struct SwapPriceContext {
    bool zeroForOne;
    uint128 priceLimitX64;
    uint128 bidPriceX64;
    uint128 askPriceX64;
    uint128 referencePriceX64;
  }

  /// @dev Packed read context to keep the build loops' stack shallow for via-IR builds.
  struct DepthEnv {
    PoolImmutables imm;
    uint256 token0ScaleMultiplier;
    uint256 token1ScaleMultiplier;
    uint256 baseBuyFeeX64;
    uint256 baseSellFeeX64;
    uint256 notionalFeeE8;
    int16 curBinIdx;
    uint104 curPosInBin;
    int24 curBinDistFromProvidedPriceE6;
  }

  // ============ Constants ============

  uint256 internal constant ONE_E6 = 1e6;
  uint256 internal constant ONE_E8 = 1e8;

  /// @dev Q64.64 fixed-point scale for marginal and execution prices (token1 per token0).
  uint256 internal constant Q64 = 1 << 64;

  /// @dev Cap on bisection probes per failing bin: start at the midpoint of the bin's range, halve on each
  ///      probe. If none of them succeed, the bin is treated as having nothing tradable.
  uint256 internal constant MAX_BINARY_SEARCH_ITERATIONS = 20;

  // ============ Entry point ============

  /// @notice Builds ask and bid ladders from caller-supplied oracle prices.
  /// @dev Each side holds at most `maxBinsPerSide + 1` rows (the current bin plus `maxBinsPerSide` bins away from it),
  ///      bounded by the pool's lowest and highest bins. Reverts with `MaxBinsPerSideZero`, `InvalidOraclePrice`, or
  ///      `InvalidNotionalFee` (combined notional fee >= 100%); `InvalidDistance` / `AmountTooLarge` /
  ///      `SimulateSwapDidNotRevert` on malformed pool state.
  function build(
    address pool,
    address factory,
    uint8 maxBinsPerSide,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64
  ) internal returns (LiquidityDepth memory depth) {
    if (maxBinsPerSide == 0) revert MaxBinsPerSideZero();
    if (
      bidPriceX64 == 0 || bidPriceX64 > askPriceX64 || referencePriceX64 < bidPriceX64
        || referencePriceX64 > askPriceX64
    ) {
      revert InvalidOraclePrice();
    }

    DepthEnv memory env = _loadDepthEnv(pool, factory, bidPriceX64, askPriceX64, referencePriceX64);

    depth.oracleBidX64 = bidPriceX64;
    depth.oracleAskX64 = askPriceX64;
    depth.oracleReferenceX64 = referencePriceX64;

    int16 highCap = _highBinCap(env.imm.highestBin, env.curBinIdx, maxBinsPerSide);
    depth.asks = _buildAskLadder(pool, env, bidPriceX64, askPriceX64, referencePriceX64, highCap);

    int16 lowCap = _lowBinCap(env.imm.lowestBin, env.curBinIdx, maxBinsPerSide);
    depth.bids = _buildBidLadder(pool, env, bidPriceX64, askPriceX64, referencePriceX64, lowCap);

    if (depth.asks.length > 0) {
      depth.effectiveCurrentAskX64 = SwapMath.calculatePriceAtBinPosition(
          depth.asks[0].lowerEffPriceX64, depth.asks[0].upperEffPriceX64, uint256(env.curPosInBin), Math.Rounding.Ceil
        ).toUint128();
    }
    if (depth.bids.length > 0) {
      depth.effectiveCurrentBidX64 = SwapMath.calculatePriceAtBinPosition(
          depth.bids[0].lowerEffPriceX64, depth.bids[0].upperEffPriceX64, uint256(env.curPosInBin), Math.Rounding.Ceil
        ).toUint128();
    }
  }

  // ============ Internal: depth context ============

  function _loadDepthEnv(
    address pool,
    address factory,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64
  ) internal view returns (DepthEnv memory env) {
    env.imm = IMetricOmmPool(pool).getImmutables();
    env.token0ScaleMultiplier = env.imm.token0ScaleMultiplier;
    env.token1ScaleMultiplier = env.imm.token1ScaleMultiplier;
    (,, uint24 protocolNotionalFeeE8, uint24 adminNotionalFeeE8) = IMetricOmmPoolFactory(factory).poolFeeConfig(pool);
    env.notionalFeeE8 = uint256(protocolNotionalFeeE8) + uint256(adminNotionalFeeE8);
    if (env.notionalFeeE8 >= ONE_E8) revert InvalidNotionalFee();

    (env.baseBuyFeeX64, env.baseSellFeeX64) = SwapMath.buySellBaseFeesX64FromBidAskAndReference(
      uint256(bidPriceX64), uint256(askPriceX64), uint256(referencePriceX64)
    );
    (, env.curBinIdx, env.curPosInBin, env.curBinDistFromProvidedPriceE6,,,) = PoolStateLibrary._slot0(pool);
  }

  function _highBinCap(int256 highestBin, int16 curBinIdx, uint8 maxBinsPerSide) internal pure returns (int16 highCap) {
    // forge-lint: disable-next-line(unsafe-typecast)
    int256 hi = int256(curBinIdx) + int256(uint256(maxBinsPerSide));
    if (hi > highestBin) hi = highestBin;
    // forge-lint: disable-next-line(unsafe-typecast)
    highCap = int16(hi);
  }

  function _lowBinCap(int256 lowestBin, int16 curBinIdx, uint8 maxBinsPerSide) internal pure returns (int16 lowCap) {
    // forge-lint: disable-next-line(unsafe-typecast)
    int256 lo = int256(curBinIdx) - int256(uint256(maxBinsPerSide));
    if (lo < lowestBin) lo = lowestBin;
    // forge-lint: disable-next-line(unsafe-typecast)
    lowCap = int16(lo);
  }

  // ============ Internal: reference-anchored bin bounds ============

  function _priceFromReferenceAndDistE6(uint256 referencePriceX64, int256 distE6, Math.Rounding rounding)
    internal
    pure
    returns (uint256)
  {
    if (distE6 >= 0) {
      // forge-lint: disable-next-line(unsafe-typecast)
      uint256 distAbs = uint256(distE6);
      return Math.mulDiv(referencePriceX64, ONE_E6 + distAbs, ONE_E6, rounding);
    }
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 distNegAbs = uint256(-distE6);
    if (distNegAbs > ONE_E6) revert InvalidDistance();
    return Math.mulDiv(referencePriceX64, ONE_E6 - distNegAbs, ONE_E6, rounding);
  }

  function _toExternal(uint256 amountScaled, uint256 scaleMultiplier) internal pure returns (uint256) {
    if (scaleMultiplier == 0) {
      return amountScaled;
    }
    return amountScaled / scaleMultiplier;
  }

  /// @dev Fee-adjusted execution prices at a bin's two bounds, from its lower-bound distance and length. Mirrors the
  ///      pool's own per-bin bounds in `MetricOmmPool._swapAcrossBins`; `isSell` selects the bid-side adjustment.
  function _binEffBounds(
    uint256 referencePriceX64,
    int256 lowerDistE6,
    uint16 lengthE6,
    uint256 baseFeeX64,
    uint16 addFeeE6,
    uint256 notionalFeeX64,
    bool isSell
  ) internal pure returns (uint256 lowerEffPriceX64, uint256 upperEffPriceX64) {
    uint256 lowerReferencePriceX64 = _priceFromReferenceAndDistE6(referencePriceX64, lowerDistE6, Math.Rounding.Floor);
    // forge-lint: disable-next-line(unsafe-typecast)
    int256 upperDistE6 = lowerDistE6 + int256(uint256(lengthE6));
    uint256 upperReferencePriceX64 = _priceFromReferenceAndDistE6(referencePriceX64, upperDistE6, Math.Rounding.Floor);
    uint256 feeX64 = FeeMath.binTotalFeeX64(baseFeeX64, addFeeE6, notionalFeeX64);
    lowerEffPriceX64 = FeeMath.effectivePriceX64(lowerReferencePriceX64, feeX64, isSell);
    upperEffPriceX64 = FeeMath.effectivePriceX64(upperReferencePriceX64, feeX64, isSell);
  }

  // ============ Internal: depth ladder walks ============
  // Each side is built in two steps:
  //   1. Decide how far the side actually executes with as few bin reads and `simulateSwapAndRevert` calls as it
  //      can (`_resolveSide`), and truncate the side there. A bin with zero raw balance still gets a row.
  //   2. Price only the rows that are kept. A row past the stop is never priced, so a bin whose bounds cannot be
  //      computed (e.g. a cumulative distance below -1e6) cannot revert a ladder that stops before it, exactly as the
  //      bin-by-bin walk never reached it.

  function _buildAskLadder(
    address pool,
    DepthEnv memory env,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64,
    int16 highCap
  ) internal returns (DepthLevel[] memory asks) {
    // casting to 'uint256' is safe because the ternary guard 'env.curBinIdx <= highCap' ensures the
    // int16 difference plus 1 is always >= 1, so no sign reinterpretation occurs
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 maxRows = env.curBinIdx <= highCap ? uint256(int256(highCap) - int256(env.curBinIdx) + 1) : 0;
    asks = new DepthLevel[](maxRows);
    if (maxRows == 0) return asks;

    bytes32[] memory states = new bytes32[](maxRows);

    SwapPriceContext memory ctx = SwapPriceContext({
      zeroForOne: false,
      priceLimitX64: MetricOmmSwapPath.openLimit(false),
      bidPriceX64: bidPriceX64,
      askPriceX64: askPriceX64,
      referencePriceX64: referencePriceX64
    });
    _truncate(asks, _resolveSide(pool, env, ctx, asks, states));
    _priceAskRows(env, uint256(referencePriceX64), asks, states);
  }

  function _buildBidLadder(
    address pool,
    DepthEnv memory env,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64,
    int16 lowCap
  ) internal returns (DepthLevel[] memory bids) {
    // casting to 'uint256' is safe because the ternary guard 'env.curBinIdx >= lowCap' ensures the
    // int16 difference plus 1 is always >= 1, so no sign reinterpretation occurs
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 maxRows = env.curBinIdx >= lowCap ? uint256(int256(env.curBinIdx) - int256(lowCap) + 1) : 0;
    bids = new DepthLevel[](maxRows);
    if (maxRows == 0) return bids;

    bytes32[] memory states = new bytes32[](maxRows);

    SwapPriceContext memory ctx = SwapPriceContext({
      zeroForOne: true,
      priceLimitX64: MetricOmmSwapPath.openLimit(true),
      bidPriceX64: bidPriceX64,
      askPriceX64: askPriceX64,
      referencePriceX64: referencePriceX64
    });
    _truncate(bids, _resolveSide(pool, env, ctx, bids, states));
    _priceBidRows(env, uint256(referencePriceX64), bids, states);
  }

  /// @dev Reads rows `[from, to)`: sets each row's `binIdx` (from the current bin, upward for asks and downward for
  ///      bids), reads their bin states in one batched `extsload` into `states`, and records each row's raw balance on
  ///      the side's output token. Rows never read keep a zero balance and a zero state.
  function _readRows(
    address pool,
    DepthEnv memory env,
    bool isBid,
    DepthLevel[] memory rows,
    bytes32[] memory states,
    uint256 from,
    uint256 to
  ) internal view {
    if (from >= to) return;
    int16[] memory binIdxs = new int16[](to - from);
    for (uint256 i = from; i < to; i++) {
      // forge-lint: disable-next-line(unsafe-typecast)
      int16 binIdx = isBid ? int16(int256(env.curBinIdx) - int256(i)) : int16(int256(env.curBinIdx) + int256(i));
      binIdxs[i - from] = binIdx;
      rows[i].binIdx = binIdx;
    }
    bytes32[] memory read = PoolStateLibrary._multipleBinStates(pool, binIdxs);
    for (uint256 i = from; i < to; i++) {
      states[i] = read[i - from];
      (uint104 t0, uint104 t1,,,) = PoolStateLibrary._decodeBinState(states[i]);
      rows[i].amountAvailableInBin = isBid
        ? _toExternal(uint256(t1), env.token1ScaleMultiplier)
        : _toExternal(uint256(t0), env.token0ScaleMultiplier);
    }
  }

  /// @dev Prices the kept ask rows. A row's lower-bound distance is the current bin's plus the lengths of every row
  ///      before it.
  function _priceAskRows(
    DepthEnv memory env,
    uint256 referencePriceX64,
    DepthLevel[] memory rows,
    bytes32[] memory states
  ) internal pure {
    uint256 notionalFeeX64 = FeeMath._notionalFeeX64(uint24(env.notionalFeeE8));
    int256 lowerDistE6 = int256(env.curBinDistFromProvidedPriceE6);
    for (uint256 i; i < rows.length; i++) {
      (,, uint16 lengthE6, uint16 addFeeBuyE6,) = PoolStateLibrary._decodeBinState(states[i]);
      (rows[i].lowerEffPriceX64, rows[i].upperEffPriceX64) =
        _binEffBounds(referencePriceX64, lowerDistE6, lengthE6, env.baseBuyFeeX64, addFeeBuyE6, notionalFeeX64, false);
      // forge-lint: disable-next-line(unsafe-typecast)
      lowerDistE6 += int256(uint256(lengthE6));
    }
  }

  /// @dev Prices the kept bid rows. The current bin's lower-bound distance is `curBinDistFromProvidedPriceE6`; each
  ///      lower bin's is the bin above's minus the lower bin's own length (bins are contiguous).
  function _priceBidRows(
    DepthEnv memory env,
    uint256 referencePriceX64,
    DepthLevel[] memory rows,
    bytes32[] memory states
  ) internal pure {
    uint256 notionalFeeX64 = FeeMath._notionalFeeX64(uint24(env.notionalFeeE8));
    int256 lowerDistE6 = int256(env.curBinDistFromProvidedPriceE6);
    for (uint256 i; i < rows.length; i++) {
      (,, uint16 lengthE6,, uint16 addFeeSellE6) = PoolStateLibrary._decodeBinState(states[i]);
      // forge-lint: disable-next-line(unsafe-typecast)
      if (i != 0) lowerDistE6 -= int256(uint256(lengthE6));
      (rows[i].lowerEffPriceX64, rows[i].upperEffPriceX64) =
        _binEffBounds(referencePriceX64, lowerDistE6, lengthE6, env.baseSellFeeX64, addFeeSellE6, notionalFeeX64, true);
    }
  }

  // ============ Internal: how far a side executes ============

  /// @dev One `simulateSwapAndRevert` outcome: `ok` when it answered with the `SimulateSwap` payload.
  struct SimResult {
    bool ok;
    uint256 outAmt;
    uint256 inAmt;
  }

  /// @dev A side's funded rows (`amountAvailableInBin > 0`), in walk order. `prefixOut[k]` is the cumulative output
  ///      that crosses funded rows `0..k` in full, and `prefixIn[k]` the input a simulation of exactly that amount
  ///      charged, or zero if that prefix was never simulated on its own.
  struct FundedRows {
    uint256[] rowIdx;
    uint256[] prefixOut;
    uint256[] prefixIn;
    uint256 count;
  }

  /// @dev Reads the side's bins as it needs them (into `rows` and `states`), fills in the simulate-backed fields, and
  ///      returns how many rows to keep. Rows past the returned length may be unread.
  ///
  ///      A side stops at the first bin that cannot be filled in full - the row the former bin-by-bin walk stopped at,
  ///      provided refusals are monotone in trade size (below) - but that row is found without simulating every
  ///      prefix of the side:
  ///
  ///      1. Read bins one at a time up to the first funded one and simulate it on its own. A tripped stop-loss
  ///         usually refuses right there, and then the side is settled having read and simulated nothing past that
  ///         bin, exactly as the bin-by-bin walk.
  ///      2. Otherwise read every remaining bin up to the cap (one batched `extsload`) and simulate the trade that
  ///         crosses every funded row. If it fills in full, so does every smaller trade: nothing on the side is
  ///         refused.
  ///      3. Otherwise binary-search the funded rows after the first for the first whose cumulative trade does not
  ///         fill in full.
  ///      4. In that row, keep the simulation's own partial fill if it answered, else bisect for the largest amount
  ///         that still succeeds (`_bisect`, unchanged from the bin-by-bin walk).
  ///
  ///      Steps 2 and 3 rely on refusals being monotone in trade size: if a cumulative amount fails, every larger one
  ///      fails too. The bin-by-bin walk already assumed this past its stop row (it never looked further); this
  ///      extends the assumption to the rows before it. An extension that refuses a mid-sized trade while accepting
  ///      a larger one would be reported as accepting everything up to the largest it accepts.
  ///
  ///      A row whose cumulative trade was not simulated on its own keeps `cumulativeIn == 0` while its
  ///      `cumulativeOut` is positive; its `cumulativeOut` is still exact, since a full fill delivers exactly the
  ///      requested output. Cost on an unrefused side with `n > 1` funded rows: 2 simulations instead of `n`; on a
  ///      side refused at funded row `s`: 1 simulation when `s == 0`, else 2 + ceil(log2(n - 1)), plus the stop row's
  ///      bisection, instead of `s + 1` plus the same bisection.
  function _resolveSide(
    address pool,
    DepthEnv memory env,
    SwapPriceContext memory ctx,
    DepthLevel[] memory rows,
    bytes32[] memory states
  ) internal returns (uint256 length) {
    uint256 n = rows.length;
    bool isBid = ctx.zeroForOne;
    uint256 first;
    for (; first < n; first++) {
      _readRows(pool, env, isBid, rows, states, first, first + 1);
      if (rows[first].amountAvailableInBin > 0) break;
    }
    // Nothing funded: every row stays flat at zero, exactly as the walk recorded them.
    if (first == n) return n;

    uint256 firstOut = rows[first].amountAvailableInBin;
    SimResult memory firstResult = _trySimulateExactOutput(pool, ctx, firstOut);
    if (!_filledInFull(firstResult, firstOut)) {
      // Only rows [0, first] are read, so the funded rows are just `first`.
      _recordStopRow(pool, ctx, rows[first], _fundedRows(rows), 0, firstResult);
      return first + 1;
    }

    _readRows(pool, env, isBid, rows, states, first + 1, n);
    FundedRows memory funded = _fundedRows(rows);
    funded.prefixIn[0] = firstResult.inAmt;
    uint256 last = funded.count - 1;
    if (last == 0) {
      _recordFullRows(rows, funded, n);
      return n;
    }

    SimResult memory stopResult = _trySimulateExactOutput(pool, ctx, funded.prefixOut[last]);
    if (_filledInFull(stopResult, funded.prefixOut[last])) {
      funded.prefixIn[last] = stopResult.inAmt;
      _recordFullRows(rows, funded, n);
      return n;
    }

    // Invariant: funded rows [0, good) fill in full, and `good - 1` was simulated on its own; funded row `stop` does
    // not fill in full, and `stopResult` is its result. Binary-search [good, stop): every row it advances `good` past
    // is one it simulated.
    uint256 good = 1;
    uint256 stop = last;
    while (stop > good) {
      uint256 mid = good + (stop - good) / 2;
      SimResult memory midResult = _trySimulateExactOutput(pool, ctx, funded.prefixOut[mid]);
      if (_filledInFull(midResult, funded.prefixOut[mid])) {
        funded.prefixIn[mid] = midResult.inAmt;
        good = mid + 1;
      } else {
        stop = mid;
        stopResult = midResult;
      }
    }

    uint256 stopRow = funded.rowIdx[stop];
    _recordFullRows(rows, funded, stopRow);
    _recordStopRow(pool, ctx, rows[stopRow], funded, stop, stopResult);
    length = stopRow + 1;
  }

  /// @dev Collects a side's funded rows and their cumulative full-fill outputs. Cannot overflow: each bin's raw
  ///      balance is a `uint104` and a side holds at most 256 bins.
  function _fundedRows(DepthLevel[] memory rows) internal pure returns (FundedRows memory funded) {
    uint256 n = rows.length;
    funded.rowIdx = new uint256[](n);
    funded.prefixOut = new uint256[](n);
    funded.prefixIn = new uint256[](n);
    uint256 cumOut;
    for (uint256 i; i < n; i++) {
      uint256 available = rows[i].amountAvailableInBin;
      if (available == 0) continue;
      cumOut += available;
      funded.rowIdx[funded.count] = i;
      funded.prefixOut[funded.count] = cumOut;
      funded.count++;
    }
  }

  /// @dev Whether a simulation of `amount` filled it in full - the bin-by-bin walk's `reachedFullBin`, over the
  ///      whole cumulative amount instead of one bin's share of it.
  function _filledInFull(SimResult memory result, uint256 amount) internal pure returns (bool) {
    return result.ok && result.outAmt == amount;
  }

  /// @dev Records rows `[0, end)` as filled in full: every funded row's whole balance is tradeable, and a zero-balance
  ///      row carries the cumulative amounts of the row before it (flat), as in the bin-by-bin walk.
  function _recordFullRows(DepthLevel[] memory rows, FundedRows memory funded, uint256 end) internal pure {
    uint256 k;
    uint256 cumOut;
    uint256 cumIn;
    for (uint256 i; i < end; i++) {
      if (rows[i].amountAvailableInBin > 0) {
        rows[i].amountTradeableInBin = rows[i].amountAvailableInBin;
        cumOut = funded.prefixOut[k];
        cumIn = funded.prefixIn[k];
        k++;
      }
      rows[i].cumulativeOut = cumOut;
      rows[i].cumulativeIn = cumIn;
    }
  }

  /// @dev Records the row a side stops at: how much of it still executes, and the cumulative amounts through that.
  ///      `stop` indexes the funded rows; every funded row before it filled in full, and the one just before it was
  ///      simulated on its own (the search only advances past a row it simulated), so its `prefixIn` is known.
  function _recordStopRow(
    address pool,
    SwapPriceContext memory ctx,
    DepthLevel memory row,
    FundedRows memory funded,
    uint256 stop,
    SimResult memory stopResult
  ) internal {
    uint256 priorOut = stop == 0 ? 0 : funded.prefixOut[stop - 1];
    uint256 priorIn = stop == 0 ? 0 : funded.prefixIn[stop - 1];
    // A simulation that answered but delivered short of the full amount is the row's fill as it stands, exactly as
    // the walk took it from its full-bin candidate; only a refused one needs the bisection.
    SimResult memory fill = stopResult.ok ? stopResult : _bisect(pool, ctx, priorOut, funded.prefixOut[stop]);
    row.amountTradeableInBin = fill.ok ? fill.outAmt - priorOut : 0;
    row.cumulativeOut = fill.ok ? fill.outAmt : priorOut;
    row.cumulativeIn = fill.ok ? fill.inAmt : priorIn;
  }

  // ============ Internal: simulate-backed sizing ============

  /// @dev Bisects `(lo, hi)` - `lo` known to fill (or zero), `hi` known to be refused - starting at its midpoint, for
  ///      up to `MAX_BINARY_SEARCH_ITERATIONS` probes, keeping the largest amount found to still succeed. `ok` is
  ///      false if none of the probes ever succeed (nothing tradable past `lo`).
  function _bisect(address pool, SwapPriceContext memory ctx, uint256 lo, uint256 hi)
    internal
    returns (SimResult memory best)
  {
    for (uint256 i; i < MAX_BINARY_SEARCH_ITERATIONS; ++i) {
      if (hi - lo <= 1) break;
      uint256 mid = lo + (hi - lo) / 2;
      SimResult memory midResult = _trySimulateExactOutput(pool, ctx, mid);
      if (midResult.ok) {
        lo = mid;
        best = midResult;
      } else {
        hi = mid;
      }
    }
  }

  /// @dev Decodes the `SimulateSwap` revert into direction-agnostic `(outAmt, inAmt)`: the amount the trader
  ///      receives and pays, regardless of which token0/token1 leg that maps to for `ctx.zeroForOne`.
  function _trySimulateExactOutput(address pool, SwapPriceContext memory ctx, uint256 amountOutExternal)
    internal
    returns (SimResult memory result)
  {
    int128 amountSpecified = MetricOmmSwapInputs.asAmountSpecifiedOut(MetricOmmSwapInputs.toUint128(amountOutExternal));
    try IMetricOmmPoolActions(pool)
      .simulateSwapAndRevert(
        address(this),
        address(this),
        ctx.zeroForOne,
        amountSpecified,
        ctx.priceLimitX64,
        ctx.bidPriceX64,
        ctx.askPriceX64,
        ctx.referencePriceX64,
        hex""
      ) returns (
      int128, int128
    ) {
      revert SimulateSwapDidNotRevert();
    } catch (bytes memory reason) {
      (int128 amount0Delta, int128 amount1Delta, bool matched) =
        MetricOmmSwapQuoteDecode.decodeSwapDeltas(reason, IMetricOmmPoolActions.SimulateSwap.selector);
      if (!matched) return result;
      result.ok = true;
      if (ctx.zeroForOne) {
        result.outAmt = (-int256(amount1Delta)).toUint256();
        result.inAmt = int256(amount0Delta).toUint256();
      } else {
        result.outAmt = (-int256(amount0Delta)).toUint256();
        result.inAmt = int256(amount1Delta).toUint256();
      }
    }
  }

  function _truncate(DepthLevel[] memory levels, uint256 length) internal pure {
    assembly ("memory-safe") {
      mstore(levels, length)
    }
  }
}
