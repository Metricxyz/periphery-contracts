// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IMetricOmmSwapQuoter
/// @notice Off-chain swap quotes via simulateSwapAndRevert: live quotes use prices the quoter reads from the pool's
///         active price provider, hypothetical quotes use caller-supplied prices.
/// @dev For off-chain queries only (eth_call). Both quote kinds read SimulateSwap revert data.
///      All quote functions forward `sender` to swap extensions on every hop. A zero sender defaults to
///      `msg.sender`. For router quotes, supply the router as sender.
///      Short live overloads and multihop quotes use the quoter as recipient.
///      Every quote returns `(quotedAmountIn, quotedAmountOut)` in native token units. Single-hop quotes return the pool's simulated
///      amounts; multihop quotes return the first hop's input and the last hop's output. A single-hop exact-input
///      `quotedAmountIn` is the input actually used (may be a partial fill), whereas multihop exact-input returns the requested
///      input because partial fills revert with `InvalidInputAmountAtHop`.
///      Any pool revert other than `SimulateSwap` (bid/ask/reference validation, `InvalidAmount`, extension rejections,
///      ...) is rethrown as `WrappedError`; the pool validates live and hypothetical prices alike. Live quotes call the
///      price provider's `getQuote` directly, so provider reverts bubble raw (not as the pool's `PriceProviderFailed`).
///      A `priceLimitX64` of 0 or `type(uint128).max` is treated as open in either direction.
///      Multihop exact-input walks `pools` forward; prior hop output becomes next hop input. Multihop exact-output walks
///      `pools` backward; prior hop input becomes next hop output. Multihop paths use open per-hop price limits.
///      Live quotes revert with `PoolPaused` for any pool whose pause level is non-zero, mirroring `swap`; the pool's
///      `simulateSwapAndRevert` skips the pause check. Hypothetical quotes do not check pause state.
interface IMetricOmmSwapQuoter {
  // ============ Errors ============

  /// @notice Wrapped non-`SimulateSwap` revert from `simulateSwapAndRevert`.
  error WrappedError(address target, bytes4 selector, bytes reason);
  /// @notice simulateSwapAndRevert completed without SimulateSwap revert.
  error QuoteDidNotRevert();
  /// @notice Pool has neither mutable nor immutable price provider configured.
  error InvalidPriceProvider();
  /// @notice Live quote requested for a pool whose pause level is non-zero, so `swap` would revert.
  error PoolPaused(address pool, uint8 pauseLevel);
  /// @notice Provided or intermediate hop amount does not fit in int128.
  error AmountTooLarge(uint128 amount);
  /// @notice Simulated deltas are not one positive (input) and one negative (output) amount for the swap direction.
  error InvalidSwapDeltas();
  /// @notice Route arrays are inconsistent, pools are not token-connected, `pools` is empty or longer than 256 pools,
  ///         or (hypothetical quotes) a price array length differs from `pools`.
  error InvalidPath();
  /// @notice Multihop exact-input hop consumed less input than requested (partial fill).
  error InvalidInputAmountAtHop(uint8 hop, uint256 amountIn, uint256 expectedAmountIn);
  /// @notice Exact-output hop output does not match the requested hop amount.
  error InvalidOutputAmountAtHop(uint8 hop, uint256 amountOut, uint256 expectedAmountOut);

  // ============ Types ============

  /// @notice Multihop live exact-input quote parameters.
  /// @param pools Pool for each hop in order; length must be 1 to 256.
  /// @param extensionDatas Extension payload per pool; length must match `pools`.
  /// @param zeroForOneBitMap Bit `i` is the swap direction for `pools[i]`.
  /// @param amountIn Exact input amount for the first hop (native units).
  struct QuoteExactInputParams {
    address[] pools;
    bytes[] extensionDatas;
    uint256 zeroForOneBitMap;
    uint128 amountIn;
  }

  /// @notice Multihop live exact-output quote parameters.
  /// @param pools Pool for each hop in order; length must be 1 to 256.
  /// @param extensionDatas Extension payload per pool; length must match `pools`.
  /// @param zeroForOneBitMap Bit `i` is the swap direction for `pools[i]`.
  /// @param amountOut Exact output amount for the final hop (native units).
  struct QuoteExactOutputParams {
    address[] pools;
    bytes[] extensionDatas;
    uint256 zeroForOneBitMap;
    uint128 amountOut;
  }

  /// @notice Multihop hypothetical exact-input quote parameters.
  /// @param pools Pool for each hop in order; length must be 1 to 256.
  /// @param extensionDatas Extension payload per pool; length must match `pools`.
  /// @param zeroForOneBitMap Bit `i` is the swap direction for `pools[i]`.
  /// @param amountIn Exact input amount for the first hop (native units).
  /// @param bidPricesX64 Hypothetical bid price per pool; length must match `pools`.
  /// @param askPricesX64 Hypothetical ask price per pool; length must match `pools`.
  /// @param referencePricesX64 Hypothetical reference/mid per pool; length must match `pools`.
  struct QuoteHypotheticalExactInputParams {
    address[] pools;
    bytes[] extensionDatas;
    uint256 zeroForOneBitMap;
    uint128 amountIn;
    uint128[] bidPricesX64;
    uint128[] askPricesX64;
    uint128[] referencePricesX64;
  }

  /// @notice Multihop hypothetical exact-output quote parameters.
  /// @param pools Pool for each hop in order; length must be 1 to 256.
  /// @param extensionDatas Extension payload per pool; length must match `pools`.
  /// @param zeroForOneBitMap Bit `i` is the swap direction for `pools[i]`.
  /// @param amountOut Exact output amount for the final hop (native units).
  /// @param bidPricesX64 Hypothetical bid price per pool; length must match `pools`.
  /// @param askPricesX64 Hypothetical ask price per pool; length must match `pools`.
  /// @param referencePricesX64 Hypothetical reference/mid per pool; length must match `pools`.
  struct QuoteHypotheticalExactOutputParams {
    address[] pools;
    bytes[] extensionDatas;
    uint256 zeroForOneBitMap;
    uint128 amountOut;
    uint128[] bidPricesX64;
    uint128[] askPricesX64;
    uint128[] referencePricesX64;
  }

  // ============ Live quotes: single hop ============

  /// @notice Quote single-hop exact-input swap using live pool prices.
  function quoteLiveExactInSingle(
    address pool,
    address sender,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64
  ) external returns (uint256 quotedAmountIn, uint256 quotedAmountOut);

  /// @notice Quote with explicit sender, recipient, and extension context.
  /// @dev A zero sender defaults to msg.sender.
  function quoteLiveExactInSingle(
    address pool,
    address sender,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    bytes memory extensionData
  ) external returns (uint256 quotedAmountIn, uint256 quotedAmountOut);

  /// @notice Quote single-hop exact-output swap using live pool prices.
  function quoteLiveExactOutSingle(
    address pool,
    address sender,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64
  ) external returns (uint256 quotedAmountIn, uint256 quotedAmountOut);

  /// @notice Quote with explicit sender, recipient, and extension context.
  /// @dev A zero sender defaults to msg.sender.
  function quoteLiveExactOutSingle(
    address pool,
    address sender,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    bytes memory extensionData
  ) external returns (uint256 quotedAmountIn, uint256 quotedAmountOut);

  // ============ Live quotes: multihop ============

  /// @notice Quote every hop using the supplied sender for swap extensions.
  /// @dev A zero sender defaults to msg.sender.
  function quoteLiveExactIn(address sender, QuoteExactInputParams calldata params)
    external
    returns (uint256 quotedAmountIn, uint256 quotedAmountOut);

  /// @notice Quote every hop using the supplied sender for swap extensions.
  /// @dev A zero sender defaults to msg.sender.
  function quoteLiveExactOut(address sender, QuoteExactOutputParams calldata params)
    external
    returns (uint256 quotedAmountIn, uint256 quotedAmountOut);

  // ============ Hypothetical quotes: single hop ============

  /// @notice Quote single-hop exact-input swap at caller-supplied bid/ask/reference prices.
  /// @dev Uses msg.sender as recipient and empty extensionData; use the overload when extensions gate on those fields.
  ///      Use the geometric mid `sqrt(bid * ask)` for `referencePriceX64`; the pool enforces its configured
  ///      bid/ask/reference asymmetry bound as well as price ordering.
  function quoteHypotheticalExactInputSingle(
    address pool,
    address sender,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64
  ) external returns (uint256 quotedAmountIn, uint256 quotedAmountOut);

  /// @notice Quote with explicit sender, recipient, and extension context.
  /// @dev A zero sender defaults to msg.sender.
  function quoteHypotheticalExactInputSingle(
    address pool,
    address sender,
    address recipient,
    bool zeroForOne,
    uint128 amountIn,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64,
    bytes memory extensionData
  ) external returns (uint256 quotedAmountIn, uint256 quotedAmountOut);

  /// @notice Quote single-hop exact-output swap at caller-supplied bid/ask/reference prices.
  /// @dev Uses msg.sender as recipient and empty extensionData; use the overload when extensions gate on those fields.
  function quoteHypotheticalExactOutputSingle(
    address pool,
    address sender,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64
  ) external returns (uint256 quotedAmountIn, uint256 quotedAmountOut);

  /// @notice Quote with explicit sender, recipient, and extension context.
  /// @dev A zero sender defaults to msg.sender.
  function quoteHypotheticalExactOutputSingle(
    address pool,
    address sender,
    address recipient,
    bool zeroForOne,
    uint128 amountOutDesired,
    uint128 priceLimitX64,
    uint128 bidPriceX64,
    uint128 askPriceX64,
    uint128 referencePriceX64,
    bytes memory extensionData
  ) external returns (uint256 quotedAmountIn, uint256 quotedAmountOut);

  // ============ Hypothetical quotes: multihop ============

  /// @notice Quote every hop using the supplied sender for swap extensions.
  /// @dev A zero sender defaults to msg.sender.
  function quoteHypotheticalExactInput(address sender, QuoteHypotheticalExactInputParams calldata params)
    external
    returns (uint256 quotedAmountIn, uint256 quotedAmountOut);

  /// @notice Quote every hop using the supplied sender for swap extensions.
  /// @dev A zero sender defaults to msg.sender.
  function quoteHypotheticalExactOutput(address sender, QuoteHypotheticalExactOutputParams calldata params)
    external
    returns (uint256 quotedAmountIn, uint256 quotedAmountOut);
}
