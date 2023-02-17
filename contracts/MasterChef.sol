// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./ApproveWithAuthorization.sol";
import "./giddyToken.sol"; 

// The Giddy MasterChef is a fork of MasterChef by SushiSwap
// The biggest change made is using per second instead of per block for rewards
// The other biggest change was the removal of the migration functions
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once it is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. 
contract GiddyChef is OwnableUpgradeable {
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of Giddy
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accGiddyPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accGiddyPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. giddy to distribute per block.
        uint256 lastRewardTime;  // Last block time that giddy distribution occurs.
        uint256 accGiddyPerShare; // Accumulated giddy per share, times 1e12. See below.
    }

    // such a cool token!
    GiddyToken public giddy;

    // giddy tokens created per second.
    uint256 public giddyPerSecond;
 
    uint256 public constant MaxAllocPoint = 4000;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;
    // The block time when Giddy mining starts.
    uint256 public startTime;
    // The block time when Giddy mining stops.
    uint256 public endTime;

    // Escrow that holds rewards
    address public escrow;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    function initialize(
        GiddyToken _giddy,
        uint256 _giddyPerSecond,
        uint256 _startTime,
        uint256 _endTime,
        address _escrow
    ) public initializer {
        __Ownable_init();
        totalAllocPoint = 0;
        giddy = _giddy;
        giddyPerSecond = _giddyPerSecond;
        startTime = _startTime;
        endTime = _endTime;
        escrow = _escrow;
    }

    function setEscrow(address _escrow) external onlyOwner {
        escrow = _escrow;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function checkForDuplicate(IERC20 _lpToken) internal view {
        uint256 length = poolInfo.length;
        for (uint256 _pid = 0; _pid < length; _pid++) {
            require(poolInfo[_pid].lpToken != _lpToken, "add: pool already exists!!!!");
        }

    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _lpToken) external onlyOwner {
        require(_allocPoint <= MaxAllocPoint, "add: too many alloc points!!");

        checkForDuplicate(_lpToken); // ensure you cant add duplicate pools

        massUpdatePools();

        uint256 lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardTime: lastRewardTime,
            accGiddyPerShare: 0
        }));
    }

    // Update the given pool's Giddy allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) external onlyOwner {
        require(_allocPoint <= MaxAllocPoint, "add: too many alloc points!!");

        massUpdatePools();

        totalAllocPoint = totalAllocPoint - poolInfo[_pid].allocPoint + _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Return reward multiplier over the given _from to _to timestamp.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        _from = _from > startTime ? _from : startTime;
        if (_to < startTime || _from >= endTime) {
            return 0;
        } else if (_to <= endTime) {
            return _to.sub(_from);
        } else {
            return endTime.sub(_from);
        }
    }

    // View function to see pending Giddy on frontend.
    function pendingGiddy(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accGiddyPerShare = pool.accGiddyPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
            uint256 giddyReward = multiplier.mul(giddyPerSecond).mul(pool.allocPoint).div(totalAllocPoint);
            accGiddyPerShare = accGiddyPerShare.add(giddyReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accGiddyPerShare).div(1e12).sub(user.rewardDebt);
    }

    function poolBalances(address _user) external view returns (uint256[] memory) {
        uint256 length = poolInfo.length;
        uint256[] memory poolBalanceData = new uint256[](length);
        for (uint256 _pid = 0; _pid < length; ++_pid) {
            UserInfo storage user = userInfo[_pid][_user];
            poolBalanceData[_pid] = user.amount;
        }
        return poolBalanceData;
    }

    // View function to see pending Giddy on frontend.
    function pendingGiddyForUser(address _user) external view returns (uint256[] memory) {
        uint256 length = poolInfo.length;
        uint256[] memory pendingGiddyValues = new uint256[](length);
        for (uint256 _pid = 0; _pid < length; ++_pid) {
            PoolInfo storage pool = poolInfo[_pid];
            UserInfo storage user = userInfo[_pid][_user];
            uint256 accGiddyPerShare = pool.accGiddyPerShare;
            uint256 lpSupply = pool.lpToken.balanceOf(address(this));
            if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
                uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
                uint256 giddyReward = multiplier.mul(giddyPerSecond).mul(pool.allocPoint).div(totalAllocPoint);
                accGiddyPerShare = accGiddyPerShare.add(giddyReward.mul(1e12).div(lpSupply));
            }
            pendingGiddyValues[_pid] = user.amount.mul(accGiddyPerShare).div(1e12).sub(user.rewardDebt);
        }
        return pendingGiddyValues;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
        uint256 giddyReward = multiplier.mul(giddyPerSecond).mul(pool.allocPoint).div(totalAllocPoint);

        pool.accGiddyPerShare = pool.accGiddyPerShare.add(giddyReward.mul(1e12).div(lpSupply));
        pool.lastRewardTime = block.timestamp;
    }

    // Deposit LP tokens to MasterChef for Giddy allocation.
    function deposit(uint256 _pid, uint256 _amount) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accGiddyPerShare).div(1e12).sub(user.rewardDebt);

        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accGiddyPerShare).div(1e12);

        if(pending > 0) {
            safeGiddyTransfer(msg.sender, pending);
        }
        pool.lpToken.transferFrom(address(msg.sender), address(this), _amount);

        emit Deposit(msg.sender, _pid, _amount);
    }

    // Deposit Giddy tokens to MasterChef for Giddy allocation.
    function depositGiddy(uint256 _pid, ApproveWithAuthorization.ApprovalRequest calldata req, bytes calldata sig) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][req.owner];

        require(address(pool.lpToken) == address(giddy), "Incorrect pid");
        require(req.spender == address(this), "Recipient is not this contract");

        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accGiddyPerShare).div(1e12).sub(user.rewardDebt);

        user.amount = user.amount.add(req.value);
        user.rewardDebt = user.amount.mul(pool.accGiddyPerShare).div(1e12);

        if(pending > 0) {
            safeGiddyTransfer(req.owner, pending);
        }

        giddy.approveWithAuthorization(req, sig);

        pool.lpToken.transferFrom(req.owner, address(this), req.value);

        emit Deposit(req.owner, _pid, req.value);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) external {  
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accGiddyPerShare).div(1e12).sub(user.rewardDebt);

        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accGiddyPerShare).div(1e12);

        if(pending > 0) {
            safeGiddyTransfer(msg.sender, pending);
        }
        pool.lpToken.transfer(address(msg.sender), _amount);
        
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function harvestAll() public {
        uint256 length = poolInfo.length;
        uint calc;
        uint pending;
        UserInfo storage user;
        PoolInfo storage pool;
        uint totalPending;
        for (uint256 pid = 0; pid < length; ++pid) {
            user = userInfo[pid][msg.sender];
            if (user.amount > 0) {
                pool = poolInfo[pid];
                updatePool(pid);

                calc = user.amount.mul(pool.accGiddyPerShare).div(1e12);
                pending = calc.sub(user.rewardDebt);
                user.rewardDebt = calc;

                if(pending > 0) {
                    totalPending+=pending;
                }
            }
        }
        if (totalPending > 0) {
            safeGiddyTransfer(msg.sender, totalPending);
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint oldUserAmount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        pool.lpToken.transfer(address(msg.sender), oldUserAmount);
        emit EmergencyWithdraw(msg.sender, _pid, oldUserAmount);
    }

    // Safe Giddy transfer function, reverts if escrow doesn't have enough funds
    function safeGiddyTransfer(address _to, uint256 _amount) internal {
        uint256 giddyBal = giddy.balanceOf(address(escrow));
        uint256 giddyAllowance = giddy.allowance(escrow, address(this));
        require(giddyBal >= _amount, "Insufficient funds");
        require(giddyAllowance >= _amount, "Insufficient approval");
        giddy.transferFrom(escrow, address(this), _amount);
        giddy.transfer(_to, _amount);
    }

    function setStartTime(uint256 _newStartTime) external onlyOwner {
        require(startTime > block.timestamp, "Already started");
        require(_newStartTime > block.timestamp, "New time in the past");

        startTime = _newStartTime;
    }

    function setEndime(uint256 _newEndTime) external onlyOwner {
        require(endTime > block.timestamp, "Already ended");
        require(_newEndTime > block.timestamp, "New end time in the past");

        endTime = _newEndTime;
    }

    function setGiddyPerSecond(uint256 _newGiddyPerSecond) external onlyOwner {
        giddyPerSecond = _newGiddyPerSecond;
    }
}