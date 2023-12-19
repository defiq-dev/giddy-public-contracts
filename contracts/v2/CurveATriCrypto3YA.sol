//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IEIP3009.sol";
import "./interfaces/curve/ICurveCryptoSwap.sol";
import "./interfaces/curve/ICurveCryptoBase.sol";
import "./interfaces/curve/IRewardsGauge.sol";
import "./BaseYA.sol";
import "./libraries/GiddyUniswap.sol";
import "./GiddyConfigYA.sol";

contract CurveATriCrypto3YA is BaseYA, ReentrancyGuardUpgradeable, OwnableUpgradeable, PausableUpgradeable, ERC2771ContextUpgradeable {
  uint256 constant private COMPOUND_TRI_THRESHOLD = 1e14;
  uint256 constant private COMPOUND_CRV_THRESHOLD = 1e16;
  address constant private CRV_TOKEN = 0x172370d5Cd63279eFa6d502DAB29171933a610AF;
  address constant private WETH_TOKEN = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
  address constant private CURVE_POOL = 0x1d8b86e3D88cDb2d34688e87E72F388Cb541B7C8;
  address constant private CURVE_POOL_BASE = 0x445FE580eF8d70FF569aB36e80c647af338db351;
  address constant private CRV_USDBTCETH_TOKEN = 0xdAD97F7713Ae9437fa9249920eC8507e5FbB23d3;
  address constant private CRV_USDBTCETHG_TOKEN = 0xBb1B19495B8FE7C402427479B9aC14886cbbaaeE;
  address constant private REWARD_POOL = 0xBb1B19495B8FE7C402427479B9aC14886cbbaaeE;
  address constant private MINT_CRV = 0xabC000d88f23Bb45525E447528DBF656A9D55bf5;

  mapping(address => uint256) private userShares;
  uint256 private contractShares;
  address private feeAccount;
  uint256 private lastVirtualPrice;
  uint256 private lastCompoundTime;
  uint256 private pendingTriFees;

  function initialize(
    address _trustedForwarder,
    address _feeAccount) public initializer {
    __Ownable_init();
    __Pausable_init();
    __ReentrancyGuard_init();
    __ERC2771Context_init(_trustedForwarder);
    feeAccount = _feeAccount;
    lastVirtualPrice = virtualPrice();
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
    return IERC20(CRV_USDBTCETHG_TOKEN).balanceOf(address(this)) - pendingTriFees;
  }

  function getContractRewards() public view override returns (uint256) {
    return IERC20(CRV_TOKEN).balanceOf(address(this));
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

  function depositCalc(uint256 value, uint256 fap) external view override returns (uint256 amountOut, uint256 priceImpact) {
    amountOut = ICurveCryptoFiveWaySwap(CURVE_POOL).calc_token_amount([0,value - fap,0,0,0], true);
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

    uint256 shares = join(value);
    userShares[owner] += shares;
    contractShares += shares;

    emit Deposit(_msgSender(), value);
  }

  function depositGiddyCalc(uint256 value, uint256 fap) external view override returns (uint256 amountOut, uint256 priceImpact) {
    (amountOut, priceImpact) = GiddyUniswap.calcPriceSimple(SUSHI_ROUTER, GIDDY_TOKEN, USDC_TOKEN, value - fap);
    amountOut = ICurveCryptoFiveWaySwap(CURVE_POOL).calc_token_amount([0,amountOut,0,0,0], true);
  }

  function depositGiddy(ApproveWithAuthorization.ApprovalRequest calldata req, bytes calldata sig, uint256 fap) external override whenNotPaused nonReentrant deductEarningsFee() {
    require(req.spender == address(this) && req.owner == _msgSender());

    ApproveWithAuthorization(GIDDY_TOKEN).approveWithAuthorization(req, sig);
    if (!IERC20(GIDDY_TOKEN).transferFrom(req.owner, address(this), req.value)) {
      revert();
    }

    uint256 value = deductFeeGiddy(req.value, fap);
    value = GiddyUniswap.swapTokensSimple(SUSHI_ROUTER, GIDDY_TOKEN, USDC_TOKEN, address(this), value);

    uint256 shares = join(value);
    userShares[req.owner] += shares;
    contractShares += shares;

    emit Deposit(_msgSender(), value);
  }

  function withdrawCalc(uint256 shares, uint256 fap) external view override returns (uint256 amountOut, uint256 priceImpact) {
    amountOut = ICurveCryptoFiveWaySwap(CURVE_POOL).calc_withdraw_one_coin(sharesToValue(shares), 1) - fap;
    priceImpact = 0;
  }

  function withdraw(uint256 shares, uint256 fap) external override whenNotPaused nonReentrant deductEarningsFee() {
    require(shares > 0);
    require(shares <= userShares[_msgSender()]);

    uint256 value = leave(shares);
    value = deductFeeUsdc(value, fap);
    if (!IERC20(USDC_TOKEN).transfer(_msgSender(), value)) {
      revert();
    }

    emit Withdraw(_msgSender(), value);
  }

  function withdrawGiddyCalc(uint256 shares, uint256 fap) external view override returns (uint256 amountOut, uint256 priceImpact) {
    amountOut = ICurveCryptoFiveWaySwap(CURVE_POOL).calc_withdraw_one_coin(sharesToValue(shares), 1);
    (amountOut, priceImpact) = GiddyUniswap.calcPriceSimple(SUSHI_ROUTER, USDC_TOKEN, GIDDY_TOKEN, amountOut);
    amountOut -= fap;
  }

  function withdrawGiddy(uint256 shares, uint256 fap) external override whenNotPaused nonReentrant deductEarningsFee() {
    require(shares > 0);
    require(shares <= userShares[_msgSender()]);

    uint256 value = leave(shares);
    value = GiddyUniswap.swapTokensSimple(SUSHI_ROUTER, USDC_TOKEN, GIDDY_TOKEN, address(this), value);

    value = deductFeeGiddy(value, fap);
    if (!IERC20(GIDDY_TOKEN).transfer(_msgSender(), value)) {
      revert();
    }
  
    emit Withdraw(_msgSender(), giddyToUsdc(value));
  }

  function virtualPrice() private view returns (uint256) {
    return ICurveCryptoBase(CURVE_POOL_BASE).get_virtual_price();
  }

  function join(uint256 usdcValue) private returns (uint256 shares) {
    if (!IERC20(USDC_TOKEN).approve(CURVE_POOL, usdcValue)) {
      revert();
    }
    ICurveCryptoFiveWaySwap(CURVE_POOL).add_liquidity([0,usdcValue,0,0,0], 0);
    uint256 triValue = IERC20(CRV_USDBTCETH_TOKEN).balanceOf(address(this));
    shares = contractShares == 0 ? triValue * INIT_SHARES : triValue * contractShares / getContractBalance();
    if (!IERC20(CRV_USDBTCETH_TOKEN).approve(REWARD_POOL, triValue)) {
      revert();
    }
    IRewardsGauge(REWARD_POOL).deposit(triValue);
  }

  function leave(uint256 shares) private returns (uint256 usdcValue) {
    uint256 value = getContractBalance() * shares / contractShares;
    userShares[_msgSender()] -= shares;
    contractShares -= shares;

    IRewardsGauge(REWARD_POOL).withdraw(value);
    if (!IERC20(CRV_USDBTCETH_TOKEN).approve(CURVE_POOL, value)) {
      revert();
    }
    ICurveCryptoFiveWaySwap(CURVE_POOL).remove_liquidity_one_coin(value, 1, 0);
    return IERC20(USDC_TOKEN).balanceOf(address(this));
  }

  function deductFeeUsdc(uint256 amount, uint256 fap) private returns (uint256) {
    if (fap > 0) {
      if (!IERC20(USDC_TOKEN).transfer(GIDDY_CONFIG.feeAccount(), fap)) {
        revert();
      }
    }
    return amount - fap;
  }

  function deductFeeGiddy(uint256 amount, uint256 fap) private returns (uint256) {
    if (fap > 0) {
      GiddyUniswap.swapTokensSimple(SUSHI_ROUTER, GIDDY_TOKEN, USDC_TOKEN, GIDDY_CONFIG.feeAccount(), fap);
    }
    return amount - fap;
  }

  modifier deductEarningsFee() {
    uint256 contractBalance = getContractBalance();
    uint256 earnings = ((virtualPrice() - lastVirtualPrice) * contractBalance) / 1e18;
    if (earnings > 0) {
      uint256 feeTri = earnings * GIDDY_CONFIG.earningsFee() / BASE_PERCENT;
      pendingTriFees += feeTri;
      if (pendingTriFees >= COMPOUND_TRI_THRESHOLD) {
        IRewardsGauge(REWARD_POOL).withdraw(pendingTriFees);
        if (!IERC20(CRV_USDBTCETH_TOKEN).approve(CURVE_POOL, pendingTriFees)) {
          revert(); 
        }
        ICurveCryptoFiveWaySwap(CURVE_POOL).remove_liquidity_one_coin(pendingTriFees, 1, 0);

        if (!IERC20(USDC_TOKEN).transfer(GIDDY_CONFIG.feeAccount(), IERC20(USDC_TOKEN).balanceOf(address(this)))) {
          revert();
        }
        pendingTriFees = 0;
      }

      IRewardsGauge(MINT_CRV).mint(REWARD_POOL);
      uint256 value = IERC20(CRV_TOKEN).balanceOf(address(this));
      if (value >= COMPOUND_CRV_THRESHOLD) {
        address[] memory route = new address[](3);
        route[0] = CRV_TOKEN;
        route[1] = WETH_TOKEN;
        route[2] = USDC_TOKEN;
        value = GiddyUniswap.swapTokens(SUSHI_ROUTER, route, address(this), value);

        value = deductFeeUsdc(value, value * GIDDY_CONFIG.earningsFee() / BASE_PERCENT);

        if (!IERC20(USDC_TOKEN).approve(CURVE_POOL, value)) {
          revert();
        }
        ICurveCryptoFiveWaySwap(CURVE_POOL).add_liquidity([0,value,0,0,0], 0);

        value = IERC20(CRV_USDBTCETH_TOKEN).balanceOf(address(this));
        if (!IERC20(CRV_USDBTCETH_TOKEN).approve(REWARD_POOL, value)) {
          revert();
        }
        IRewardsGauge(REWARD_POOL).deposit(value);

        earnings += value;
      }
      emit Compound(earnings - feeTri, lastCompoundTime, contractBalance);
      lastCompoundTime = block.timestamp;
    }
    _;
    lastVirtualPrice = virtualPrice();
  }
}