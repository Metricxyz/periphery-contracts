// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IDepositAllowlistExtension
/// @notice Per-pool deposit allowlist admin and read API.
interface IDepositAllowlistExtension {
  event AllowedToDepositSet(address indexed pool, address indexed depositor, bool allowed);
  event AllowAllDepositorsSet(address indexed pool, bool allowed);

  function allowedDepositor(address pool, address depositor) external view returns (bool);

  function allowAllDepositors(address pool) external view returns (bool);

  /// @notice Pool admin only. `depositor` is matched against the position owner passed to `addLiquidity`.
  function setAllowedToDeposit(address pool, address depositor, bool allowed) external;

  /// @notice Pool admin only. When true, every owner is allowed regardless of the per-address allowlist.
  function setAllowAllDepositors(address pool, bool allowed) external;

  /// @return true if `allowAllDepositors[pool]` or `allowedDepositor[pool][depositor]`.
  function isAllowedToDeposit(address pool, address depositor) external view returns (bool);
}
