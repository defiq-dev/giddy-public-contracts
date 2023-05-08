//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library GiddyLibraryV2 {
  address constant internal ONE_INCH_ROUTER = 0x1111111254EEB25477B68fb85Ed929f73A960582;

  function oneInchSwap(address srcAccount, address dstAccount, address srcToken, address dstToken, uint amount, bytes calldata data) internal returns (uint returnAmount) {
    if (!IERC20(srcToken).approve(ONE_INCH_ROUTER, amount)) {
      revert("SWAP_APPROVE");
    }
    uint srcBalance = IERC20(srcToken).balanceOf(address(srcAccount));
    uint dstBalance = IERC20(dstToken).balanceOf(address(dstAccount));
    (bool swapResult, bytes memory swaptData) = address(ONE_INCH_ROUTER).call(data);
    if (!swapResult) {
      revert("SWAP_CALL");
    }
    uint spentAmount;
    (returnAmount, spentAmount) = abi.decode(swaptData, (uint, uint));
    require(spentAmount == amount, "SWAP_SPENT");
    require(srcBalance - IERC20(srcToken).balanceOf(srcAccount) == spentAmount, "SWAP_SRC_BALANCE");
    require(IERC20(dstToken).balanceOf(dstAccount) - dstBalance == returnAmount, "SWAP_DST_BALANCE");
  }
}