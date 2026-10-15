// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title MetricOmmSwapQuoteDecode
/// @notice Decode swap deltas from deliberate revert payloads.
/// @dev Expects the layout `selector (4 bytes) | int256 amount0Delta | int256 amount1Delta`; the payload length is not checked.
library MetricOmmSwapQuoteDecode {
  /// @return amount0Delta Net token0 delta, truncated to int128 (the pool's `SimulateSwap` deltas fit in int128).
  /// @return amount1Delta Net token1 delta, truncated to int128.
  /// @return matched False (with zero deltas) when `reason` does not start with `expectedSelector`.
  function decodeSwapDeltas(bytes memory reason, bytes4 expectedSelector)
    internal
    pure
    returns (int128 amount0Delta, int128 amount1Delta, bool matched)
  {
    // forge-lint: disable-next-line(unsafe-typecast)
    if (bytes4(reason) != expectedSelector) return (0, 0, false);

    int256 a0;
    int256 a1;
    assembly ("memory-safe") {
      a0 := mload(add(reason, 36))
      a1 := mload(add(reason, 68))
    }
    // forge-lint: disable-next-line(unsafe-typecast)
    amount0Delta = int128(a0);
    // forge-lint: disable-next-line(unsafe-typecast)
    amount1Delta = int128(a1);
    return (amount0Delta, amount1Delta, true);
  }
}
