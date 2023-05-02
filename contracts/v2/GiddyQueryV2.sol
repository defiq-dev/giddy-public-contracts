//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

abstract contract GiddyQueryV2 {
  function getNativeToken() external pure virtual returns (address token);
  function getRewardTokens() external pure virtual returns (address[] memory tokens);
  function getDepositTokens() external pure virtual returns (address[] memory tokens);
  function getDepositRatios() external view virtual returns (uint256[] memory ratios);
  function getWithdrawTokens() external pure virtual returns (address[] memory tokens);
  function getWithdrawAmounts(uint256 staked) external view virtual returns (uint256[] memory amounts);
}