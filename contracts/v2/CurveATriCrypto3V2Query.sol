//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import "./GiddyVaultV2.sol";
import "./interfaces/curve/ICurveCryptoSwap.sol";
import "./interfaces/curve/ICurveCryptoBase.sol";
import "./interfaces/curve/IRewardsGauge.sol";

contract GammaUsdcWethNarrowV2Query is GiddyQueryV2, Initializable, OwnableUpgradeable {
  uint256 constant private RATIO_PERCENT = 1e18;
  address constant private USDC_TOKEN = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
  address constant private AM3CRV_TOKEN = 0xE7a24EF0C5e95Ffb0f6684b813A78F2a3AD7D171;
  address constant private CURVE_POOL = 0x445FE580eF8d70FF569aB36e80c647af338db351;

  GiddyVaultV2 public vault;

  function initialize(address vaultAddress) public initializer {
    __Ownable_init();
    vault = GiddyVaultV2(vaultAddress);
  }

  function getNativeToken() external pure override returns (address token) {
    token = AM3CRV_TOKEN;
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
    amounts[0] = ICurveCryptoFiveWaySwap(CURVE_POOL).calc_withdraw_one_coin(staked, 1);
  }
}
