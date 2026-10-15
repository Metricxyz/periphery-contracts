// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMetricOmmPool} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {IPriceProvider} from "@metric-core/interfaces/IPriceProvider/IPriceProvider.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {MetricOmmPoolStateView} from "../common/MetricOmmPoolStateView.sol";
import {LiquidityLadder} from "../libraries/LiquidityLadder.sol";

/// @title MetricOmmPoolDataProvider
/// @notice Read-only swap data for MetricOMM pools: per-bin depth ladders, distance from the provided price, and
///         the raw state getters of `MetricOmmPoolStateView`.
/// @dev For off-chain queries only (e.g. `eth_call`, indexers, UIs). Do not call from other contracts inside a transaction; this lens is not gas-optimized for on-chain composition.
///      Depth getters are non-view because they run `simulateSwapAndRevert` against the pool; call them via `eth_call`.
///      Depth ladder construction lives in `LiquidityLadder`; this contract resolves prices and wires the pool/factory context into it.
contract MetricOmmPoolDataProvider is MetricOmmPoolStateView {
  // ============ Errors ============

  /// @notice Constructor received zero factory address.
  error InvalidFactory();
  /// @notice Pool has neither mutable nor immutable price provider configured.
  error InvalidPriceProvider();

  // ============ Constants ============

  uint256 internal constant ONE_E6 = 1e6;

  /// @dev Q64 fixed-point scale for `distanceFromProvidedPriceX64` (2^64 = 100%).
  uint256 internal constant Q64 = 1 << 64;

  uint256 internal constant MAX_POS_U104 = type(uint104).max;

  // ============ Constructor ============

  constructor(address factory) MetricOmmPoolStateView(factory) {
    if (factory == address(0)) revert InvalidFactory();
  }

  // ============ External: swap data views ============

  /// @notice Returns current distance from the provided price as a signed Q64 fraction (2^64 = 100%).
  /// @dev Sum of the current bin's lower-bound distance and the in-bin offset (`lengthE6 * curPosInBin / type(uint104).max`), each rounded toward zero.
  function distanceFromProvidedPriceX64(address pool) external view returns (int256 distanceX64) {
    (, int16 curBinIdx, uint104 curPosInBin, int24 curBinDistFromProvidedPriceE6,,,) = PoolStateLibrary._slot0(pool);
    (,, uint16 lengthE6,,) = PoolStateLibrary._binState(pool, curBinIdx);

    int256 baseDistE6 = int256(curBinDistFromProvidedPriceE6);
    int256 baseDistAbsE6 = baseDistE6 >= 0 ? baseDistE6 : -baseDistE6;
    // casting to `uint256` is safe because `baseDistAbsE6` is made non-negative above
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 baseDistAbsX64 = Math.mulDiv(uint256(baseDistAbsE6), Q64, ONE_E6, Math.Rounding.Floor);
    // casting to `int256` is safe because `baseDistAbsX64` is derived from bounded E6 distance and scales linearly
    // forge-lint: disable-next-line(unsafe-typecast)
    int256 signedBaseDistX64 = baseDistE6 >= 0 ? int256(baseDistAbsX64) : -int256(baseDistAbsX64);

    uint256 inBinDistNumerator = uint256(lengthE6) * uint256(curPosInBin);
    uint256 inBinDistX64 = Math.mulDiv(inBinDistNumerator, Q64, ONE_E6 * MAX_POS_U104, Math.Rounding.Floor);

    // casting to `int256` is safe because `inBinDistX64` is non-negative and bounded by one-bin distance in X64
    // forge-lint: disable-next-line(unsafe-typecast)
    distanceX64 = signedBaseDistX64 + int256(inBinDistX64);
  }

  // ---- Per-bin depth ladders ----

  /// @notice Computes read-only bid and ask depth ladders from the pool's current bin outward, using the prices read from the pool's active price provider.
  /// @dev Quotes the pool's active price provider directly (mutable provider from storage, else immutable). Reverts with `InvalidPriceProvider` if none is set, with `LiquidityLadder` errors on a malformed quote, zero `maxBinsPerSide` or a combined notional fee of 100% or more; provider reverts bubble.
  ///      Prices that pass `InvalidOraclePrice` but fail the pool's own validation (`bid == ask`, asymmetry bound)
  ///      yield zero tradeable depth instead of reverting; extension gates may also reduce depth.
  /// @param pool Pool to read.
  /// @param maxBinsPerSide Maximum bins per side beyond the current bin (each side returns up to `maxBinsPerSide + 1` rows including the current bin); clamped to the pool's lowest/highest bin. Must be non-zero.
  function getLiquidityDepthLive(address pool, uint8 maxBinsPerSide)
    external
    returns (LiquidityLadder.LiquidityDepth memory depth)
  {
    address provider = _resolvePriceProvider(pool);
    (uint128 bidPriceX64, uint128 askPriceX64, uint128 referencePriceX64) = IPriceProvider(provider).getQuote();
    return LiquidityLadder.build(pool, FACTORY, maxBinsPerSide, bidPriceX64, askPriceX64, referencePriceX64);
  }

  /// @notice Computes read-only bid and ask depth ladders from the pool's current bin outward, at caller-supplied bid/ask/reference prices.
  /// @dev Reverts with `LiquidityLadder.InvalidOraclePrice` unless `0 < bid <= ask` and `bid <= reference <= ask`, and with the same ladder errors as `getLiquidityDepthLive`. Prices that pass that check but fail the pool's own validation (`bid == ask`, asymmetry bound) yield zero tradeable depth instead of reverting; extension gates may also reduce depth.
  /// @param pool Pool to read.
  /// @param maxBinsPerSide Maximum bins per side beyond the current bin (each side returns up to `maxBinsPerSide + 1` rows including the current bin); clamped to the pool's lowest/highest bin. Must be non-zero.
  /// @param bidPriceX64 Hypothetical bid price (Q64.64).
  /// @param askPriceX64 Hypothetical ask price (Q64.64).
  /// @param referencePriceX64 Hypothetical reference price (Q64.64).
  function getLiquidityDepthHypothetical(
    address pool,
    uint8 maxBinsPerSide,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64
  ) external returns (LiquidityLadder.LiquidityDepth memory depth) {
    return LiquidityLadder.build(pool, FACTORY, maxBinsPerSide, bidPriceX64, askPriceX64, referencePriceX64);
  }

  // ============ Internal: factory and price-provider resolution ============

  /// @dev Mutable provider from pool storage if set, otherwise the immutable one; the pool itself prefers the immutable (the two are never both set).
  function _resolvePriceProvider(address pool) internal view returns (address provider) {
    provider = PoolStateLibrary._slot3(pool);
    if (provider == address(0)) {
      provider = IMetricOmmPool(pool).getImmutables().immutablePriceProvider;
    }
    if (provider == address(0)) revert InvalidPriceProvider();
  }
}
