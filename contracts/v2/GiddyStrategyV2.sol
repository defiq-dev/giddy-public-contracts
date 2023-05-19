//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "./libraries/GiddyLibraryV2.sol";

abstract contract GiddyStrategyV2 {
  function getContractBalance() public view virtual returns (uint256 amount);
  function getContractRewards() public view virtual returns (uint256[] memory amounts);
  function getNeedsCompound() public view virtual returns (bool needsCompound);
  function claimRewards() external virtual;
  function compound(SwapInfo[] calldata swaps) external virtual returns (uint256 staked);
  function deposit(uint256[] calldata amounts) external virtual returns (uint256 staked);
  function depositNative(uint256 amount) external virtual returns (uint256 staked);
  function withdraw(uint256 staked) external virtual returns (uint256[] memory amounts);
}