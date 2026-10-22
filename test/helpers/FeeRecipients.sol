// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReedGuard} from "../../src/ReedGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract SwitchableRecipient {
    bool public rejecting = true;

    function setRejecting(bool value) external {
        rejecting = value;
    }

    receive() external payable {
        require(!rejecting, "recipient rejects ETH");
    }
}

contract ReentrantRecipient {
    ReedGuard public hook;
    IPoolManager public manager;
    PoolKey private _key;
    bool public claimSucceeded;
    bool public swapSucceeded;
    uint256 public attempts;

    function configure(ReedGuard hook_, IPoolManager manager_, PoolKey memory key_) external {
        hook = hook_;
        manager = manager_;
        _key = key_;
    }

    receive() external payable {
        attempts++;
        (claimSucceeded,) = address(hook).call(abi.encodeCall(ReedGuard.claimFees, (_key.toId())));
        (swapSucceeded,) = address(manager)
            .call(
                abi.encodeCall(
                    IPoolManager.swap,
                    (_key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), bytes(""))
                )
            );
    }
}
