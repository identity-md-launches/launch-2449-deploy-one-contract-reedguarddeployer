// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {ReedGuard} from "../../src/ReedGuard.sol";

/// @dev Test-only router. Every operation below runs inside a single actual manager unlock.
/// It buys with its caller's ETH and refunds that caller; it never pulls another payer's tokens.
contract BatchProbe is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    enum Settlement {
        AfterEach,
        AfterBatch,
        Omit
    }

    IPoolManager public immutable manager;
    uint256 public checkedSwaps;
    uint256 public checkedUnlocks;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function buy(PoolKey[] memory keys, uint256[] memory amounts, Settlement settlement)
        external
        payable
        returns (BalanceDelta[] memory deltas)
    {
        require(keys.length != 0 && keys.length == amounts.length, "invalid batch");
        deltas = abi.decode(
            manager.unlock(abi.encode(uint8(0), abi.encode(keys, amounts, settlement))), (BalanceDelta[])
        );
        for (uint256 i; i < keys.length; ++i) {
            IERC20Minimal token = IERC20Minimal(Currency.unwrap(keys[i].currency1));
            uint256 balance = token.balanceOf(address(this));
            if (balance != 0) require(token.transfer(msg.sender, balance), "token refund");
        }
        uint256 refund = address(this).balance;
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "ETH refund");
        }
    }

    function claimInsideUnlock(ReedGuard hook, PoolId id) external returns (bool, bytes memory) {
        return abi.decode(manager.unlock(abi.encode(uint8(1), abi.encode(hook, id))), (bool, bytes));
    }

    /// @dev Creates genuinely backed, unsolicited ERC-6909 claims without changing hook storage.
    function donateClaims(address recipient) external payable {
        manager.unlock(abi.encode(uint8(2), abi.encode(recipient, msg.value)));
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external payable {
        if (amount1 != 0) {
            require(
                IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), amount1)
            );
        }
        manager.unlock(abi.encode(uint8(3), abi.encode(key, amount0, amount1)));
        uint256 refund = address(this).balance;
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "ETH refund");
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == address(manager), "only manager");
        require(manager.isUnlocked(), "observations must be inside unlock");
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == 0) {
            (PoolKey[] memory keys, uint256[] memory amounts, Settlement settlement) =
                abi.decode(payload, (PoolKey[], uint256[], Settlement));
            BalanceDelta[] memory deltas = new BalanceDelta[](keys.length);
            for (uint256 i; i < keys.length; ++i) {
                require(amounts[i] <= uint256(type(int256).max), "amount too big");
                deltas[i] = manager.swap(
                    keys[i], SwapParams(true, -int256(amounts[i]), TickMath.MIN_SQRT_PRICE + 1), ""
                );
                // Checked before leaving this transaction: transient storage has not been cleared.
                require(
                    manager.currencyDelta(address(keys[i].hooks), keys[i].currency0) == 0, "hook ETH debt"
                );
                require(
                    manager.currencyDelta(address(keys[i].hooks), keys[i].currency1) == 0, "hook token debt"
                );
                ++checkedSwaps;
                if (settlement == Settlement.AfterEach) _settleKey(keys[i]);
            }
            if (settlement == Settlement.AfterBatch) {
                for (uint256 i; i < keys.length; ++i) {
                    _settleKey(keys[i]);
                }
            }
            result = abi.encode(deltas);
            // Deliberately leave debt for PoolManager to reject in the Omit scenario.
            if (settlement == Settlement.Omit) return result;
        } else if (action == 1) {
            (ReedGuard hook, PoolId id) = abi.decode(payload, (ReedGuard, PoolId));
            (bool ok, bytes memory reason) = address(hook).call(abi.encodeCall(ReedGuard.claimFees, (id)));
            result = abi.encode(ok, reason);
        } else if (action == 2) {
            (address recipient, uint256 amount) = abi.decode(payload, (address, uint256));
            manager.mint(recipient, 0, amount);
            _settle(Currency.wrap(address(0)));
        } else {
            (PoolKey memory key, uint256 amount0, uint256 amount1) =
                abi.decode(payload, (PoolKey, uint256, uint256));
            manager.donate(key, amount0, amount1, "");
            _settleKey(key);
        }
        require(manager.getNonzeroDeltaCount() == 0, "unsettled currency");
        ++checkedUnlocks;
    }

    function _settleKey(PoolKey memory key) private {
        _settle(key.currency0);
        _settle(key.currency1);
    }

    function _settle(Currency currency) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: uint256(-delta)}();
            } else {
                require(IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), uint256(-delta)));
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(delta));
        }
    }

    receive() external payable {}
}
