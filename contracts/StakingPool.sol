// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12 <0.8.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2ERC20.sol";
import "abdk-libraries-solidity/ABDKMath64x64.sol";
import "./ScheduleLib.sol";

contract StakingPool is Ownable {

    struct StakingInfo {
        uint amount;
        uint rewardPaidPerUnitOfStakedCurrency;
        uint claimedReward;
        uint permanentReward;
    }

    struct RewardPool {
        address owner;
        uint value;
    }

    bool public active = false;

    address public rewardToken;
    address public stakingToken;

    address public reinvestContract;

    mapping(address => StakingInfo) public stakingInfoByAddress;

    RewardSchedule public rewardSchedule;

    uint public scheduleItemIndex = 0;
    uint public scheduleItemStartTimestamp = 0;
    uint public scheduleItemRepeatCount = 0;
    uint public rewardRate;

    RewardPool[5] private nominexPools;

    uint public rewardPerUnitOfStakedCurrency = 0;
    uint public lastUpdateTimestamp = 0;
    uint public totalStaked = 0;

    uint public totalDistributed = 0;
    uint public totalReward = 0;
    uint public totalClaimed = 0;

    uint private MULTIPLIER = 1e18;

    event Stake(address indexed owner, uint256 amount);
    event Reinvest(address indexed owner, uint256 amount);
    event ClaimedForReinvest(address indexed owner, uint256 amount);
    event Unstake(address indexed owner, uint256 amount);
    event Claim(address indexed owner, uint256 amount);
    event Activate();
    event Deactivate();

    constructor(address _rewardToken, address _stakingToken) public {
        rewardToken = _rewardToken;
        stakingToken = _stakingToken;
    }

    function setRewardSchedule(RewardSchedule memory _rewardSchedule) external onlyOwner {
        ScheduleLib.copyFromMemoryToStorage(_rewardSchedule, rewardSchedule);
    }

    function stake(uint amount) public {
        require(active, "NMXSTK: POOL_INACTIVE");
        bool transferred = IERC20(stakingToken).transferFrom(msg.sender, address(this), amount);
        require(transferred, "NMXSTK: LP_FAILED_TRANSFER");
        updateState();
        totalStaked += amount;
        changeUserStakeAmount(stakingInfoByAddress[msg.sender], amount);
        emit Stake(msg.sender, amount);
    }

    function stakeWithPermit(uint amount, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
        IUniswapV2ERC20(stakingToken).permit(msg.sender, address(this), amount, deadline, v, r, s);
        stake(amount);
    }

    function unstake(uint amount) external {
        StakingInfo storage stakingInfo = stakingInfoByAddress[msg.sender];
        require(stakingInfo.amount >= amount, "NMXSTK: NOT_ENOUGH_STAKED");
        bool transferred = IERC20(stakingToken).transfer(msg.sender, amount);
        require(transferred, "NMXSTK: LP_FAILED_TRANSFER");
        updateState();
        totalStaked -= amount;
        changeUserStakeAmount(stakingInfo, - amount);
        emit Unstake(msg.sender, amount);
    }

    function activate() external onlyOwner {
        require(!active, "NMXSTK: ALREADY_ACTIVE");
        updateState();
        active = true;
        emit Activate();
    }

    function deactivate() external onlyOwner returns (uint) {
        require(active, "NMXSTK: ALREADY_INACTIVE");
        updateState();
        active = false;
        emit Deactivate();
        return totalReward - totalClaimed;
    }

    function claimReward() external returns (uint reward) {
        updateState();
        StakingInfo storage stakingInfo = stakingInfoByAddress[msg.sender];
        uint userTotalReward = getTotalReward(stakingInfo);
        reward = userTotalReward - stakingInfo.claimedReward;
        bool transferred = IERC20(rewardToken).transferFrom(owner(), msg.sender, reward);
        require(transferred, "NMXSTK: NMX_TRANSFER_FAIlED");
        stakingInfo.claimedReward += reward;
        totalClaimed += reward;
        emit Claim(msg.sender, reward);
    }

    function setReinvestContract(address _reinvestContract) external onlyOwner {
        reinvestContract = _reinvestContract;
    }

    function claimForReinvest(address _owner, uint amount) external {
        require(msg.sender == reinvestContract);
        StakingInfo storage stakingInfo = stakingInfoByAddress[_owner];
        uint userTotalReward = getTotalReward(stakingInfo);
        uint reward = userTotalReward - stakingInfo.claimedReward;
        require(reward > amount, "NMXSTK: NOT_ENOUGH_BALANCE");
        bool transferred = IERC20(rewardToken).transferFrom(owner(), msg.sender, amount);
        require(transferred, "NMXSTK: NMX_TRANSFER_FAIlED");
        stakingInfo.claimedReward += amount;
        totalClaimed += amount;
        emit ClaimedForReinvest(_owner, amount);
    }

    function reinvest(address owner, uint amount) external {
        require(msg.sender == reinvestContract);
        bool transferred = IERC20(stakingToken).transferFrom(msg.sender, address(this), amount);
        require(transferred, "NMXSTK: LP_FAILED_TRANSFER");
        updateState();
        totalStaked += amount;
        changeUserStakeAmount(stakingInfoByAddress[owner], amount);
        emit Reinvest(owner, amount);
    }

    function setPoolOwner(NominexPoolIds poolId, address newPoolOwner) external returns (bool) {
        RewardPool storage pool = nominexPools[uint(poolId)];
        require(owner() == msg.sender || pool.owner == msg.sender, "NMXSTK: NOT_OWNER");
        pool.owner = newPoolOwner;
        return true;
    }

    function claimPoolReward() external {
        updateState();
        for (uint i = 0; i < nominexPools.length; ++i) {
            claimPoolReward(nominexPools[i]);
        }
    }

    function getPoolReward(NominexPoolIds poolId) external returns (uint) {
        updateState();
        return nominexPools[uint(poolId)].value;
    }

    function getUnclaimedReward() external returns (uint) {
        updateState();
        StakingInfo storage stakingInfo = stakingInfoByAddress[msg.sender];
        return getTotalReward(stakingInfo) - stakingInfo.claimedReward;
    }

    function getCurrentStakingRate() external returns (uint) {
        updateState();
        return rewardRate;
    }

    function updateState() private {

        if (block.timestamp <= rewardSchedule.distributionStart ||
        scheduleItemIndex >= rewardSchedule.items.length ||
            block.timestamp <= lastUpdateTimestamp) {
            return;
        }

        uint processingPeriodStart = lastUpdateTimestamp;
        if (scheduleItemStartTimestamp == 0) {
            scheduleItemStartTimestamp = rewardSchedule.distributionStart;
            processingPeriodStart = scheduleItemStartTimestamp;
            rewardRate = rewardSchedule.items[0].rewardRate;
        }

        RewardScheduleItem storage scheduleItem = rewardSchedule.items[scheduleItemIndex];
        do {

            uint timePassedFromScheduleItemStart = block.timestamp - scheduleItemStartTimestamp;
            bool schedulePeriodFinished = timePassedFromScheduleItemStart >= scheduleItem.duration;

            uint processingPeriodEnd = (
                schedulePeriodFinished
                    ? scheduleItemStartTimestamp + scheduleItem.duration
                    : block.timestamp
            );

            if (totalStaked > 0 && active) {
                calculateReward(processingPeriodEnd - processingPeriodStart, scheduleItem);
            }


            if (!schedulePeriodFinished) {
                break;
            }

            processingPeriodStart = processingPeriodEnd;
            scheduleItemStartTimestamp = processingPeriodEnd;
            scheduleItemRepeatCount++;

            if (scheduleItemRepeatCount < scheduleItem.repeatCount) {
                rewardRate = ABDKMath64x64.mulu(scheduleItem.repeatMultiplier, rewardRate);
                continue;
            }

            scheduleItemRepeatCount = 0;
            scheduleItemIndex++;
            if (scheduleItemIndex < rewardSchedule.items.length) {
                scheduleItem = rewardSchedule.items[scheduleItemIndex];
                if (scheduleItem.rewardRate != 0) {
                    rewardRate = scheduleItem.rewardRate;
                } else {
                    rewardRate = ABDKMath64x64.mulu(scheduleItem.repeatMultiplier, rewardRate);
                }
                continue;
            }
            break;
        } while (true);
        lastUpdateTimestamp = block.timestamp;
    }

    function calculateReward(uint duration, RewardScheduleItem storage scheduleItem) private {
        uint reward = duration * rewardRate;
        uint personalReward = reward;

        for (uint i = 0; i < scheduleItem.poolRewardRates.length; ++i) {
            uint poolReward = ABDKMath64x64.mulu(scheduleItem.poolRewardRates[i], reward);
            nominexPools[i].value += poolReward;
            personalReward -= poolReward;
        }

        uint delta = personalReward * MULTIPLIER / totalStaked;
        rewardPerUnitOfStakedCurrency += delta;
        totalReward += reward;
    }

    function changeUserStakeAmount(StakingInfo storage stakingInfo, uint amount) private {
        stakingInfo.permanentReward = getTotalReward(stakingInfo);
        stakingInfo.amount += amount;
        stakingInfo.rewardPaidPerUnitOfStakedCurrency = rewardPerUnitOfStakedCurrency;
    }

    function getTotalReward(StakingInfo storage stakingInfo) private view returns (uint) {
        return (rewardPerUnitOfStakedCurrency - stakingInfo.rewardPaidPerUnitOfStakedCurrency) * stakingInfo.amount / MULTIPLIER + stakingInfo.permanentReward;
    }

    function claimPoolReward(RewardPool storage pool) private {
        if (pool.owner == msg.sender && pool.value > 0) {
            bool transferred = IERC20(rewardToken).transferFrom(owner(), msg.sender, pool.value);
            require(transferred, "NMXSTK: NMX_TRANSFER_FAIlED");
            totalClaimed += pool.value;
            pool.value = 0;
        }
    }

}
