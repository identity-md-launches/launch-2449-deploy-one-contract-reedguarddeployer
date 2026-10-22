// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {ReedGuard} from "./ReedGuard.sol";
import {HookFlags} from "./HookFlags.sol";

/// @notice Deploy this contract once. Its constructor mines and creates the hook atomically.
/// @dev No salt input, external dependency calls, post-launch initializer or deployment function.
contract ReedGuardDeployer {
    error HookDeploymentFailed();

    address public immutable hook;

    event HookDeployed(address indexed hook, bytes32 salt);

    constructor(IPoolManager poolManager_, address owner_, address feeRecipient_) {
        bytes memory initCode =
            abi.encodePacked(type(ReedGuard).creationCode, abi.encode(poolManager_, owner_, feeRecipient_));
        bytes32 initCodeHash = keccak256(initCode);
        uint160 flags = HookFlags.REED_GUARD;
        uint160 mask = HookFlags.ALL;
        address deployed;
        bytes32 salt = bytes32(0);

        // Reuse one 85-byte preimage: no growing allocation in the mining loop.
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(248, 0xff))
            mstore(add(ptr, 1), shl(96, address()))
            mstore(add(ptr, 53), initCodeHash)
            for {} 1 { salt := add(salt, 1) } {
                mstore(add(ptr, 21), salt)
                if eq(and(keccak256(ptr, 85), mask), flags) { break }
            }
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        if (deployed == address(0)) revert HookDeploymentFailed();
        hook = deployed;
        emit HookDeployed(deployed, salt);
    }
}
