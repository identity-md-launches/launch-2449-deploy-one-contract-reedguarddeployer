// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BatchFixture} from "./helpers/BatchFixture.sol";
import {BatchProbe} from "./helpers/BatchProbe.sol";
import {
    PoolKey,
    PoolId,
    BalanceDelta,
    IPoolManager,
    IHooks,
    ReedGuard,
    StateLibrary
} from "./helpers/Fixture.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract ReedGuardTransactionsTest is BatchFixture {
    using StateLibrary for IPoolManager;

    function test_batchDefersBothPoolsBeforeRouterSettlesETH() public {
        _checkBatch(1 ether, 2 ether, false);
    }

    function test_batchWithSettlementBetweenSwapsPaysSecondFeeDirectly() public {
        _checkBatch(1 ether, 2 ether, true);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_batchPaymentTimingAndPoolIsolation(uint96 a, uint96 b, bool settleEach) public {
        _checkBatch(bound(a, 0.01 ether, 3 ether), bound(b, 100, 0.1 ether), settleEach);
    }

    function _checkBatch(uint256 a, uint256 b, bool settleEach) private {
        (PoolKey[] memory keys, uint256[] memory amounts) = _twoPools(key, sameTokenKey, a, b);
        uint256 recipientBefore = OWNER.balance;
        uint256 walletBefore = alice.balance;
        vm.prank(alice, alice);
        BalanceDelta[] memory deltas = batch.buy{value: a + b}(
            keys, amounts, settleEach ? BatchProbe.Settlement.AfterEach : BatchProbe.Settlement.AfterBatch
        );
        assertEq(int256(deltas[0].amount0()), -int256(a));
        assertEq(int256(deltas[1].amount0()), -int256(b));
        assertGt(deltas[0].amount1(), 0);
        assertGt(deltas[1].amount1(), 0);
        // Simple integer division is an independent oracle for exactly one percent.
        uint256 firstFee = a / 100;
        uint256 secondFee = b / 100;
        uint256 paid = settleEach ? secondFee : 0;
        assertEq(OWNER.balance - recipientBefore, paid);
        assertEq(walletBefore - alice.balance, a + b);
        assertEq(address(manager).balance, a + b - paid);
        assertEq(hook.claimableFees(key.toId()), firstFee);
        assertEq(hook.claimableFees(sameTokenKey.toId()), secondFee - paid);
        assertEq(hook.claimableFees(secondKey.toId()), 0);
        assertEq(manager.balanceOf(address(hook), 0), firstFee + secondFee - paid);
        assertEq(hook.nextSwapAt(key.toId(), alice), block.timestamp + 30);
        assertEq(hook.nextSwapAt(sameTokenKey.toId(), alice), block.timestamp + 30);
        assertEq(hook.nextSwapAt(secondKey.toId(), alice), 0);
        assertEq(hook.nextSwapAt(key.toId(), address(batch)), 0);
        assertEq(batch.checkedSwaps(), 2, "checked hook debts inside unlock");
        assertEq(batch.checkedUnlocks(), 1, "checked settlement before transient storage cleared");
        assertEq(address(batch).balance, 0);
        assertEq(asset.balanceOf(address(batch)), 0);

        vm.startPrank(bob);
        assertEq(hook.claimFees(sameTokenKey.toId()), secondFee - paid);
        assertEq(hook.claimableFees(key.toId()), firstFee, "claim cannot consume the other pool");
        assertEq(hook.claimFees(key.toId()), firstFee);
        vm.stopPrank();
        assertEq(OWNER.balance - recipientBefore, firstFee + secondFee);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        _assertSettled();
    }

    function test_twoPoolsWithDifferentTokensShareOnlyETHSettlement() public {
        (PoolKey[] memory keys, uint256[] memory amounts) = _twoPools(key, secondKey, 1 ether, 2 ether);
        uint256 firstBalance = asset.balanceOf(alice);
        uint256 secondBalance = secondAsset.balanceOf(alice);
        vm.prank(alice, alice);
        BalanceDelta[] memory deltas =
            batch.buy{value: 3 ether}(keys, amounts, BatchProbe.Settlement.AfterBatch);
        assertEq(asset.balanceOf(alice) - firstBalance, uint256(int256(deltas[0].amount1())));
        assertEq(secondAsset.balanceOf(alice) - secondBalance, uint256(int256(deltas[1].amount1())));
        assertEq(hook.claimableFees(key.toId()), 0.01 ether);
        assertEq(hook.claimableFees(secondKey.toId()), 0.02 ether);
        assertEq(hook.claimableFees(sameTokenKey.toId()), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0.03 ether);
        assertEq(batch.checkedUnlocks(), 1);
        assertEq(secondAsset.balanceOf(address(batch)), 0);
    }

    function test_repeatedPoolInOneTransactionRevertsEntireBatch() public {
        (PoolKey[] memory keys, uint256[] memory amounts) = _twoPools(key, key, 1 ether, 2 ether);
        vm.prank(alice, alice);
        vm.expectRevert(
            _wrapped(
                abi.encodeWithSelector(
                    ReedGuard.SwapTooSoon.selector, key.toId(), alice, block.timestamp + 30
                )
            )
        );
        batch.buy{value: 3 ether}(keys, amounts, BatchProbe.Settlement.AfterEach);
        _assertFreshRollback();
        // The failed transaction did not use up the origin's first swap.
        _swap(alice, key, true, -1 ether);
        assertEq(hook.nextSwapAt(key.toId(), alice), block.timestamp + 30);
    }

    function test_secondPoolFailureRollsBackFirstPoolsClaimsAndPrice() public {
        (uint160 priceBefore,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        vm.prank(OWNER);
        hook.pause(sameTokenKey.toId());
        (PoolKey[] memory keys, uint256[] memory amounts) = _twoPools(key, sameTokenKey, 1 ether, 2 ether);
        vm.prank(alice, alice);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(ReedGuard.PoolPaused.selector, sameTokenKey.toId())));
        batch.buy{value: 3 ether}(keys, amounts, BatchProbe.Settlement.AfterBatch);
        _assertFreshRollback();
        (uint160 priceAfter,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(priceAfter, priceBefore);
        assertTrue(hook.paused(sameTokenKey.toId()), "earlier owner transaction remains applied");
        assertFalse(hook.paused(key.toId()));
    }

    function test_unsettledSwapCannotLeaveMintedFeesOrCooldownBehind() public {
        (PoolKey[] memory keys, uint256[] memory amounts) = _twoPools(key, sameTokenKey, 1 ether, 2 ether);
        vm.prank(alice, alice);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        batch.buy{value: 3 ether}(keys, amounts, BatchProbe.Settlement.Omit);
        _assertFreshRollback();
        _checkBatch(1 ether, 2 ether, false);
    }

    function test_unsettledSwapRollsBackFeeAlreadySentToRecipient() public {
        _swap(bob, secondKey, true, -1 ether);
        hook.claimFees(secondKey.toId());
        uint256 recipientBefore = OWNER.balance;
        uint256 managerBefore = address(manager).balance;
        uint256 walletBefore = alice.balance;
        uint256 tokenBefore = asset.balanceOf(alice);
        (uint160 priceBefore,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        (PoolKey[] memory keys, uint256[] memory amounts) = _twoPools(key, sameTokenKey, 1 ether, 2 ether);
        vm.prank(alice, alice);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        batch.buy{value: 3 ether}(keys, amounts, BatchProbe.Settlement.Omit);
        assertEq(OWNER.balance, recipientBefore);
        assertEq(address(manager).balance, managerBefore);
        assertEq(alice.balance, walletBefore);
        assertEq(asset.balanceOf(alice), tokenBefore);
        assertEq(hook.nextSwapAt(key.toId(), alice), 0);
        assertEq(hook.nextSwapAt(sameTokenKey.toId(), alice), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        (uint160 priceAfter,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(priceAfter, priceBefore);
        _swap(alice, key, true, -1 ether);
        assertEq(OWNER.balance - recipientBefore, 0.01 ether, "payment guard rolls back too");
    }

    function test_claimDuringExistingUnlockFailsAtomicallyAndCanBeRetried() public {
        _swap(alice, key, true, -1 ether);
        uint256 recipientBefore = OWNER.balance;
        uint256 cashBefore = address(manager).balance;
        (bool ok, bytes memory reason) = batch.claimInsideUnlock(hook, key.toId());
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(IPoolManager.AlreadyUnlocked.selector));
        assertEq(hook.claimableFees(key.toId()), 0.01 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.01 ether);
        assertEq(address(manager).balance, cashBefore);
        assertEq(OWNER.balance, recipientBefore);
        vm.prank(bob);
        assertEq(hook.claimFees(key.toId()), 0.01 ether);
        assertEq(OWNER.balance - recipientBefore, 0.01 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        _swap(bob, key, true, -1 ether);
        assertEq(OWNER.balance - recipientBefore, 0.02 ether);
    }

    function _assertFreshRollback() private view {
        assertEq(alice.balance, FUNDS);
        assertEq(asset.balanceOf(alice), FUNDS);
        assertEq(address(manager).balance, 0);
        assertEq(hook.claimableFees(key.toId()), 0);
        assertEq(hook.claimableFees(sameTokenKey.toId()), 0);
        assertEq(hook.nextSwapAt(key.toId(), alice), 0);
        assertEq(hook.nextSwapAt(sameTokenKey.toId(), alice), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(batch.checkedSwaps(), 0);
        assertEq(address(batch).balance, 0);
        assertEq(asset.balanceOf(address(batch)), 0);
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
}
