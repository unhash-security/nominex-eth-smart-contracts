// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.8.0;

library Checks {
    function safe_u64(int128 v) internal pure returns (uint64 r) {
        r = uint64(v);
        assert(int128(r) == v);
    }

    function safe_u128(uint256 v) internal pure returns (uint128 r) {
        assert(v <= type(uint128).max);
        r = uint128(v);
    }
}


library SafeMath128 {
    function sub(uint128 a, uint128 b) internal pure returns (uint128) {
        assert(a >= b);
        return a - b;
    }

    function mul(uint128 a, uint128 b) internal pure returns (uint128 r) {
        if (a == 0) {
            return 0;
        }
        r = a * b;
        assert(r / a == b);
    }
}
