// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title IMD6900 - Identity.MD 6900 on Robinhood Chain
/// @notice A plain token: one billion minted once, to the launch, in the constructor. No owner, no mint, no tax, no
///         pause, no blacklist, no limits, no proxy: nothing anyone can change after it exists. Holders may burn their
///         own (the pool burns the trading fees it earns in IMD6900).
contract IMD6900 is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    constructor(address to) {
        _mint(to, SUPPLY);
    }

    function name() public pure override returns (string memory) {
        return "Identity.MD 6900";
    }

    function symbol() public pure override returns (string memory) {
        return "IMD6900";
    }

    /// @notice Burns `amount` of the caller's own
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
