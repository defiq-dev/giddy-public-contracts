//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./interfaces/gamma/IUniProxy.sol";
import "./interfaces/gamma/IHypervisor.sol";
import "./interfaces/gamma/IMasterChef.sol";
import "./interfaces/gamma/IRewarder.sol";
import "./interfaces/quick/IDragonsLair.sol";
import "./GiddyVaultV2.sol";

contract GammaWbtcGiddyStrategy is GiddyStrategyV2, Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable {
  uint256 constant private BASE_PERCENT = 1e6;
  uint constant private COMPOUND_THRESHOLD_GIDDY = 10e18;
  uint256 constant private PID = 2;
  address constant private UNI_PROXY = 0xe0A61107E250f8B5B24bf272baBFCf638569830C;
  address constant private MASTER_CHEF = 0x68678Cf174695fc2D27bd312DF67A3984364FFDd;
  address constant private GIDDY_REWARDER = 0x43e867915E4fBf7e3648800bF9bB5A4Bc7A49F37;
  address constant private POS = 0xCbb7FaE80e4F5c0CbFE1Af7bb1f19692f9532Cfa;
  address constant private WBTC_TOKEN = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;
  address constant private GIDDY_TOKEN = 0x67eB41A14C0fe5CD701FC9d5A3D6597A72F641a6;
  
  GiddyVaultV2 public vault;

  function initialize(address vaultAddress) public initializer {
    __Ownable_init();
    __ReentrancyGuard_init();
    vault = GiddyVaultV2(vaultAddress);
  }

  function getContractBalance() public view override returns (uint256 amount) {
    (amount,) = IMasterChef(MASTER_CHEF).userInfo(PID, address(this));
    amount += IERC20(POS).balanceOf(address(this));
  }

  function getContractRewards() public view override returns (uint256[] memory amounts) {
    amounts = new uint256[](2);
    amounts[0] += IRewarder(IMasterChef(MASTER_CHEF).getRewarder(PID, 0)).pendingToken(PID, address(this));
    amounts[0] += IERC20(GIDDY_TOKEN).balanceOf(address(this));
    amounts[1] = COMPOUND_THRESHOLD_GIDDY;
  }

  function claimRewards() external override { }

  function compound(SwapInfo[] calldata swaps) external override onlyVault returns (uint256 staked) {
    require(swaps.length == 2, "SWAP_LENGTH");
    IMasterChef(MASTER_CHEF).deposit(PID, 0, address(this));
    uint256[] memory amounts = new uint256[](2);
    if (swaps[0].amount > 0) {
      amounts[0] += GiddyLibraryV2.routerSwap(vault.config().swapRouter(), swaps[0], address(this), address(this), WBTC_TOKEN);
    }
    if (swaps[1].amount > 0) {
      amounts[1] += swaps[1].amount;
    }
    amounts[0] = deductEarningsFee(WBTC_TOKEN, amounts[0]);
    amounts[1] = deductEarningsFee(GIDDY_TOKEN, amounts[1]);
    return depsoitLP(amounts);
  }

  function deposit(uint256[] memory amounts) external override nonReentrant onlyVault returns (uint256 staked) {
    return depsoitLP(amounts);
  }

  function depositNative(uint256 amount) external override nonReentrant onlyVault returns (uint256 staked) {
    depositChef(amount);
    return amount;
  }

  function withdraw(uint256 staked) external override nonReentrant onlyVault returns (uint256[] memory amounts) {
    uint256 contractBalance = IERC20(POS).balanceOf(address(this));
    if (staked > contractBalance) {
      IMasterChef(MASTER_CHEF).withdraw(PID, staked - contractBalance, address(this));
    }
    if (!IERC20(POS).approve(POS, staked)) {
      revert("REMOVE_LP_APPROVE");
    }
    amounts = new uint[](2);
    (amounts[0], amounts[1]) = IHypervisor(POS).withdraw(staked, address(this), address(this), [uint(0), uint(0), uint(0), uint(0)]);
    if (!IERC20(WBTC_TOKEN).transfer(address(vault), amounts[0])) {
      revert("VAULT_TRANSFER_USDC");
    }
    if (!IERC20(GIDDY_TOKEN).transfer(address(vault), amounts[1])) {
      revert("VAULT_TRANSFER_WETH");
    }
  }

  function moveStrategy(address strategy) external override onlyVault {
    IMasterChef(MASTER_CHEF).emergencyWithdraw(PID, address(this));
    if (!IERC20(POS).transfer(strategy, IERC20(POS).balanceOf(address(this)))) {
      revert("TRANSFER_POS");
    }
  }

  function emergencyWithdraw() external onlyOwner {
    IMasterChef(MASTER_CHEF).emergencyWithdraw(PID, address(this));
  }

  function emergencyDeposit() external onlyOwner {
    depositChef(IERC20(POS).balanceOf(address(this)));
  }

  function depositChef(uint256 amount) private {
    if (!IERC20(POS).approve(MASTER_CHEF, amount)) {
      revert("STAKE_APPROVE");
    }
    IMasterChef(MASTER_CHEF).deposit(PID, amount, address(this));
  }

  function depsoitLP(uint256[] memory amounts) private returns (uint256 staked) {
    if (!IERC20(WBTC_TOKEN).approve(POS, amounts[0])) {
      revert("LP_USDC_APPROVE");
    }
    if (!IERC20(GIDDY_TOKEN).approve(POS, amounts[1])) {
      revert("LP_WETH_APPROVE");
    }
    staked = IUniProxy(UNI_PROXY).deposit(amounts[0], amounts[1], address(this), POS, [uint(0), uint(0), uint(0), uint(0)]);
    depositChef(staked);
  }

  function deductEarningsFee(address token, uint256 amount) private returns (uint256) {
    uint fee = amount * vault.config().earningsFee() / BASE_PERCENT;
    if (fee > 0) {
      if (!ERC20Upgradeable(token).transfer(vault.config().feeAccount(), fee)) {
        revert("FEE_TRANSFER");
      }
    }
    return amount - fee;
  }

  modifier onlyVault() {
    require(_msgSender() == address(vault), "VAULT_CHECK");
    _;
  }
}
