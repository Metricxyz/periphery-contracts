// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title ISelfPermit
/// @notice Functionality to call permit on any EIP-2612-compliant token for use in the route.
interface ISelfPermit {
  /// @notice Permits this contract to spend a given token from `msg.sender`.
  /// @dev The `owner` is always msg.sender and the `spender` is always address(this).
  function selfPermit(address token, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external payable;

  /// @notice Permits this contract to spend a given token from `msg.sender` when allowance is insufficient.
  /// @dev Can be used instead of selfPermit to prevent calls from failing due to a frontrun of selfPermit.
  ///      Skips the permit when the current allowance is at least `value`.
  function selfPermitIfNecessary(address token, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
    external
    payable;

  /// @notice Permits this contract to spend the sender's tokens for permit signatures that have the `allowed` parameter.
  /// @dev The `owner` is always msg.sender and the `spender` is always address(this).
  function selfPermitAllowed(address token, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s)
    external
    payable;

  /// @notice Permits this contract to spend the sender's tokens for permit signatures that have the `allowed` parameter.
  /// @dev Can be used instead of selfPermitAllowed to prevent calls from failing due to a frontrun of selfPermitAllowed.
  ///      Skips the permit when the current allowance is already `type(uint256).max`.
  function selfPermitAllowedIfNecessary(address token, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s)
    external
    payable;
}
