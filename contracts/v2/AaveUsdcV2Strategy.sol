//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import "./interfaces/aave/IIncentivesController.sol";
import "./interfaces/aave/ILendingPoolV3.sol";
import "./GiddyVaultV2.sol";

contract AaveUsdcV2Strategy is GiddyStrategyV2, Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable {
  uint256 constant private BASE_PERCENT = 1e6;
  address constant private USDC_TOKEN = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
  address constant private AM_USDC_TOKEN = 0xA4D94019934D8333Ef880ABFFbF2FDd611C762BD;
  address constant private LENDING_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
  uint256 constant private COMPOUND_THRESHOLD_USDC = 10e6;

  GiddyVaultV2 public vault;
  uint256 private lastBalance;

  function initialize(address vaultAddress) public initializer {
    __Ownable_init();
    __ReentrancyGuard_init();
    vault = GiddyVaultV2(vaultAddress);
  }

  function getContractBalance() public view override returns (uint256 amount) {
    amount = IERC20(AM_USDC_TOKEN).balanceOf(address(this));
  }

  function getContractRewards() public view override returns (uint256[] memory amounts) {
    amounts = new uint256[](0);
  }

  function compound(SwapInfo[] calldata swaps) external override onlyVault returns (uint256 staked) {
    uint256 earnings = getContractBalance() - lastBalance;
    if (earnings > 0) {
      uint fee = earnings * vault.config().earningsFee() / BASE_PERCENT;
      ILendingPoolV3(LENDING_POOL).withdraw(USDC_TOKEN, fee, address(this));
    }
    uint256 feeBalance = IERC20(USDC_TOKEN).balanceOf(address(this));
    if (feeBalance > COMPOUND_THRESHOLD_USDC) {
      SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(USDC_TOKEN), vault.config().feeAccount(), feeBalance);
    }
    lastBalance = getContractBalance();
    return earnings;
  }

  function deposit(uint256[] memory amounts) external override nonReentrant onlyVault returns (uint256 staked) {
    uint256 balance = IERC20(AM_USDC_TOKEN).balanceOf(address(this));
    SafeERC20Upgradeable.safeApprove(IERC20Upgradeable(USDC_TOKEN), LENDING_POOL, amounts[0]);
    ILendingPoolV3(LENDING_POOL).supply(USDC_TOKEN, amounts[0], address(this), 0);
    staked = IERC20(AM_USDC_TOKEN).balanceOf(address(this)) - balance;
  }

  function depositNative(uint256 amount) external override nonReentrant onlyVault returns (uint256 staked) {
    return amount;
  }

  function withdraw(uint256 staked) external override nonReentrant onlyVault returns (uint256[] memory amounts) {
    amounts = new uint[](1);
    uint256 balance = IERC20(USDC_TOKEN).balanceOf(address(this));
    ILendingPoolV3(LENDING_POOL).withdraw(USDC_TOKEN, amounts[0], address(this));
    amounts[0] = IERC20(USDC_TOKEN).balanceOf(address(this)) - balance;
    SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(USDC_TOKEN), address(vault), amounts[0]);
  }

  function moveStrategy(address strategy) external override onlyVault {
    SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(AM_USDC_TOKEN), strategy, IERC20(AM_USDC_TOKEN).balanceOf(address(this)));
  }

  function emergencyWithdraw() external onlyOwner { }

  function emergencyDeposit() external onlyOwner { }

  modifier onlyVault() {
    require(_msgSender() == address(vault), "VAULT_CHECK");
    _;
  }
}
