//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./GiddyVaultV2.sol";
import "./libraries/GiddyLibrary.sol";
import "./interfaces/gamma/IUniProxy.sol";
import "./interfaces/gamma/IHypervisor.sol";
import "./libraries/FullMath.sol";
import "./libraries/TickMath.sol";

contract GammaUsdcWethNarrowV2Query is GiddyQueryV2, Initializable, OwnableUpgradeable {
  uint256 constant private RATIO_PERCENT = 1e18;
  address constant private UNI_PROXY = 0xe0A61107E250f8B5B24bf272baBFCf638569830C;
  address constant private USDC_TOKEN = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
  address constant private WETH_TOKEN = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
  address constant private WMATIC_TOKEN = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
  address constant private QUICK_TOKEN = 0xB5C064F955D8e7F38fE0460C556a72987494eE17;
  address constant private USDC_WETH_POS = 0x3Cc20A6795c4b57d9817399F68E83e71C8626580;

  GiddyVaultV2 public vault;

  function initialize(address vaultAddress) public initializer {
    __Ownable_init();
    vault = GiddyVaultV2(vaultAddress);
  }

  function getNativeToken() external pure override returns (address token) {
    token = USDC_WETH_POS;
  }

  function getRewardTokens() external pure override returns (address[] memory tokens) {
    tokens = new address[](2);
    tokens[0] = WMATIC_TOKEN;
    tokens[1] = QUICK_TOKEN;
  }

  function getDepositTokens() external pure override returns (address[] memory tokens) {
    tokens = new address[](2);
    tokens[0] = USDC_TOKEN;
    tokens[1] = WETH_TOKEN;
  }

  function getDepositRatios() external view override returns (uint256[] memory ratios) {
    ratios = new uint256[](2);
    (ratios[0], ratios[1]) = IUniProxy(UNI_PROXY).getDepositAmount(USDC_WETH_POS, USDC_TOKEN, 1000e6);
    ratios[1] = (ratios[0] + ratios[1]) / 2;
    ratios[0] = (1000e18 * RATIO_PERCENT) / (1000e18 + ratios[1]);
    ratios[1] = (ratios[1] * RATIO_PERCENT) / (1000e18 + ratios[1]);    
  }

  function getWithdrawTokens() external pure override returns (address[] memory tokens) {
    tokens = new address[](2);
    tokens[0] = USDC_TOKEN;
    tokens[1] = WETH_TOKEN;
  }

  function getWithdrawAmounts(uint256 staked) external view override returns (uint256[] memory amounts) {
    amounts = new uint256[](2);
    (amounts[0], amounts[1]) = calcTokens(USDC_WETH_POS, staked);
  }

  function calcTokens(address pos, uint256 shares) private view returns (uint256 withdraw0, uint256 withdraw1) {
    IHypervisor hypervisor = IHypervisor(pos);
    (withdraw0, withdraw1) = hypervisor.getTotalAmounts();
    uint totalSupply = hypervisor.totalSupply();
    withdraw0 = (withdraw0 * shares) / totalSupply;
    withdraw1 = (withdraw1 * shares) / totalSupply;
  }
}
