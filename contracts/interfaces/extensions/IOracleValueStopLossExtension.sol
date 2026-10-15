// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IOracleValueStopLossExtension
/// @notice Per-pool oracle value stop-loss admin, read API, and timelocked parameter updates.
interface IOracleValueStopLossExtension {
  /// @dev Per-share metrics in 1e18-scaled bin units, decayed lazily from `lastDecayTs`.
  struct BinHighWatermarks {
    uint104 token0;
    uint104 token1;
    uint40 lastDecayTs;
  }

  /// @dev `drawdownE6`: 1e6 = 100%, 0 disables the check. `decayPerSecondE18`: 1e18 = 100%/s, 0 disables decay.
  ///      `timelock`: seconds applied to every proposal.
  struct PoolStopLossConfig {
    uint32 drawdownE6;
    uint64 decayPerSecondE18;
    uint40 timelock;
    bool initialized;
  }

  /// @dev `*ExecuteAfter == 0` means nothing is pending.
  struct PoolStopLossSchedule {
    uint40 pendingTimelock;
    uint40 pendingTimelockExecuteAfter;
    uint32 pendingDrawdownE6;
    uint40 pendingDrawdownExecuteAfter;
    uint64 pendingDecayPerSecondE18;
    uint40 pendingDecayExecuteAfter;
  }

  /// @dev One pending proposal per pool; `executeAfter == 0` means nothing is pending.
  struct PendingHighWatermarks {
    uint104 token0;
    uint104 token1;
    int16 binIdx;
    uint40 executeAfter;
  }

  /// @notice The swap direction's per-share metric fell below `threshold` (decayed watermark * (1e6 - drawdownE6) / 1e6).
  error OracleStopLossTriggered(int16 binIdx, bool isToken0Metric, uint256 currentMetric, uint256 threshold);
  /// @notice Drawdown above 1e6 (100%).
  error OracleStopLossDrawdownTooLarge(uint256 requested);
  /// @notice Decay above 1e18 per second (100%).
  error OracleStopLossDecayTooLarge(uint256 requested);
  error OracleStopLossAlreadyInitialized(address pool);
  error OracleStopLossNotInitialized(address pool);
  error OracleStopLossNoPendingDrawdown(address pool);
  error OracleStopLossNoPendingDecay(address pool);
  error OracleStopLossNoPendingTimelock(address pool);
  error OracleStopLossNoPendingHighWatermark(address pool);
  error OracleStopLossTimelockNotElapsed(uint256 executeAfter, uint256 currentTime);
  /// @notice `block.timestamp + timelock` does not fit in `uint40` (would wrap a deadline into the past).
  error OracleStopLossTimelockOverflow(uint256 executeAfter);

  event OracleStopLossTimelockProposed(address indexed pool, uint256 proposedTimelock, uint256 executeAfter);
  event OracleStopLossTimelockSet(address indexed pool, uint256 newTimelock);
  event OracleStopLossTimelockCancelled(address indexed pool);
  event OracleStopLossDrawdownProposed(address indexed pool, uint256 proposedDrawdownE6, uint256 executeAfter);
  event OracleStopLossDrawdownSet(address indexed pool, uint256 newMaxDrawdownE6);
  event OracleStopLossDrawdownCancelled(address indexed pool);
  event OracleStopLossDecayProposed(address indexed pool, uint256 proposedDecayPerSecondE18, uint256 executeAfter);
  event OracleStopLossDecaySet(address indexed pool, uint256 newDecayPerSecondE18);
  event OracleStopLossDecayCancelled(address indexed pool);
  event OracleStopLossHighWatermarkProposed(
    address indexed pool, int16 binIdx, uint104 proposedHwmToken0, uint104 proposedHwmToken1, uint256 executeAfter
  );
  event OracleStopLossHighWatermarkUpdated(
    address indexed pool, int16 binIdx, uint104 newHwmToken0, uint104 newHwmToken1
  );
  event OracleStopLossHighWatermarkCancelled(address indexed pool);

  /// @notice Factory only, once per pool. `data` = `abi.encode(uint32 drawdownE6, uint64 decayPerSecondE18, uint40 timelock)`;
  ///         applied immediately.
  function initialize(address pool, bytes calldata data) external returns (bytes4);

  /// @notice Watermarks after lazy decay up to `block.timestamp`; what the next check compares against.
  function currentHighWatermarks(address pool, int16 binIdx) external view returns (uint256 hwm0, uint256 hwm1);

  /// @notice Pool admin only. Propose/execute/cancel for timelock, drawdown, decay and high watermarks: a proposal becomes
  ///         executable after the current timelock; a new proposal replaces a pending one of the same kind; cancel is immediate.
  function proposeOracleStopLossTimelock(address pool, uint40 newTimelock) external;

  function executeOracleStopLossTimelock(address pool) external;

  function cancelOracleStopLossTimelock(address pool) external;

  /// @param newMaxDrawdownE6 1e6 = 100%; 0 disables the check.
  function proposeOracleStopLossDrawdown(address pool, uint256 newMaxDrawdownE6) external;

  function executeOracleStopLossDrawdown(address pool) external;

  function cancelOracleStopLossDrawdown(address pool) external;

  /// @param newDecayPerSecondE18 1e18 = 100% per second; 0 disables decay.
  function proposeOracleStopLossDecay(address pool, uint256 newDecayPerSecondE18) external;

  function executeOracleStopLossDecay(address pool) external;

  function cancelOracleStopLossDecay(address pool) external;

  /// @notice Watermarks are in the same 1e18-scaled per-share units as `BinHighWatermarks`; one pending proposal per pool.
  function proposeOracleStopLossHighWatermarks(address pool, int16 binIdx, uint104 newHwmToken0, uint104 newHwmToken1)
    external;

  function executeOracleStopLossHighWatermarks(address pool) external;

  function cancelOracleStopLossHighWatermarks(address pool) external;
}
