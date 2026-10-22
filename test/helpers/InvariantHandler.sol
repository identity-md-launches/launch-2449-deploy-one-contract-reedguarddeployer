// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {ReedGuard} from "../../src/ReedGuard.sol";
import {TestRouter} from "./TestRouter.sol";
import {SwitchableRecipient} from "./FeeRecipients.sol";

contract InvariantHandler is Test {
    ReedGuard public immutable hook;
    IPoolManager public immutable manager;
    TestRouter public immutable router;
    SwitchableRecipient public immutable recipient;
    PoolKey[3] private _keys;
    address[2] private _wallets;
    mapping(PoolId => uint256) public expectedClaims;
    mapping(PoolId => bool) public expectedPaused;
    mapping(PoolId => mapping(address => uint256)) public expectedNext;
    uint256 public totalFees;
    uint256 public successfulSwaps;
    uint256 public refusedSwaps;
    uint256 public redeemed;

    constructor(
        ReedGuard hook_,
        TestRouter router_,
        SwitchableRecipient recipient_,
        PoolKey[3] memory keys_,
        address[2] memory wallets_
    ) {
        hook = hook_;
        manager = hook_.poolManager();
        router = router_;
        recipient = recipient_;
        _keys = keys_;
        _wallets = wallets_;
    }

    function advance(uint32 elapsed) external {
        vm.warp(block.timestamp + bound(uint256(elapsed), 0, 90));
    }

    function pausePool(uint8 pool, bool value) external {
        PoolId id = _keys[pool % 3].toId();
        vm.prank(hook.owner());
        if (value) hook.pause(id);
        else hook.unpause(id);
        expectedPaused[id] = value;
    }

    function rejectPayment(bool value) external {
        recipient.setRejecting(value);
    }

    function trade(uint8 pool, uint8 actor, bool buy, bool exactInput, uint96 amount) external {
        PoolKey memory key = _keys[pool % 3];
        PoolId id = key.toId();
        address wallet = _wallets[actor % 2];
        uint256 size = bound(uint256(amount), 1_000, 0.1 ether);
        int256 specified = exactInput ? -int256(size) : int256(size);
        bytes memory data = abi.encodeCall(
            TestRouter.swap,
            (
                key,
                SwapParams(buy, specified, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                bytes(""),
                buy ? 0 : 1 ether
            )
        );
        bool shouldRefuse = expectedPaused[id] || block.timestamp < expectedNext[id][wallet];
        uint256 recipientBefore = address(recipient).balance;
        vm.recordLogs();
        vm.prank(wallet, wallet);
        (bool ok, bytes memory result) = address(router).call{value: buy ? 1 ether : 0}(data);
        assertEq(ok, !shouldRefuse, "swap accepted/refused exactly according to pool controls");
        if (shouldRefuse) {
            refusedSwaps++;
            assertEq(hook.claimableFees(id), expectedClaims[id]);
            assertEq(hook.nextSwapAt(id, wallet), expectedNext[id][wallet]);
            return;
        }

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        int128 raw0;
        int128 raw1;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager)
                    && logs[i].topics[0]
                        == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
            ) {
                (raw0, raw1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
                break;
            }
        }
        assertTrue(found, "successful trade has a real manager swap");
        uint256 base = (exactInput == buy) ? size : uint256(raw0 < 0 ? -int256(raw0) : int256(raw0));
        uint256 fee = FullMath.mulDiv(base, 100, 10_000);
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        assertEq(int256(delta.amount0()), int256(raw0) - int256(fee));
        assertEq(delta.amount1(), raw1);
        uint256 paid = address(recipient).balance - recipientBefore;
        assertEq(paid, recipient.rejecting() ? 0 : fee);
        expectedClaims[id] += fee - paid;
        expectedNext[id][wallet] = block.timestamp + 30;
        totalFees += fee;
        successfulSwaps++;
    }

    function claim(uint8 pool, uint8 actor) external {
        PoolId id = _keys[pool % 3].toId();
        uint256 pending = expectedClaims[id];
        bool shouldRefuse = recipient.rejecting() && pending != 0;
        vm.prank(_wallets[actor % 2]);
        (bool ok, bytes memory result) = address(hook).call(abi.encodeCall(ReedGuard.claimFees, (id)));
        assertEq(ok, !shouldRefuse, "failed redemption rolls back");
        if (!ok) {
            assertEq(hook.claimableFees(id), pending);
            return;
        }
        assertEq(abi.decode(result, (uint256)), pending);
        expectedClaims[id] = 0;
        redeemed += pending;
    }
}
