// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ReedGuard} from "../../src/ReedGuard.sol";
import {TestRouter} from "./TestRouter.sol";
import {BatchProbe} from "./BatchProbe.sol";

/// @dev Drives real pools through liquidity exhaustion/refill, trades, controls and claims.
/// No balances/storage are injected during the random campaign.
contract LiquidityHandler is Test {
    using StateLibrary for IPoolManager;
    ReedGuard public immutable hook;
    IPoolManager public immutable manager;
    TestRouter public immutable router;
    BatchProbe public immutable batch;
    PoolKey[3] private _keys;
    address[2] private _wallets;
    mapping(PoolId => uint256) public expectedLiquidity;
    mapping(PoolId => uint256) public expectedClaims;
    mapping(PoolId => bool) public expectedPaused;
    mapping(PoolId => mapping(address => uint256)) public expectedNext;
    uint256 public totalFees;
    uint256 public donatedClaims;
    uint256 public traded;
    uint256 public refused;
    uint256 public removed;
    uint256 public added;
    uint256 public redeemed;

    constructor(
        ReedGuard hook_,
        TestRouter router_,
        BatchProbe batch_,
        PoolKey[3] memory keys_,
        address[2] memory wallets_
    ) {
        hook = hook_;
        manager = hook_.poolManager();
        router = router_;
        batch = batch_;
        _keys = keys_;
        _wallets = wallets_;
        for (uint256 i; i < 3; ++i) {
            expectedLiquidity[keys_[i].toId()] = 10_000 ether;
        }
    }

    function advance(uint32 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 0, 60));
    }

    function pausePool(uint8 pool, bool value) external {
        PoolId id = _keys[pool % 3].toId();
        vm.prank(hook.owner());
        if (value) hook.pause(id);
        else hook.unpause(id);
        expectedPaused[id] = value;
    }

    function unauthorizedControl(uint8 pool, uint8 actor, bool pause_) external {
        PoolId id = _keys[pool % 3].toId();
        vm.prank(_wallets[actor % 2], hook.owner());
        (bool ok, bytes memory reason) = address(hook)
            .call(pause_ ? abi.encodeCall(ReedGuard.pause, (id)) : abi.encodeCall(ReedGuard.unpause, (id)));
        assertFalse(ok, "origin cannot grant ownership");
        assertEq(reason, abi.encodeWithSelector(ReedGuard.OnlyOwner.selector));
        assertEq(hook.paused(id), expectedPaused[id]);
    }

    function addLiquidity(uint8 pool, uint96 amount) external {
        PoolKey memory key = _keys[pool % 3];
        uint256 liquidity = bound(amount, 1, 10_000 ether);
        uint256 recipientBefore = hook.feeRecipient().balance;
        router.modify{value: 1_000 ether}(
            key, ModifyLiquidityParams(-600, -60, int256(liquidity), bytes32(0)), 1_000 ether
        );
        expectedLiquidity[key.toId()] += liquidity;
        assertEq(hook.feeRecipient().balance, recipientBefore, "adding liquidity is untaxed");
        ++added;
    }

    function removeLiquidity(uint8 pool, uint96 amount, bool full) external {
        PoolKey memory key = _keys[pool % 3];
        uint256 liquidity = expectedLiquidity[key.toId()];
        if (liquidity == 0) return; // v4 does not permit poking an empty position.
        uint256 withdrawn = full ? liquidity : bound(amount, 0, liquidity);
        uint256 recipientBefore = hook.feeRecipient().balance;
        BalanceDelta delta =
            router.modify(key, ModifyLiquidityParams(-600, -60, -int256(withdrawn), bytes32(0)), 0);
        expectedLiquidity[key.toId()] -= withdrawn;
        assertGe(delta.amount0(), 0);
        assertGe(delta.amount1(), 0);
        assertEq(
            hook.feeRecipient().balance,
            recipientBefore,
            "removal/collection is untaxed, including while paused"
        );
        ++removed;
    }

    function trade(uint8 pool, uint8 actor, bool buy, uint96 amount) external {
        PoolKey memory key = _keys[pool % 3];
        PoolId id = key.toId();
        address wallet = _wallets[actor % 2];
        uint256 size = bound(amount, 1, 0.1 ether);
        // Specify tokens in both directions. Fees have an independent oracle: the actual
        // ETH delta in PoolManager's event, including zero/partial fills in depleted pools.
        SwapParams memory params = SwapParams(
            buy,
            buy ? int256(size) : -int256(size),
            buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        (uint160 price,,,) = manager.getSlot0(id);
        bytes memory expectedError;
        if (expectedPaused[id]) {
            expectedError = _wrapped(abi.encodeWithSelector(ReedGuard.PoolPaused.selector, id));
        } else if (block.timestamp < expectedNext[id][wallet]) {
            expectedError = _wrapped(
                abi.encodeWithSelector(ReedGuard.SwapTooSoon.selector, id, wallet, expectedNext[id][wallet])
            );
        } else if (buy ? price <= params.sqrtPriceLimitX96 : price >= params.sqrtPriceLimitX96) {
            // An empty pool can already be at the absolute price limit after a zero fill.
            // v4 refuses another swap in that direction independently of the hook.
            expectedError = abi.encodeWithSelector(
                Pool.PriceLimitAlreadyExceeded.selector, price, params.sqrtPriceLimitX96
            );
        }
        bool mustRefuse = expectedError.length != 0;
        uint256 recipientBefore = hook.feeRecipient().balance;
        uint256 cashBefore = address(manager).balance;
        vm.recordLogs();
        vm.prank(wallet, wallet);
        (bool ok, bytes memory result) = address(router).call{value: buy ? 1 ether : 0}(
            abi.encodeCall(TestRouter.swap, (key, params, bytes(""), buy ? 0 : 1 ether))
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(ok, !mustRefuse, "bounded trade obeys controls and v4 price limits");
        if (!ok) {
            assertEq(result, expectedError, "unexpected failure must not be hidden by the handler");
            assertEq(hook.feeRecipient().balance, recipientBefore);
            assertEq(address(manager).balance, cashBefore);
            ++refused;
            return;
        }
        (int128 raw0, int128 raw1) = _rawSwap(logs, id);
        uint256 fee = uint256(raw0 < 0 ? -int256(raw0) : int256(raw0)) / 100;
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        assertEq(int256(delta.amount0()), int256(raw0) - int256(fee));
        assertEq(delta.amount1(), raw1, "token side cannot pay a hook fee");
        uint256 paid = cashBefore >= fee ? fee : 0;
        assertEq(hook.feeRecipient().balance - recipientBefore, paid);
        expectedClaims[id] += fee - paid;
        expectedNext[id][wallet] = block.timestamp + 30;
        totalFees += fee;
        if (raw0 != 0 && raw1 != 0) ++traded;
    }

    function claim(uint8 pool, uint8 actor) external {
        PoolId id = _keys[pool % 3].toId();
        uint256 pending = expectedClaims[id];
        uint256 recipientBefore = hook.feeRecipient().balance;
        vm.prank(_wallets[actor % 2]);
        assertEq(hook.claimFees(id), pending, "pool fees remain redeemable after liquidity exits");
        assertEq(hook.feeRecipient().balance - recipientBefore, pending);
        expectedClaims[id] = 0;
        redeemed += pending;
    }

    function donateClaims(uint96 amount) external {
        uint256 value = bound(amount, 1, 0.1 ether);
        batch.donateClaims{value: value}(address(hook));
        donatedClaims += value;
    }

    function _rawSwap(Vm.Log[] memory logs, PoolId id) private view returns (int128, int128) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager) && logs[i].topics.length > 1
                    && logs[i].topics[0]
                        == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
                    && logs[i].topics[1] == PoolId.unwrap(id)
            ) {
                (int128 raw0, int128 raw1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return (raw0, raw1);
            }
        }
        revert("successful trade missing manager event");
    }

    function _wrapped(bytes memory reason) private view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    receive() external payable {}
}
