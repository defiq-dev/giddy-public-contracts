//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ApproveWithAuthorization.sol";
import "./GiddyConfigYA.sol";

contract GiddyFarm is ReentrancyGuardUpgradeable, OwnableUpgradeable, PausableUpgradeable, ERC2771ContextUpgradeable {
  struct User {
    uint amount;
    uint debt;
    uint pending;
  }

  uint256 constant internal BASE_PERCENT = 1e6;
  uint256 constant internal WEIGHT = 1e30;
  address constant internal GIDDY_TOKEN = 0x67eB41A14C0fe5CD701FC9d5A3D6597A72F641a6;
  uint private remainingRewards;
  uint public accumulatedRewards;
  uint public lastUpdate;

  GiddyConfigYA public config;
  address public rewardToken;
  uint public rewardsPerSecond;
  mapping (address => User) public users;

  event Deposit(address indexed account, uint amount, uint fap);
  event Withdraw(address indexed account, uint amount, uint fap);
  event Harvest(address indexed account, uint amount);

  function initialize(address trustedForwarder, address configAddress, address token) public initializer {
    __Ownable_init();
    __Pausable_init();
    __ReentrancyGuard_init();
    __ERC2771Context_init(trustedForwarder);
    config = GiddyConfigYA(configAddress);
    rewardToken = token;
    lastUpdate = block.timestamp;
  }

  function _msgSender() internal view virtual override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (address sender) {
    return ERC2771ContextUpgradeable._msgSender();
  }

  function _msgData() internal view virtual override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (bytes calldata) {
    return ERC2771ContextUpgradeable._msgData();
  }

  function contractRewards() external view returns(uint remainingAmount, uint remainingSeconds) {
    remainingAmount = remainingRewards;
    if (block.timestamp > lastUpdate && IERC20(GIDDY_TOKEN).balanceOf(address(this)) > 0) {
      uint newRewards = (block.timestamp - lastUpdate) * rewardsPerSecond;
      if (newRewards < remainingRewards) remainingAmount -= newRewards;
      else remainingAmount = 0;
    }
    if (rewardsPerSecond > 0) remainingSeconds = remainingAmount / rewardsPerSecond;
  }

  function apyInfo() external view returns(uint staked, uint currentRewardsPerSecond) {
    staked = IERC20(GIDDY_TOKEN).balanceOf(address(this));
    if (staked > 0 && remainingRewards > 0) {
      currentRewardsPerSecond = rewardsPerSecond;
    }
  }

  function userStaked(address account) external view returns (uint amount) {
    return users[account].amount;
  }

  function userRewards(address account) external view returns (uint amount) {
    uint staked = IERC20(GIDDY_TOKEN).balanceOf(address(this));
    User memory user = users[account];
    amount = user.pending;
    if (block.timestamp > lastUpdate && user.amount > 0) {
      uint newRewards = (block.timestamp - lastUpdate) * rewardsPerSecond;
      if (newRewards > remainingRewards) newRewards = remainingRewards;
      newRewards = accumulatedRewards + ((newRewards * WEIGHT) / staked);
      amount += ((user.amount * newRewards) / WEIGHT) - user.debt;
    }
    amount -= amount * config.earningsFee() / BASE_PERCENT;
  }

  function deposit(ApproveWithAuthorization.ApprovalRequest calldata giddyAuth, bytes calldata giddySig, uint fap) external whenNotPaused nonReentrant {
    require(giddyAuth.spender == address(this) && giddyAuth.owner == _msgSender());
    ApproveWithAuthorization(GIDDY_TOKEN).approveWithAuthorization(giddyAuth, giddySig);
    updateFarm();
    SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(GIDDY_TOKEN), giddyAuth.owner, address(this), giddyAuth.value);
    uint256 amount = deductFee(GIDDY_TOKEN, giddyAuth.value, fap);
    User storage user = users[_msgSender()];
    user.pending += ((user.amount * accumulatedRewards) / WEIGHT) - user.debt;
    user.amount += amount;
    user.debt = (((user.amount) * accumulatedRewards) / WEIGHT);
    emit Deposit(_msgSender(), giddyAuth.value, fap);
  }

  function withdraw(uint256 amount, uint256 fap) external nonReentrant {
    require(amount > 0, "ZERO_AMOUNT");
    User storage user = users[_msgSender()];
    require(amount <= user.amount, "AMOUNT_EXCEEDS_OWNED");
    updateFarm();
    user.pending += ((user.amount * accumulatedRewards) / WEIGHT) - user.debt;
    user.amount -= amount;
    user.debt = (((user.amount) * accumulatedRewards) / WEIGHT);
    SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(GIDDY_TOKEN), _msgSender(), deductFee(GIDDY_TOKEN, amount, fap));
    emit Withdraw(_msgSender(), amount, fap);
  }

  function harvest(uint fap) external whenNotPaused nonReentrant {
    updateFarm();
    User storage user = users[_msgSender()];
    uint amount = user.pending + ((user.amount * accumulatedRewards) / WEIGHT) - user.debt;
    amount = deductFee(rewardToken, amount, fap);
    if (amount > 0) {
      amount = deductFee(rewardToken, amount, amount * config.earningsFee() / BASE_PERCENT);
      SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(rewardToken), _msgSender(), amount);
      user.debt = (((user.amount) * accumulatedRewards) / WEIGHT);
      user.pending = 0;
      emit Harvest(_msgSender(), amount);
    }
  }

  function updateFarm() private {
    if (block.timestamp <= lastUpdate) {
      return;
    }
    uint staked = IERC20(GIDDY_TOKEN).balanceOf(address(this));
    if (staked > 0) {
      uint elapsedSeconds = block.timestamp - lastUpdate;
      uint newRewards = elapsedSeconds * rewardsPerSecond;
      if (newRewards > remainingRewards) {
        accumulatedRewards += ((remainingRewards * WEIGHT) / staked);
        remainingRewards = 0;
      }
      else {
        accumulatedRewards += ((newRewards * WEIGHT) / staked);
        remainingRewards -= newRewards;
      }
    }
    lastUpdate = block.timestamp;
  }

  function addRewards(uint amount) external onlyOwner {
    require(amount > 0, "ZERO_AMOUNT");
    updateFarm();
    remainingRewards += amount;
    SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(rewardToken), _msgSender(), address(this), amount);
  }

  function removeRewards(uint amount) external onlyOwner {
    require(amount > 0, "ZERO_AMOUNT");
    updateFarm();
    require(amount <= remainingRewards, "AMOUNT_EXCEEDS_REMAINING");
    remainingRewards -= amount;
    SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(rewardToken), _msgSender(), amount);
  }

  function setRewardsPerSecond(uint value) external onlyOwner {
    updateFarm();
    rewardsPerSecond = value;
  }

  function setConfig(address configAddress) public onlyOwner {
    config = GiddyConfigYA(configAddress);
  }

  function deductFee(address token, uint amount, uint fap) private returns (uint) {
    if (fap > 0) {
      require(fap < amount, "FEE_AMOUNT");
      SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(token), config.feeAccount(), fap);
    }
    return amount - fap;
  }
}