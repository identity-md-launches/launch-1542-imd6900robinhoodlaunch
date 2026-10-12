// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IMD6900RobinhoodLaunch} from "../src/IMD6900RobinhoodLaunch.sol";

/// @dev What script/launch.sh's `hook` step mines with cast, for the tests: the first salt whose CREATE2 address from
///      the launch carries exactly its FLAGS and doesn't start with 0x91
library HookSalt {
    function mine(IMD6900RobinhoodLaunch l) internal view returns (bytes32) {
        return mine(l, 0);
    }

    function mine(IMD6900RobinhoodLaunch l, uint256 from) internal view returns (bytes32 s) {
        bytes32 initHash = l.hookInitCodeHash();
        uint160 flags = l.FLAGS();
        for (uint256 i = from;; ++i) {
            address a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(l), i, initHash)))));
            if (uint160(a) & Hooks.ALL_HOOK_MASK == flags && uint160(a) >> 152 != 0x91) return bytes32(i);
        }
    }
}
