//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import "./GiddyVaultV2.sol";
import "./interfaces/gamma/IUniProxy.sol";
import "./interfaces/gamma/IHypervisor.sol";

contract AaveUsdcV2Query is GiddyQueryV2, Initializable, OwnableUpgradeable {
  uint256 constant private RATIO_PERCENT = 1e18;
  address constant private USDC_TOKEN = 0x12eb2270c193ddc890350015bcadec414282383b;
  address constant private AM_USDC_TOKEN = 0xa4d94019934d8333ef880abffbf2fdd611c762bd;

  GiddyVaultV2 public vault;

  function initialize(address vaultAddress) public initializer {
    __Ownable_init();
    vault = GiddyVaultV2(vaultAddress);
  }

  function getNativeToken() external pure override returns (address token) {
    token = AM_USDC_TOKEN;
  }

  function getRewardTokens() external pure override returns (address[] memory tokens) {
    tokens = new address[](0);
  }

  function getDepositTokens() external pure override returns (address[] memory tokens) {
    tokens = new address[](1);
    tokens[0] = USDC_TOKEN;
  }

  function getDepositRatios() external view override returns (uint256[] memory ratios) {
    ratios = new uint256[](1);
    ratios[0] = RATIO_PERCENT;
  }

  function getWithdrawTokens() external pure override returns (address[] memory tokens) {
    tokens = new address[](1);
    tokens[0] = USDC_TOKEN;
  }

  function getWithdrawAmounts(uint256 staked) external view override returns (uint256[] memory amounts) {
    amounts = new uint256[](1);
    amounts[0] = staked;
  }
}
