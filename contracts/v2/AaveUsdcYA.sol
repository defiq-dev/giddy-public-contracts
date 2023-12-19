//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IEIP3009.sol";
import "./interfaces/aave/IIncentivesController.sol";
import "./interfaces/aave/ILendingPool.sol";
import "./interfaces/uniswap/IUniswapV2Router02.sol";
import "./interfaces/uniswap/IUniswapV2Pair.sol";
import "./BaseYA.sol";
import "./UniswapV2Giddy.sol";
import "./GiddyConfigYA.sol";

contract AaveUsdcYA is BaseYA, UniswapV2Giddy, ReentrancyGuardUpgradeable, OwnableUpgradeable, PausableUpgradeable, ERC2771ContextUpgradeable {
  address constant private LENDING_POOL = 0x8dFf5E27EA6b7AC08EbFdf9eB090F32ee9a30fcf;
  address constant private AM_USDC_TOKEN = 0x1a13F4Ca1d028320A707D99520AbFefca3998b7F;
  
  mapping(address => uint256) private userShares;
  uint256 private contractShares;
  address private feeAccount;
  uint256 private lastContractBalance;
  uint256 private lastCompoundTime;

  function initialize(
    address _trustedForwarder,
    address _feeAccount) public initializer {
    __Ownable_init();
    __Pausable_init();
    __ReentrancyGuard_init();
    __ERC2771Context_init(_trustedForwarder);
    feeAccount = _feeAccount;
    lastCompoundTime = block.timestamp;
  }

  function _msgSender() internal view virtual override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (address sender) {
    return ERC2771ContextUpgradeable._msgSender();
  }

  function _msgData() internal view virtual override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (bytes calldata) {
    return ERC2771ContextUpgradeable._msgData();
  }

  function getContractShares() public view override returns (uint256) {
    return contractShares;
  }

  function getContractBalance() public view override returns (uint256) {
    return IERC20(AM_USDC_TOKEN).balanceOf(address(this));
  }

  function getContractRewards() public view override returns (uint256) {
    return getContractBalance() - lastContractBalance;
  }

  function getUserShares(address user) public view override returns (uint256) {
    return userShares[user];
  }

  function getUserBalance(address user) public view override returns (uint256) {
    return sharesToValue(getUserShares(user));
  }

  function sharesToValue(uint256 shares) public view override returns (uint256) {
    if (contractShares == 0) return 0;
    return getContractBalance() * shares / contractShares;
  }

  function compound() public override whenNotPaused deductEarningsFee() { }

  function depositCalc(uint256 value, uint256 fap) external pure override returns (uint256 amountOut, uint256 priceImpact) {
    amountOut = value - fap;
    priceImpact = 0;
  }

  function deposit(bytes calldata auth, uint256 fap) external override whenNotPaused nonReentrant deductEarningsFee() {
    (address owner, address spender, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) = abi.decode(
      auth,
      (address, address, uint256, uint256, uint256, bytes32, uint8, bytes32, bytes32)
    );
    require(spender == address(this) && owner == _msgSender());
         
    IEIP3009(USDC_TOKEN).approveWithAuthorization(owner, spender, value, validAfter, validBefore, nonce, v, r, s);
    if (!IERC20(USDC_TOKEN).transferFrom(owner, address(this), value)) {
      revert();
    }
    value = deductFeeUsdc(value, fap);

    uint256 shares = contractShares == 0 ? value * INIT_SHARES : value * contractShares / getContractBalance();
    userShares[owner] = userShares[owner] + shares;
    contractShares = contractShares + shares;

    if (!IERC20(USDC_TOKEN).approve(LENDING_POOL, value)) {
      revert();
    }
    ILendingPool(LENDING_POOL).deposit(USDC_TOKEN, value, address(this), 0);

    emit Deposit(_msgSender(), value);
  }

  function depositGiddyCalc(uint256 value, uint256 fap) external view override returns (uint256 amountOut, uint256 priceImpact) {
    (amountOut, priceImpact) = calcPriceSimple(SUSHI_ROUTER, GIDDY_TOKEN, USDC_TOKEN, value - fap);
  }

  function depositGiddy(ApproveWithAuthorization.ApprovalRequest calldata req, bytes calldata sig, uint256 fap) external override whenNotPaused nonReentrant deductEarningsFee() {
    require(req.spender == address(this) && req.owner == _msgSender());

    ApproveWithAuthorization(GIDDY_TOKEN).approveWithAuthorization(req, sig);
    if (!IERC20(GIDDY_TOKEN).transferFrom(req.owner, address(this), req.value)) {
      revert();
    }
    uint256 giddyValue = deductFeeGiddy(req.value, fap);
    uint256 usdcValue = swapTokensSimple(SUSHI_ROUTER, GIDDY_TOKEN, USDC_TOKEN, address(this), giddyValue);
    
    uint256 shares = contractShares == 0 ? usdcValue * INIT_SHARES : usdcValue * contractShares / getContractBalance();
    userShares[req.owner] = userShares[req.owner] + shares;
    contractShares = contractShares + shares;

    if (!IERC20(USDC_TOKEN).approve(LENDING_POOL, usdcValue)) {
      revert();
    }
    ILendingPool(LENDING_POOL).deposit(USDC_TOKEN, usdcValue, address(this), 0);

    emit Deposit(_msgSender(), usdcValue);
  }

  function withdrawCalc(uint256 shares, uint256 fap) external view override returns (uint256 amountOut, uint256 priceImpact) {
    amountOut = sharesToValue(shares) - fap;
    priceImpact = 0;
  }

  function withdraw(uint256 shares, uint256 fap) external override whenNotPaused nonReentrant deductEarningsFee() {
    require(shares > 0, "Shares cannot be zero.");
    require(shares <= userShares[_msgSender()], "Shares exceeds value owned.");

    uint256 value = getContractBalance() * shares / contractShares;
    userShares[_msgSender()] = userShares[_msgSender()] - shares;
    contractShares = contractShares - shares;

    ILendingPool(LENDING_POOL).withdraw(USDC_TOKEN, value, address(this));
    value = deductFeeUsdc(value, fap);

    if (!IERC20(USDC_TOKEN).transfer(_msgSender(), value)) {
      revert();
    }

    emit Withdraw(_msgSender(), value);
  }

  function withdrawGiddyCalc(uint256 shares, uint256 fap) external view override returns (uint256 amountOut, uint256 priceImpact) {
    (amountOut, priceImpact) = calcPriceSimple(SUSHI_ROUTER, USDC_TOKEN, GIDDY_TOKEN, sharesToValue(shares));
    amountOut -= fap;
  }

  function withdrawGiddy(uint256 shares, uint256 fap) external override whenNotPaused nonReentrant deductEarningsFee() {
    require(shares > 0, "Shares cannot be zero.");
    require(shares <= userShares[_msgSender()], "Shares exceeds value owned.");

    uint256 value = getContractBalance() * shares / contractShares;
    userShares[_msgSender()] = userShares[_msgSender()] - shares;
    contractShares = contractShares - shares;

    ILendingPool(LENDING_POOL).withdraw(USDC_TOKEN, value, address(this));
    value = swapTokensSimple(SUSHI_ROUTER, USDC_TOKEN, GIDDY_TOKEN, address(this), value);
    value = deductFeeGiddy(value, fap);

    if (!IERC20(GIDDY_TOKEN).transfer(_msgSender(), value)) {
      revert();
    }

    emit Withdraw(_msgSender(), giddyToUsdc(value));
  }

  function deductFeeUsdc(uint256 amount, uint256 fap) internal returns (uint256) {
    if (fap > 0) {
      if (!IERC20(USDC_TOKEN).transfer(GIDDY_CONFIG.feeAccount(), fap)) {
        revert();
      }
    }
    return amount - fap;
  }

  function deductFeeGiddy(uint256 amount, uint256 fap) internal returns (uint256) {
    if (fap > 0) {
      swapTokensSimple(SUSHI_ROUTER, GIDDY_TOKEN, USDC_TOKEN, GIDDY_CONFIG.feeAccount(), fap);
    }
    return amount - fap;
  }

  modifier deductEarningsFee() {
    uint256 earnings = getContractBalance() - lastContractBalance;
    if (earnings > 0) {
      uint256 fee = earnings * GIDDY_CONFIG.earningsFee() / BASE_PERCENT;
      if (fee > 0) {
        ILendingPool(LENDING_POOL).withdraw(USDC_TOKEN, fee, address(this));
        if (!IERC20(USDC_TOKEN).transfer(GIDDY_CONFIG.feeAccount(), fee)) {
          revert();
        }
      }
      emit Compound(earnings - fee, lastCompoundTime, lastContractBalance);
      lastCompoundTime = block.timestamp;
    }
    _;
    lastContractBalance = getContractBalance();
  }
}
