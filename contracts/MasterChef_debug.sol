// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";
import "./VCT.sol";

interface IMigratorChef {
    // Perform LP token migration from legacy UniswapV2 to VCTSwap.
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    // Return the new LP token address.
    //
    // XXX Migrator must have allowance access to UniswapV2 LP tokens.
    // VCTSwap must mint EXACTLY the same amount of VCTSwap LP tokens or
    // else something bad will happen. Traditional UniswapV2 does not
    // do that so be careful!
    function migrate(IERC20 token) external returns (IERC20);
}

// MasterChef is the master of 'VCT'. He can make VCT and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once VCT is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.

contract MasterChef_debug is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    // Info of each user
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below
        //
        // We do some fancy math here. Basically, any point in time, the amount of VCTs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accVCTPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accVCTPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }
    // Info of each pool
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. VCTs to distribute per block
        uint256 lastRewardBlock; // Last block number that VCTs distribution occurs;
        uint256 accVCTPerShare; // Accumulated VCTs per share, times 1e0. See below
    }
    // The VCT TOKEN!
    VCT public vct;
    // Dev address;
    address public devaddr;
    // Block number when bonus VCT period ends
    uint256 public bonusEndBlock;
    // VCT tokens created per block
    uint256 public VCTPerBlock;
    // Bonus multiplier for early VCT makers
    uint256 public constant BONUS_MULTIPLIER = 10;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner)
    IMigratorChef public migrator;
    // Info of each pool
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools
    uint256 public totalAllocPoint = 0;
    // The block number when VCT mining starts
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        VCT _vct,
        address _devaddr,
        uint256 _vctPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock
    ) public {
        vct = _vct;
        devaddr = _devaddr;
        VCTPerBlock = _vctPerBlock;
        bonusEndBlock = _bonusEndBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
        lpToken: _lpToken,
        allocPoint: _allocPoint,
        lastRewardBlock: lastRewardBlock,
        accVCTPerShare: 0
        }));
    }

    // Update the given pool's VCT allocation point. Can only be called by the owner
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Set the migrator contract. Can only be called by the owner
    function setMigrator(IMigratorChef _migrator) public onlyOwner {
        migrator = _migrator;
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    // Return reward multiplier over the given _from to _to block
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from).mul(BONUS_MULTIPLIER);
        } else if (_from >= bonusEndBlock) {
            return _to.sub(_from);
        } else {
            return bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(_to.sub(bonusEndBlock));
        }
    }

    // View function to see pending VCTs on frontend
    function pendingVCT(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accVCTPerShare = pool.accVCTPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 VCTReward = multiplier.mul(VCTPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accVCTPerShare = accVCTPerShare.add(VCTReward.mul(1e0).div(lpSupply));
        }
        return user.amount.mul(accVCTPerShare).div(1e0).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date
    function updatePool(uint256 _pid) public {
        //console.log('update Pool');
        PoolInfo storage pool = poolInfo[_pid];
        console.log('------------------------------');
        console.log('block.number', block.number);
        console.log('pool.lastRewardBlock', pool.lastRewardBlock);

        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        console.log('lpSupply before', lpSupply);
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        console.log('lpSupply after', lpSupply);
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 VCTReward = multiplier.mul(VCTPerBlock).mul(pool.allocPoint).div(totalAllocPoint);

        console.log('multiplier', multiplier);
        console.log('VCTPerBlock', VCTPerBlock);
        console.log('pool.allocationPoint', pool.allocPoint);
        console.log('totalAllocPoint', totalAllocPoint);
        console.log('VCTReward', VCTReward);

        vct.mint(devaddr, VCTReward.div(10));
        vct.mint(address(this), VCTReward);
        pool.accVCTPerShare = pool.accVCTPerShare.add(VCTReward.mul(1e0).div(lpSupply));
        console.log('pool.accVCTPerShare', pool.accVCTPerShare);
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for VCT allocation
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        //console.log('user.amount', user.amount);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accVCTPerShare).div(1e0).sub(user.rewardDebt);
            console.log('????????????????????????????????');
            console.log('user.amount', user.amount);
            console.log('pool.accVCTPerShare', pool.accVCTPerShare);
            console.log('user.rewardDebt', user.rewardDebt);
            console.log('pending', pending);
            safeVCTTransfer(msg.sender, pending);
        }
        //        console.log('multiplier', multiplier);

        pool.lpToken.safeTransferFrom(address(msg.sender), address (this), _amount);
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accVCTPerShare).div(1e0);

        console.log('user.rewardDebt', user.rewardDebt);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accVCTPerShare).div(1e0).sub(user.rewardDebt);
        safeVCTTransfer(msg.sender, pending);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accVCTPerShare).div(1e0);
        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe VCT transfer function, just in case if rounding error causes pool to not have enough VCTs
    function safeVCTTransfer(address _to, uint256 _amount) internal {
        uint VCTBal = vct.balanceOf(address(this));
        if (_amount > VCTBal) {
            vct.transfer(_to, VCTBal);
        } else {
            vct.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }
}
