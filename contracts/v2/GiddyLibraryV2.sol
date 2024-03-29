//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

struct SwapInfo {
  address srcToken;
  uint256 amount;
  bytes data;
}

library GiddyLibraryV2 {
  function routerSwap(address router, SwapInfo calldata swap, address srcAccount, address dstAccount, address dstToken) internal returns (uint returnAmount) {
    SafeERC20Upgradeable.safeApprove(IERC20Upgradeable(swap.srcToken), router, swap.amount);
    uint srcBalance = IERC20(swap.srcToken).balanceOf(address(srcAccount));
    uint dstBalance = IERC20(dstToken).balanceOf(address(dstAccount));
    (bool swapResult, ) = address(router).call(swap.data);
    if (!swapResult) {
      revert("SWAP_CALL");
    }
    require(srcBalance - IERC20(swap.srcToken).balanceOf(srcAccount) == swap.amount, "SWAP_SRC_BALANCE");
    returnAmount = IERC20(dstToken).balanceOf(dstAccount) - dstBalance;
  }
}