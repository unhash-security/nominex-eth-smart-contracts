// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12;
pragma experimental ABIEncoderV2;

/**
 * @title RewardScheduleItem
 * @notice Structure defining reward schedule item.
 */

enum NominexPoolIds {
    BONUS_POOL,
    AFFILIATE_TEAM_STAKING_POOL,
    FUNDING_TEAM_POOL,
    OPERATIONAL_FUND_POOL,
    RESERVE_FUND_POOL
}

struct RewardScheduleItem {
        uint16 repeatCount;
        uint32 blockCount;
        uint rewardRate;
        int128 repeatMultiplier;
        int128[5] poolRewardRates;
}

struct RewardSchedule {
    uint64 distributionStartBlock;
    RewardScheduleItem[] items;
}

library ScheduleLib {
    function copyFromMemoryToStorage(RewardSchedule memory mem, RewardSchedule storage stg) public {
        stg.distributionStartBlock = mem.distributionStartBlock;
        delete stg.items;
        for (uint i = 0; i < mem.items.length; ++i) {
            stg.items.push(mem.items[i]);
        }
    }
}