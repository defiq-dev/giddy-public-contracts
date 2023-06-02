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
  struct VaultAuth {
    bytes signature;
    bytes32 nonce;
    uint256 deadline;
    uint256 amount;
    uint256 fap;
    uint256 fapIndex;
    SwapInfo[] depositSwaps;
    SwapInfo[] compoundSwaps;
  }

  struct UsdcAuth {
    address owner;
    address spender;
    uint256 value;
    uint256 validAfter;
    uint256 validBefore;
    bytes32 nonce;
    uint8 v;
    bytes32 r;
    bytes32 s;
  }

  using SafeERC20Upgradeable for ERC20Upgradeable;
  uint256 constant internal INIT_SHARES = 1e10;
  uint256 constant internal BASE_PERCENT = 1e6;
  address constant internal USDC_TOKEN = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
  address constant internal GIDDY_TOKEN = 0x67eB41A14C0fe5CD701FC9d5A3D6597A72F641a6;
  address constant internal GIDDY_USDC_PAIR = 0xDE990994309BC08E57aca82B1A19170AD84323E8;
  bytes32 constant public SWAP_AUTHORIZATION_TYPEHASH = keccak256("VaultAuth(bytes32 nonce,uint256 deadline,uint256 amount,uint256 fap,uint256 fapIndex,bytes[] data)");

  bytes32 public domainSeparator;
  mapping(bytes32 => bool) private nonceMap;
  string public name;

  mapping(address => uint256) private userShares;
  uint256 private contractShares;
  GiddyStrategyV2 public strategy;
  GiddyQueryV2 public query;
  GiddyConfigYA public config;
  bool public rewardsEnabled;

  event Deposit(address indexed from, uint256 fap, address token, uint256 amount, uint256 shares);
  event DepositExact(address indexed from, uint256 fap, uint256 fapIndex, uint256[] amounts, uint256 shares);
  event Withdraw(address indexed from, uint256 fap, uint256 fapIndex, uint256 shares, uint256[] amounts);
  event CompoundV2(uint256 contractBalance, uint256 contractShares);

  function initialize(address trustedForwarder, address configAddress, string calldata _name) public initializer {
    __Ownable_init();
    __Pausable_init();
    __ReentrancyGuard_init();
    __ERC2771Context_init(trustedForwarder);
    name = _name;
    domainSeparator = EIP712.makeDomainSeparator(_name, "1.0");
    config = GiddyConfigYA(configAddress);
    rewardsEnabled = true;
  }

  function _msgSender() internal view virtual override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (address sender) {
    return ERC2771ContextUpgradeable._msgSender();
  }

  function _msgData() internal view virtual override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (bytes calldata) {
    return ERC2771ContextUpgradeable._msgData();
  }

  function getNativeToken() external view returns (address token) {
    return query.getNativeToken();
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

  function getRewardTokens() external view returns (address[] memory tokens) {
    return query.getRewardTokens(); 
  }

  function getContractRewards() public view returns (uint256[] memory amounts) {
    return strategy.getContractRewards();
  }

  function getContractShares() public view returns (uint256 shares) {
    return contractShares;
  }

  function getContractBalance() public view returns (uint256 amount) {
    return strategy.getContractBalance();
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
  
  function compound(VaultAuth calldata vaultAuth) public whenNotPaused {
    validateVaultAuth(vaultAuth);
    strategy.claimRewards();
    if (strategy.compound(vaultAuth.compoundSwaps) > 0) {
      emit CompoundV2(getContractBalance(), getContractShares());
    }
  }

  function depositSingle(VaultAuth calldata vaultAuth) external whenNotPaused nonReentrant {
    validateVaultAuth(vaultAuth);
    compoundCheck(vaultAuth.compoundSwaps);
    SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(vaultAuth.depositSwaps[0].srcToken), _msgSender(), address(this), vaultAuth.amount);
    deductFee(vaultAuth.depositSwaps[0].srcToken, vaultAuth.amount, vaultAuth.fap);
    uint256 shares = joinStrategy(_msgSender(), vaultAuth.depositSwaps);
    emit Deposit(_msgSender(), vaultAuth.fap, vaultAuth.depositSwaps[0].srcToken, vaultAuth.amount, shares);
  }

  function depositUsdc(UsdcAuth calldata usdcAuth, VaultAuth calldata vaultAuth) external whenNotPaused nonReentrant {
    validateVaultAuth(vaultAuth);
    compoundCheck(vaultAuth.compoundSwaps);
    require(usdcAuth.spender == address(this), "AUTH_SPENDER");
    require(usdcAuth.owner == _msgSender(), "AUTH_OWNER");



    IEIP3009(USDC_TOKEN).approveWithAuthorization(usdcAuth.owner, usdcAuth.spender, usdcAuth.value, usdcAuth.validAfter, usdcAuth.validBefore, usdcAuth.nonce, usdcAuth.v, usdcAuth.r, usdcAuth.s);
    if (!IERC20Upgradeable(USDC_TOKEN).transferFrom(usdcAuth.owner, address(this), usdcAuth.value)) {
      revert("VAULT_ONE_STEP");
    }

    deductFee(USDC_TOKEN, usdcAuth.value, vaultAuth.fap);
    uint256 shares = joinStrategy(usdcAuth.owner, vaultAuth.depositSwaps);
    emit Deposit(_msgSender(), vaultAuth.fap, USDC_TOKEN, usdcAuth.value, shares);
  }

  function depositGiddy(ApproveWithAuthorization.ApprovalRequest calldata giddyAuth, bytes calldata giddySig, VaultAuth calldata vaultAuth) external whenNotPaused nonReentrant {
    validateVaultAuth(vaultAuth);
    compoundCheck(vaultAuth.compoundSwaps);
    require(giddyAuth.spender == address(this), "AUTH_SPENDER");
    require(giddyAuth.owner == _msgSender(), "AUTH_OWNER");

    ApproveWithAuthorization(GIDDY_TOKEN).approveWithAuthorization(giddyAuth, giddySig);
    if (!IERC20Upgradeable(GIDDY_TOKEN).transferFrom(giddyAuth.owner, address(this), giddyAuth.value)) {
      revert("VAULT_ONE_STEP");
    }

    deductFee(GIDDY_TOKEN, giddyAuth.value, vaultAuth.fap);
    uint256 shares = joinStrategy(giddyAuth.owner, vaultAuth.depositSwaps);
    emit Deposit(_msgSender(), vaultAuth.fap, GIDDY_TOKEN, giddyAuth.value, shares);
  }

  function joinStrategy(address user, SwapInfo[] calldata swaps) private returns (uint256 shares) {
    address[] memory depositTokens = query.getDepositTokens();
    uint256[] memory amounts = new uint256[](depositTokens.length);
    address router = config.swapRouter();

    for (uint8 i; i < depositTokens.length; i++) {
      if (swaps[i].amount > 0) {
        if (swaps[i].srcToken == depositTokens[i]) {
          if (!ERC20Upgradeable(swaps[i].srcToken).transfer(address(strategy), swaps[i].amount)) {
            revert("STRAT_TRANSFER");
          }
          amounts[i] = swaps[i].amount;
        }
        else {
          amounts[i] = GiddyLibraryV2.routerSwap(router, swaps[i], address(this), address(strategy), depositTokens[i]);
        }
      }
    }

    uint256 staked = strategy.deposit(amounts);
    shares = contractShares == 0 ? staked * INIT_SHARES : staked * contractShares / (getContractBalance() - staked);
    userShares[user] += shares;
    contractShares += shares;
  }

  function withdrawAuth(VaultAuth calldata vaultAuth) external whenNotPaused nonReentrant {
    validateVaultAuth(vaultAuth);
    compoundCheck(vaultAuth.compoundSwaps);
    require(vaultAuth.amount > 0, "ZERO_SHARES");
    require(vaultAuth.amount <= userShares[_msgSender()], "SHARES_EXCEEDS_OWNED");

    address[] memory withdrawTokens = query.getWithdrawTokens();
    uint256 staked = getContractBalance() * vaultAuth.amount / contractShares;
    userShares[_msgSender()] -= vaultAuth.amount;
    contractShares -= vaultAuth.amount;
    uint256[] memory amounts = strategy.withdraw(staked);
    for (uint8 i; i < amounts.length; i++) {
      if (amounts[i] > 0) {
        if (vaultAuth.fap > 0 && i == vaultAuth.fapIndex && amounts[0] >= vaultAuth.fap) {
          amounts[i] = deductFee(withdrawTokens[i], amounts[i], vaultAuth.fap);
        }
        if (!ERC20Upgradeable(withdrawTokens[i]).transfer(_msgSender(), amounts[i])) {
          revert("USER_TRANSFER");
        }
      }
    }
    emit Withdraw(_msgSender(), vaultAuth.fap, vaultAuth.fapIndex, vaultAuth.amount, amounts);
  }

  function withdraw(uint256 shares) external whenNotPaused nonReentrant {
    require(shares > 0, "ZERO_SHARES");
    require(shares <= userShares[_msgSender()], "SHARES_EXCEEDS_OWNED");

    address[] memory withdrawTokens = query.getWithdrawTokens();
    uint256 staked = getContractBalance() * shares / contractShares;
    userShares[_msgSender()] -= shares;
    contractShares -= shares;
    uint256[] memory amounts = strategy.withdraw(staked);
    for (uint8 i; i < amounts.length; i++) {
      if (amounts[i] > 0) {
        if (!ERC20Upgradeable(withdrawTokens[i]).transfer(_msgSender(), amounts[i])) {
          revert("USER_TRANSFER");
        }
      }
    }
    emit Withdraw(_msgSender(), 0, 0, shares, amounts);
  }

  function setStrategy(address strategyAddress) public onlyOwner {
    if (address(strategy) != address(0)) {
      strategy.moveStrategy(strategyAddress);
    }
    strategy = GiddyStrategyV2(strategyAddress);
  }

  function setQuery(address queryAddress) public onlyOwner {
    query = GiddyQueryV2(queryAddress);
  }

  function setConfig(address configAddress) public onlyOwner {
    config = GiddyConfigYA(configAddress);
  }

  function setRewardsEnabled(bool enabled) public onlyOwner {
    rewardsEnabled = enabled;
  }

  function getGlobalSettings() public view virtual returns(address feeAccount, uint256 earningsFee) {
    feeAccount = config.feeAccount();
    earningsFee = config.earningsFee();
  }

  function deductFee(address token, uint256 amount, uint256 fap) private returns (uint256) {
    if (fap > 0) {
      require(fap < amount, "FEE_AMOUNT");
      if (!ERC20Upgradeable(token).transfer(config.feeAccount(), fap)) {
        revert("FEE_TRANSFER");
      }
    }
    return amount - fap;
  }

  function compoundCheck(SwapInfo[] calldata swaps) private {
    if (rewardsEnabled) {
      strategy.claimRewards();
      if (swaps.length > 0) {
        if (strategy.compound(swaps) > 0) {
          emit CompoundV2(getContractBalance(), getContractShares());
        }
      }
    }
  }

  function validateVaultAuth(VaultAuth calldata auth) private {
    require(block.timestamp < auth.deadline, "SWAP_AUTH_EXPRIED");
    require(!nonceMap[auth.nonce], "NONCE_USED");
    bytes memory dataArray;
    for (uint i = 0; i < auth.depositSwaps.length; i++) {
      dataArray = abi.encodePacked(dataArray, keccak256(auth.depositSwaps[i].data));
    }
    for (uint i = 0; i < auth.compoundSwaps.length; i++) {
      dataArray = abi.encodePacked(dataArray, keccak256(auth.compoundSwaps[i].data));
    }
    bytes memory data = abi.encodePacked(SWAP_AUTHORIZATION_TYPEHASH, abi.encode(
      auth.nonce,
      auth.deadline,
      auth.amount,
      auth.fap,
      auth.fapIndex,
      keccak256(dataArray)
    ));
    require(config.verifiedContracts(EIP712.recover(domainSeparator, auth.signature, data)), "VERIFY_SWAP");
    nonceMap[auth.nonce] = true;
  }
}