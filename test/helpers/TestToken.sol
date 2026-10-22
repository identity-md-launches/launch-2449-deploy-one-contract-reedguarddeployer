// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @dev Test fixture only. No token is part of the launch.
contract TestToken is ERC20 {
    constructor(uint8 decimals_) ERC20("Test asset", "TEST", decimals_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
