// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {WETH} from "solmate/tokens/WETH.sol";

// All liquidity provision deposits will be done via the pool
contract Pool is ERC4626 {
    // --- Constants ---

    WETH public immutable weth =
        WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    // --- Constructor ---

    constructor(address exchange) ERC4626(weth, "LP Position", "lp") {
        weth.approve(exchange, type(uint256).max);
    }

    receive() external payable {
        // Allow depositing ETH directly
        weth.deposit{value: msg.value}();
        this.deposit(msg.value, msg.sender);
    }

    // --- ERC4626 Overrides ---

    function totalAssets() public view override returns (uint256) {
        return weth.balanceOf(address(this));
    }
}
