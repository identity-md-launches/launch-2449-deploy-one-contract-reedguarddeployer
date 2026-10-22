// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev Local integration fixture, not a launch contract or production router.
/// Pulls only from msg.sender in its entry points; settles from its own balance.
contract TestRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData, uint256 maxTokenIn)
        external
        payable
        returns (BalanceDelta delta)
    {
        uint256 ethBefore = address(this).balance - msg.value;
        IERC20Minimal asset = IERC20Minimal(Currency.unwrap(key.currency1));
        uint256 tokenBefore = asset.balanceOf(address(this));
        if (maxTokenIn > 0) require(asset.transferFrom(msg.sender, address(this), maxTokenIn));
        delta = abi.decode(
            manager.unlock(abi.encode(uint8(0), key, abi.encode(params, hookData))), (BalanceDelta)
        );
        _refund(asset, ethBefore, tokenBefore);
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory params, uint256 maxTokenIn)
        external
        payable
        returns (BalanceDelta delta)
    {
        uint256 ethBefore = address(this).balance - msg.value;
        IERC20Minimal asset = IERC20Minimal(Currency.unwrap(key.currency1));
        uint256 tokenBefore = asset.balanceOf(address(this));
        if (maxTokenIn > 0) require(asset.transferFrom(msg.sender, address(this), maxTokenIn));
        delta = abi.decode(manager.unlock(abi.encode(uint8(1), key, abi.encode(params))), (BalanceDelta));
        _refund(asset, ethBefore, tokenBefore);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (uint8 action, PoolKey memory key, bytes memory payload) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta delta;
        if (action == 0) {
            (SwapParams memory params, bytes memory hookData) = abi.decode(payload, (SwapParams, bytes));
            delta = manager.swap(key, params, hookData);
        } else {
            (delta,) = manager.modifyLiquidity(key, abi.decode(payload, (ModifyLiquidityParams)), "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 owed = uint256(-int256(delta));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                require(IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), owed));
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(int256(delta)));
        }
    }

    function _refund(IERC20Minimal asset, uint256 ethBefore, uint256 tokenBefore) private {
        uint256 tokenRefund = asset.balanceOf(address(this)) - tokenBefore;
        if (tokenRefund > 0) require(asset.transfer(msg.sender, tokenRefund));
        uint256 ethRefund = address(this).balance - ethBefore;
        if (ethRefund > 0) {
            (bool success,) = msg.sender.call{value: ethRefund}("");
            require(success, "refund failed");
        }
    }

    receive() external payable {}
}
