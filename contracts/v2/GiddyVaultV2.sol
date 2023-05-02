//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./interfaces/IEIP3009.sol";
import "./ApproveWithAuthorization.sol";
import "./GiddyStrategyV2.sol";
import "./GiddyQueryV2.sol";
import "./GiddyConfigYA.sol";

contract GiddyVaultV2 is ReentrancyGuardUpgradeable, OwnableUpgradeable, PausableUpgradeable, ERC2771ContextUpgradeable {
  using SafeERC20Upgradeable for ERC20Upgradeable;
  uint256 constant internal INIT_SHARES = 1e10;
  uint256 constant internal BASE_PERCENT = 1e6;
  address constant internal ONE_INCH_ROUTER = 0x1111111254EEB25477B68fb85Ed929f73A960582;
  address constant internal USDC_TOKEN = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
  address constant internal GIDDY_TOKEN = 0x67eB41A14C0fe5CD701FC9d5A3D6597A72F641a6;
  address constant internal GIDDY_USDC_PAIR = 0xDE990994309BC08E57aca82B1A19170AD84323E8;

  mapping(address => uint256) private userShares;
  uint256 private contractShares;
  GiddyStrategyV2 public strategy;
  GiddyQueryV2 public query;
  GiddyConfigYA public config;
  uint256 private lastCompoundTime;

  event Deposit(address indexed from, uint256 fap, address token, uint256 amount, uint256 shares);
  event DepositExact(address indexed from, address fapToken, uint256 fapAmount, uint256[] amounts, uint256 shares);
  event Withdraw(address indexed from, uint256 fap, uint8 fapIndex, uint256 shares, uint256[] amounts);
  event CompoundV2(uint256 staked, uint256 contractBalance, uint256 contractShares, uint256 lastCompoundTime);
  event SwapCall(address srcToken, uint inputAmount, uint returnAmount, uint spentAmount);

  function initialize(address trustedForwarder, address configAddress) public initializer {
    __Ownable_init();
    __Pausable_init();
    __ReentrancyGuard_init();
    __ERC2771Context_init(trustedForwarder);
    config = GiddyConfigYA(configAddress);
    lastCompoundTime = block.timestamp;
  }

  function _msgSender() internal view virtual override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (address sender) {
    return ERC2771ContextUpgradeable._msgSender();
  }

  function _msgData() internal view virtual override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (bytes calldata) {
    return ERC2771ContextUpgradeable._msgData();
  }

  function getContractShares() public view returns (uint256 shares) {
    return contractShares;
  }

  function getContractBalance() public view returns (uint256 amount) {
    return strategy.getContractBalance();
  }

  function getContractRewards() public view returns (uint256[] memory amounts) {
    return strategy.getContractRewards();
  }

  function getNeedsCompound() public view returns (bool[] memory needsCompound) {
    return strategy.getNeedsCompound();
  }

  function getUserShares(address user) public view returns (uint256 shares) {
    return userShares[user];
  }

  function getUserBalance(address user) public view returns (uint256 amount) {
    return sharesToValue(getUserShares(user));
  }

  function sharesToValue(uint256 shares) public view returns (uint256 amount) {
    if (contractShares == 0) return 0;
    return getContractBalance() * shares / contractShares;
  }

  function getNativeToken() external view returns (address token) {
    return query.getNativeToken();
  }

  function getRewardTokens() external view returns (address[] memory tokens) {
    return query.getRewardTokens(); 
  }

  function getDepositTokens() external view returns (address[] memory tokens) {
    return query.getDepositTokens(); 
  }

  function getDepositRatios() external view returns (uint256[] memory ratios) {
    return query.getDepositRatios(); 
  }

  function getWithdrawTokens() external view returns (address[] memory tokens) {
    return query.getWithdrawTokens(); 
  }

  function getWithdrawAmounts(uint256 shares) external view returns (uint256[] memory amounts) {
    return query.getWithdrawAmounts(sharesToValue(shares));
  }

  function compound(GiddyStrategyV2.SwapInfo[] calldata swaps) public whenNotPaused {
    uint staked = strategy.compound(swaps);
    if (staked > 0) {
      emit CompoundV2(staked, getContractBalance(), getContractShares(), lastCompoundTime);
      lastCompoundTime = block.timestamp;
    }
  }
  

  function depositExact(uint256[] calldata amounts, address fapToken, uint256 fapAmount) external whenNotPaused nonReentrant {
    strategy.claimRewards();
    if (fapAmount > 0) {
       SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(fapToken), config.feeAccount(), fapAmount);
    }
    address[] memory depositTokens = query.getDepositTokens();
    for (uint8 i; i < depositTokens.length; i++) {
      if (amounts[i] > 0) {
        SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(depositTokens[i]), _msgSender(), address(strategy), amounts[i]);
      }
    }
    uint256 staked = strategy.deposit(amounts);
    uint256 shares = contractShares == 0 ? staked * INIT_SHARES : staked * contractShares / (getContractBalance() - staked);
    userShares[_msgSender()] += shares;
    contractShares += shares;
    emit DepositExact(_msgSender(), fapToken, fapAmount, amounts, shares);
  }

  function depositNative(uint256 amount, uint256 fap) external whenNotPaused nonReentrant {
    strategy.claimRewards();
    address nativeToken = query.getNativeToken();
    SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(nativeToken), _msgSender(), address(strategy), amount);
    amount = deductFee(nativeToken, amount, fap);
    uint256 staked = strategy.depositNative(amount);
    uint256 shares = contractShares == 0 ? staked * INIT_SHARES : staked * contractShares / (getContractBalance() - staked);
    userShares[_msgSender()] += shares;
    contractShares += shares;
    emit Deposit(_msgSender(), fap, nativeToken, amount, shares);
  }

  function depositSingle(address token, uint256 amount, uint256 fap, GiddyStrategyV2.SwapInfo[] calldata swaps) external whenNotPaused nonReentrant {
    strategy.claimRewards();
    SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(token), _msgSender(), address(this), amount);
    deductFee(token, amount, fap);
    uint256 shares = joinStrategy(_msgSender(), swaps);
    emit Deposit(_msgSender(), fap, token, amount, shares);
  }

  function depositUsdc(bytes calldata auth, uint256 fap, GiddyStrategyV2.SwapInfo[] calldata swaps) external whenNotPaused nonReentrant {
    (address owner, address spender, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) = abi.decode(
      auth,
      (address, address, uint256, uint256, uint256, bytes32, uint8, bytes32, bytes32)
    );   
    require(spender == address(this), "AUTH_SPENDER");
    require(owner == _msgSender(), "AUTH_OWNER");

    IEIP3009(USDC_TOKEN).approveWithAuthorization(owner, spender, value, validAfter, validBefore, nonce, v, r, s);
    if (!IERC20Upgradeable(USDC_TOKEN).transferFrom(owner, address(this), value)) {
      revert("VAULT_ONE_STEP");
    }

    deductFee(USDC_TOKEN, value, fap);
    uint256 shares = joinStrategy(owner, swaps);
    emit Deposit(_msgSender(), fap, USDC_TOKEN, value, shares);
  }

  function depositGiddy(ApproveWithAuthorization.ApprovalRequest calldata req, bytes calldata sig, uint256 fap, GiddyStrategyV2.SwapInfo[] calldata swaps) external whenNotPaused nonReentrant {
    require(req.spender == address(this), "AUTH_SPENDER");
    require(req.owner == _msgSender(), "AUTH_OWNER");
  
    ApproveWithAuthorization(GIDDY_TOKEN).approveWithAuthorization(req, sig);
    if (!IERC20Upgradeable(GIDDY_TOKEN).transferFrom(req.owner, address(this), req.value)) {
      revert("VAULT_ONE_STEP");
    }

    deductFee(GIDDY_TOKEN, req.value, fap);
    uint256 shares = joinStrategy(req.owner, swaps);
    emit Deposit(_msgSender(), fap, GIDDY_TOKEN, req.value, shares);
  }

  function joinStrategy(address user, GiddyStrategyV2.SwapInfo[] calldata swaps) private returns (uint256 shares) {
    strategy.claimRewards();
    address[] memory depositTokens = query.getDepositTokens();
    uint256[] memory amounts = new uint256[](depositTokens.length);
    require(swaps.length >= depositTokens.length, "SWAP_LENGTH");
    if (swaps.length > depositTokens.length) {
      compound(swaps);
    }

    for (uint8 i; i < depositTokens.length; i++) {
      if (swaps[i].amount > 0) {
        if (swaps[i].srcToken == depositTokens[i]) {
          if (!ERC20Upgradeable(swaps[i].srcToken).transfer(address(strategy), swaps[i].amount)) {
            revert("STRAT_TRANSFER");
          }
          amounts[i] = swaps[i].amount;
        }
        else {
          amounts[i] = oneInchSwap(swaps[i], depositTokens[i]);
        }
      }
    }

    uint256 staked = strategy.deposit(amounts);
    shares = contractShares == 0 ? staked * INIT_SHARES : staked * contractShares / (getContractBalance() - staked);
    userShares[user] += shares;
    contractShares += shares;
  }

  function withdraw(uint256 shares, uint256 fap, uint8 fapIndex, GiddyStrategyV2.SwapInfo[] calldata swaps) external whenNotPaused nonReentrant {
    if (swaps.length > 0) {
      compound(swaps);
    }
    strategy.claimRewards();
    require(shares > 0, "ZERO_SHARES");
    require(shares <= userShares[_msgSender()], "SHARES_EXCEEDS_OWNED");

    address[] memory withdrawTokens = query.getWithdrawTokens();
    uint256 staked = getContractBalance() * shares / contractShares;
    userShares[_msgSender()] -= shares;
    contractShares -= shares;
    uint256[] memory amounts = strategy.withdraw(staked);
    for (uint8 i; i < amounts.length; i++) {
      if (amounts[i] > 0) {
        if (fap > 0 && i == fapIndex && amounts[0] >= fap) {
          amounts[i] = deductFee(withdrawTokens[i], amounts[i], fap);
        }
        if (!ERC20Upgradeable(withdrawTokens[i]).transfer(_msgSender(), amounts[i])) {
          revert("USER_TRANSFER");
        }
      }
    }
    emit Withdraw(_msgSender(), fap, fapIndex, shares, amounts);
  }

  function deductFee(address token, uint256 amount, uint256 fap) private returns (uint256) {
    if (fap > 0) {
      require(fap < amount, "FEE_AMOUNT");
      if (ERC20Upgradeable(token).transfer(config.feeAccount(), fap)) {
        revert("FEE_TRANSFER");
      }
    }
    return amount - fap;
  }

  function setStrategy(address strategyAddress) public onlyOwner {
    strategy = GiddyStrategyV2(strategyAddress);
  }

  function setQuery(address queryAddress) public onlyOwner {
    query = GiddyQueryV2(queryAddress);
  }

  function setConfig(address configAddress) public onlyOwner {
    config = GiddyConfigYA(configAddress);
  }

  function getGlobalSettings() public view virtual returns(address feeAccount, uint256 earningsFee) {
    feeAccount = config.feeAccount();
    earningsFee = config.earningsFee();
  }

  function oneInchSwap(GiddyStrategyV2.SwapInfo calldata swap, address dstToken) private returns (uint returnAmount) {
    if (!IERC20Upgradeable(swap.srcToken).approve(ONE_INCH_ROUTER, swap.amount)) {
      revert("SWAP_APPROVE");
    }
    uint srcBalance = IERC20Upgradeable(swap.srcToken).balanceOf(address(this));
    uint dstBalance = IERC20Upgradeable(dstToken).balanceOf(address(strategy));
    (bool swapResult, bytes memory swaptData) = address(ONE_INCH_ROUTER).call(swap.data);
    if (!swapResult) {
      revert("SWAP_CALL");
    }
    uint spentAmount;
    (returnAmount, spentAmount) = abi.decode(swaptData, (uint, uint));
    require(spentAmount == swap.amount, "SWAP_SPENT");
    require(srcBalance - IERC20Upgradeable(swap.srcToken).balanceOf(address(this)) == spentAmount, "SWAP_SRC_BALANCE");
    require(IERC20Upgradeable(dstToken).balanceOf(address(strategy)) - dstBalance == returnAmount, "SWAP_DST_BALANCE");
    emit SwapCall(swap.srcToken, swap.amount, returnAmount, spentAmount);
  }
}