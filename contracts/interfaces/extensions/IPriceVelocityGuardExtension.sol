// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPriceVelocityGuardExtension
/// @notice Per-pool oracle reference-price velocity guard admin API (state is read via the contract's `priceVelocityState`).
interface IPriceVelocityGuardExtension {
  struct PriceVelocityState {
    /// @dev Velocity check reference. Fixed until a swap lands in a block after `lastObservedBlock`.
    uint128 anchorMidPriceX64;
    /// @dev Mid from the latest swap; becomes the next anchor once its block is left behind.
    uint128 lastObservedMidPriceX64;
    /// @dev Block number `anchorMidPriceX64` was observed in; blockDiff is measured from here.
    uint64 anchorBlock;
    /// @dev Block number of the latest swap.
    uint64 lastObservedBlock;
    /// @dev Max relative change per `sqrt(1 + blockDiff)`, 1e18 = 100%; 0 disables the check.
    uint64 maxChangePerBlockE18;
  }

  /// @notice Squared relative change (1e18 = 100%, so E36) exceeded the squared allowance `max^2 * (1 + blockDiff)`.
  error PriceVelocityExceeded(uint256 actualDeltaSqE36, uint256 allowedDeltaSqE36);

  event MaxChangePerBlockSet(address indexed pool, uint64 newMaxPctChangePerBlockE18);
  event AnchorMidPriceUpdated(address indexed pool, uint128 newAnchorMidPriceX64);

  /// @notice Pool admin only; takes effect immediately.
  /// @param newMaxPctChangePerBlockE18 Base allowed change, 1e18 = 100%; 0 disables the check. Not a strict per-block cap:
  ///        the limit is scaled by `sqrt(1 + blockDiff)`, so only a swap in the anchor's own block gets 1x and the
  ///        next block already gets sqrt(2)x.
  function setMaxChangePerBlock(address pool, uint64 newMaxPctChangePerBlockE18) external;

  /// @notice Pool admin only. Resets anchor and last observed price to `newAnchorMidPriceX64` (Q64.64) at the current block;
  ///         0 makes the next swap re-seed the anchor.
  function setAnchorMidPrice(address pool, uint128 newAnchorMidPriceX64) external;
}
