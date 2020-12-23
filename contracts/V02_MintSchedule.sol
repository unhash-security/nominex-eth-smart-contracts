// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.8.0;
pragma experimental ABIEncoderV2;

import "./V02_Lib.sol";
import "abdk-libraries-solidity/ABDKMath64x64.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

struct ScheduleItem {
    uint256 cycleDuration;
    uint96 cyclesCount;
    int128 cycleCompletenessMultiplier;
    int128[] poolShares;
}

contract MintSchedule is Ownable {
    using ABDKMath64x64 for int128;
    int128 private _outputRate = ABDKMath64x64.fromInt(1);
    ScheduleItem[] items;

    constructor() {
        // todo fill the items with actual values
    }

    function setOutputRate(int128 outputRate) external onlyOwner {
        require(
            outputRate <= 1 << 64,
            "NMXMINTSCH: outputRate must be le 1<<64"
        );
        require(outputRate >= 0, "NMXMINTSCH: outputRate must be ge 0");
        _outputRate = outputRate;
    }

    function makeProgress(
        MintScheduleState memory scheduleState,
        uint256 time,
        MintPool pool
    ) external view returns (uint256 nmxSupply, MintScheduleState memory) {
        if (time <= scheduleState.time) return (0, scheduleState);
        while (
            time > scheduleState.time && scheduleState.itemIndex < items.length
        ) {
            if (scheduleState.itemIndex < items.length) { /* FIXME: или условие всегда выполняется или цикл может быть бесконечным */
                ScheduleItem storage item = items[scheduleState.itemIndex];
                uint256 boundary =
                    min(
                        time,
                        scheduleState.cycleStartTime + item.cycleDuration
                    );
                uint256 secondsFromLastUpdate = boundary - scheduleState.time;
                nmxSupply +=
                    secondsFromLastUpdate *
                    uint256(
                        _outputRate.mul(item.poolShares[uint256(pool)]).mul(
                            scheduleState.nextTickSupply
                        )
                    );
                persistStateChange(scheduleState, item, boundary);
            }

        }
        return (nmxSupply >> 64, scheduleState);
    }

    function persistStateChange(
        MintScheduleState memory state,
        ScheduleItem memory item,
        uint256 time
    ) private pure {
        state.time = time;
        if (time == state.cycleStartTime + item.cycleDuration) {
            state.nextTickSupply = ABDKMath64x64.mul(
                state.nextTickSupply,
                item.cycleCompletenessMultiplier
            );
            state.cycleIndex++;
            state.cycleStartTime = time;
            if (state.cycleIndex == item.cyclesCount) {
                state.cycleIndex = 0;
                state.itemIndex++;
            }
        }
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        if (a < b) return a;
        return b;
    }
}
