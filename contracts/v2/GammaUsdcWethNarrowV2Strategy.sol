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
import "./libraries/GiddyLibraryV2.sol";

contract GammaUsdcWethNarrowV2Strategy is GiddyStrategyV2, Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable {
  uint256 constant private COMPOUND_THRESHOLD_WMATIC = 1e14;
  uint256 constant private COMPOUND_THRESHOLD_DQUICK = 1e17;
  uint256 constant private COMPOUND_THRESHOLD_QUICK = 1e17;
  uint256 constant private PID = 4;
  address constant private UNI_PROXY = 0xe0A61107E250f8B5B24bf272baBFCf638569830C;
  address constant private MASTER_CHEF = 0x20ec0d06F447d550fC6edee42121bc8C1817b97D;
  address constant private USDC_TOKEN = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
  address constant private WETH_TOKEN = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
  address constant private WMATIC_TOKEN = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
  address constant private QUICK_TOKEN = 0xB5C064F955D8e7F38fE0460C556a72987494eE17;
  address constant private QUICK_REWARDER = 0x158B99aE660D4511e4c52799e1c47613cA47a78a;
  address constant private DQUICK_TOKEN_AND_LAIR = 0x958d208Cdf087843e9AD98d23823d32E17d723A1;
  address constant private QUICK_ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
  address constant private USDC_WETH_POS = 0x3Cc20A6795c4b57d9817399F68E83e71C8626580;

  GiddyVaultV2 public vault;

  function initialize(address vaultAddress) public initializer {
    __Ownable_init();
    __ReentrancyGuard_init();
    vault = GiddyVaultV2(vaultAddress);
  }

  function getContractBalance() public view override returns (uint256 amount) {
    (amount,) = IMasterChef(MASTER_CHEF).userInfo(PID, address(this));
  }

  function getContractRewards() public view override returns (uint256[] memory amounts) {
    amounts = new uint256[](2);
    amounts[0] = IERC20(WMATIC_TOKEN).balanceOf(address(this));
    amounts[1] = IERC20(QUICK_TOKEN).balanceOf(address(this));
  }

  function getNeedsCompound() public view override returns (bool[] memory needsCompound) {
    uint256[] memory rewards = getContractRewards();
    needsCompound = new bool[](2);
    needsCompound[0] = rewards[0] >= COMPOUND_THRESHOLD_WMATIC;
    needsCompound[1] = rewards[1] >= COMPOUND_THRESHOLD_QUICK;
  }

  function claimRewards() public override {
    IMasterChef(MASTER_CHEF).deposit(PID, 0, address(this));
    uint value = IERC20(DQUICK_TOKEN_AND_LAIR).balanceOf(address(this));
    if (value > COMPOUND_THRESHOLD_DQUICK) {
      IDragonsLair(DQUICK_TOKEN_AND_LAIR).leave(value);
    }
  }

  function compound(GiddyStrategyV2.SwapInfo[] calldata swaps) external override returns (uint256 staked) {
    require(_msgSender() == address(vault), "FAILED_VAULT_CHECK");
    require(swaps.length >= 2, "SWAP_LENGTH");
    uint256[] memory amounts = new uint256[](2);
    if (swaps[swaps.length - 2].amount > 0) {
      amounts[0] = GiddyLibraryV2.oneInchSwap(address(this), address(this), swaps[swaps.length - 2].srcToken, USDC_TOKEN, swaps[swaps.length - 2].amount, swaps[swaps.length - 2].data);
    }
    if (swaps[swaps.length - 1].amount > 0) {
      amounts[1] = GiddyLibraryV2.oneInchSwap(address(this), address(this), swaps[swaps.length - 1].srcToken, WETH_TOKEN, swaps[swaps.length - 1].amount, swaps[swaps.length - 1].data);
    }
    return stake(amounts);
  }

  function deposit(uint256[] memory amounts) external override nonReentrant returns (uint256 staked) {
    require(_msgSender() == address(vault), "FAILED_VAULT_CHECK");
    return stake(amounts);
  }

  function stake(uint256[] memory amounts) private returns (uint256 staked) {
    if (!IERC20(USDC_TOKEN).approve(USDC_WETH_POS, amounts[0])) {
      revert("LP_USDC_APPROVE");
    }
    if (!IERC20(WETH_TOKEN).approve(USDC_WETH_POS, amounts[1])) {
      revert("LP_WETH_APPROVE");
    }
    staked = IUniProxy(UNI_PROXY).deposit(amounts[0], amounts[1], address(this), USDC_WETH_POS, [uint(0), uint(0), uint(0), uint(0)]);
    if (!IERC20(USDC_WETH_POS).approve(MASTER_CHEF, staked)) {
      revert("STAKE_APPROVE");
    }
    IMasterChef(MASTER_CHEF).deposit(PID, staked, address(this));
  }


  function depositNative(uint256 amount) external override nonReentrant returns (uint256 staked) {
    require(_msgSender() == address(vault), "FAILED_VAULT_CHECK");
    if (!IERC20(USDC_WETH_POS).approve(MASTER_CHEF, staked)) {
      revert("STAKE_APPROVE");
    }
    IMasterChef(MASTER_CHEF).deposit(PID, staked, address(this));
    return amount;
  }

  function withdraw(uint256 staked) external override nonReentrant returns (uint256[] memory amounts) {
    require(_msgSender() == address(vault), "FAILED_VAULT_CHECK");
    IMasterChef(MASTER_CHEF).withdraw(PID, staked, address(this));
    if (!IERC20(USDC_WETH_POS).approve(USDC_WETH_POS, staked)) {
      revert("REMOVE_LP_APPROVE");
    }
    amounts = new uint[](2);
    (amounts[0], amounts[1]) = IHypervisor(USDC_WETH_POS).withdraw(staked, address(this), address(this), [uint(0), uint(0), uint(0), uint(0)]);
    if (!IERC20(USDC_TOKEN).transfer(address(vault), amounts[0])) {
      revert("VAULT_TRANSFER_USDC");
    }
    if (!IERC20(WETH_TOKEN).transfer(address(vault), amounts[1])) {
      revert("VAULT_TRANSFER_WETH");
    }
  }
}
