//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import "./interfaces/curve/ICurveCryptoSwap.sol";
import "./interfaces/curve/ICurveCryptoBase.sol";
import "./interfaces/curve/IRewardsGauge.sol";
import "./GiddyVaultV2.sol";

contract CurveATriCrypto3V2Strategy is GiddyStrategyV2, Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable {
  uint256 constant private BASE_PERCENT = 1e6;
  address constant private USDC_TOKEN = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
  address constant private AM3CRV_TOKEN = 0xE7a24EF0C5e95Ffb0f6684b813A78F2a3AD7D171;
  address constant private CURVE_POOL = 0x445FE580eF8d70FF569aB36e80c647af338db351;
  uint256 constant private COMPOUND_THRESHOLD_USDC = 10e6;

  GiddyVaultV2 public vault;
  uint256 private lastVirtualPrice;

  function initialize(address vaultAddress) public initializer {
    __Ownable_init();
    __ReentrancyGuard_init();
    vault = GiddyVaultV2(vaultAddress);
    lastVirtualPrice = virtualPrice();
  }

  function getContractBalance() public view override returns (uint256 amount) {
     amount = IERC20(AM3CRV_TOKEN).balanceOf(address(this));
  }

  function getContractRewards() public view override returns (uint256[] memory amounts) {
    amounts = new uint256[](0);
  }

  function compound(SwapInfo[] calldata swaps) external override onlyVault returns (uint256 staked) {
    uint256 contractBalance = getContractBalance();
    uint256 earnings = ((virtualPrice() - lastVirtualPrice) * contractBalance) / 1e18;
    if (earnings > 0) {
      uint fee = earnings * vault.config().earningsFee() / BASE_PERCENT;
      ICurveCryptoFiveWaySwap(CURVE_POOL).remove_liquidity_one_coin(fee, 1, 0);
    }
    uint256 feeBalance = IERC20(USDC_TOKEN).balanceOf(address(this));
    if (feeBalance > COMPOUND_THRESHOLD_USDC) {
      SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(USDC_TOKEN), vault.config().feeAccount(), feeBalance);
    }
    lastVirtualPrice = virtualPrice();
    return earnings;
  }

  function deposit(uint256[] memory amounts) external override nonReentrant onlyVault returns (uint256 staked) {
    SafeERC20Upgradeable.safeApprove(IERC20Upgradeable(USDC_TOKEN), CURVE_POOL, amounts[0]);
    uint256 balance = IERC20(AM3CRV_TOKEN).balanceOf(address(this));
    ICurveCryptoFiveWaySwap(CURVE_POOL).add_liquidity([0,amounts[0],0,0,0], 0);
    staked = IERC20(AM3CRV_TOKEN).balanceOf(address(this)) - balance;
  }

  function depositNative(uint256 amount) external override nonReentrant onlyVault returns (uint256 staked) {
    return amount;
  }

  function withdraw(uint256 staked) external override nonReentrant onlyVault returns (uint256[] memory amounts) {
    amounts = new uint[](1);
    uint256 balance = IERC20(USDC_TOKEN).balanceOf(address(this));
    ICurveCryptoFiveWaySwap(CURVE_POOL).remove_liquidity_one_coin(staked, 1, 0);
    amounts[0] = IERC20(USDC_TOKEN).balanceOf(address(this)) - balance;
    SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(USDC_TOKEN), address(vault), amounts[0]);
  }

  function moveStrategy(address strategy) external override onlyVault {
    SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(AM3CRV_TOKEN), strategy, IERC20(AM3CRV_TOKEN).balanceOf(address(this)));
  }

  function emergencyWithdraw() external onlyOwner { }

  function emergencyDeposit() external onlyOwner { }

  function virtualPrice() private view returns (uint256) {
    return ICurveCryptoBase(CURVE_POOL).get_virtual_price();
  }

  modifier onlyVault() {
    require(_msgSender() == address(vault), "VAULT_CHECK");
    _;
  }
}
