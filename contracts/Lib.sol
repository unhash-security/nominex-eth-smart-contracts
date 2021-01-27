// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.8.0;

/**
 * @dev kinds of possible pools
 *
 * @param DEFAULT_VALUE - dummy type for null value
 * @param PRIMARY - blockchain based staking. All rules are declared in the  contracts
 * @param BONUS - Nominex platform based staking. All rules are declared and implemented in the Nominex business logic
 * @param TEAM - Nominex partner structure platform based staking. All rules are declared and implemented in the Nominex business logic
 * @param NOMINEX - tokens for Nominex company
 */
enum MintPool {DEFAULT_VALUE, PRIMARY, BONUS, TEAM, NOMINEX}

/**
 * @dev current state of the schedule for each MintPool
 *
 * @param time last invocation time
 * @param itemIndex index of current item in MintSchedule.items
 * @param weekIndex index of current week in current item in MintSchedule.items
 * @param weekStartTime start time of the current week
 * @param nextTickSupply amount of Nmx to be distributed next second
 */
struct MintScheduleState {
    uint40 time;
    uint8 itemIndex;
    uint16 weekIndex;
    uint40 weekStartTime;
    uint128 nextTickSupply;
}
