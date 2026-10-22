// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    Fixture,
    PoolKey,
    PoolId,
    Currency,
    BalanceDelta,
    SwapParams,
    ModifyLiquidityParams,
    TickMath,
    ReedGuard,
    ReedGuardDeployer,
    IHooks,
    PoolManager
} from "./helpers/Fixture.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {TestToken} from "./helpers/TestToken.sol";
import {SwitchableRecipient, ReentrantRecipient} from "./helpers/FeeRecipients.sol";

contract ReedGuardClaimsTest is Fixture {
    function setUp() public override {
        vm.warp(1_000);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        manager = new PoolManager(address(this));
        hook = ReedGuard(new ReedGuardDeployer(manager, OWNER, OWNER).hook());
        router = new TestRouter(manager);
        asset = new TestToken(18);
        secondAsset = new TestToken(6);
        key = _key(asset, hook, 3_000);
        secondKey = _key(secondAsset, hook, 12_500);
        _fund(address(this));
        _fund(alice);
        _fund(bob);
        _seedOnlyTokens(key);
        _seedOnlyTokens(secondKey);
        assertEq(address(manager).balance, 0, "fresh manager has never received ETH");
    }

    function _seedOnlyTokens(PoolKey memory poolKey) internal {
        manager.initialize(poolKey, PRICE);
        BalanceDelta delta =
            router.modify(poolKey, ModifyLiquidityParams(-600, -60, 10_000 ether, bytes32(0)), 100_000 ether);
        assertEq(delta.amount0(), 0, "one-sided token liquidity");
        assertLt(delta.amount1(), 0);
    }

    function test_freshManagerBuyMintsETHClaimThenAnyoneRedeems() public {
        uint256 recipientBefore = OWNER.balance;
        BalanceDelta delta = _swap(alice, key, true, -1 ether);
        uint256 fee = _fee(1 ether);
        assertEq(delta.amount0(), -1 ether);
        assertGt(delta.amount1(), 0);
        assertEq(OWNER.balance, recipientBefore);
        assertEq(hook.claimableFees(key.toId()), fee);
        assertEq(manager.balanceOf(address(hook), 0), fee);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(asset)))), 0);
        assertEq(address(manager).balance, 1 ether, "router settled after fee was claimed");
        _assertSettled();

        vm.prank(OWNER);
        hook.pause(key.toId());
        uint256 callerBefore = bob.balance;
        vm.prank(bob);
        assertEq(hook.claimFees(key.toId()), fee);
        assertEq(OWNER.balance - recipientBefore, fee);
        assertEq(bob.balance, callerBefore, "caller cannot redirect proceeds");
        assertEq(hook.claimableFees(key.toId()), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(address(manager).balance, 1 ether - fee);
        assertEq(hook.claimFees(key.toId()), 0, "claim cannot be redeemed twice");
        _assertSettled();
    }

    function test_exactOutputTokenBuyAlsoMintsOnFreshManager() public {
        vm.recordLogs();
        _swap(alice, key, true, 1 ether);
        (int128 actualETH,) = _readSwap(vm.getRecordedLogs());
        uint256 fee = _fee(_abs128(actualETH));
        assertGt(fee, 0);
        assertEq(hook.claimableFees(key.toId()), fee);
        assertEq(manager.balanceOf(address(hook), 0), fee);
        assertEq(hook.claimFees(key.toId()), fee);
        _assertSettled();
    }

    function test_laterFundedSwapPaysImmediatelyAndPreservesEarlierClaim() public {
        _swap(alice, key, true, -1 ether);
        uint256 pending = hook.claimableFees(key.toId());
        uint256 recipientBefore = OWNER.balance;
        _swap(bob, key, true, -2 ether);
        assertEq(OWNER.balance - recipientBefore, _fee(2 ether));
        assertEq(hook.claimableFees(key.toId()), pending);
        assertEq(manager.balanceOf(address(hook), 0), pending);
        _assertSettled();
    }

    function test_nonzeroButInsufficientManagerETHAlsoDefers() public {
        vm.deal(address(manager), 1);
        _swap(alice, key, true, -1 ether);
        assertEq(hook.claimableFees(key.toId()), _fee(1 ether));
        assertEq(manager.balanceOf(address(hook), 0), _fee(1 ether));
        _assertSettled();
    }

    function test_rejectingRecipientCannotBlockSwapsAndFailedClaimIsRetryable() public {
        SwitchableRecipient recipient = new SwitchableRecipient();
        _useRecipient(address(recipient));
        _swap(alice, key, true, -1 ether);
        _swap(bob, key, true, -2 ether); // sufficient manager ETH, but take rejects and rolls back.
        uint256 pending = _fee(1 ether) + _fee(2 ether);
        assertEq(hook.claimableFees(key.toId()), pending);
        assertEq(manager.balanceOf(address(hook), 0), pending);
        assertEq(address(recipient).balance, 0);
        uint256 pmBefore = address(manager).balance;
        vm.expectRevert();
        hook.claimFees(key.toId());
        assertEq(hook.claimableFees(key.toId()), pending);
        assertEq(manager.balanceOf(address(hook), 0), pending, "burn rolled back");
        assertEq(address(manager).balance, pmBefore);
        recipient.setRejecting(false);
        assertEq(hook.claimFees(key.toId()), pending);
        assertEq(address(recipient).balance, pending);
        assertEq(hook.claimableFees(key.toId()), 0);
        _assertSettled();
    }

    function test_claimBalancesAreIsolatedEvenForSameToken() public {
        SwitchableRecipient recipient = new SwitchableRecipient();
        _useRecipient(address(recipient));
        sameTokenKey = _key(asset, hook, 500);
        _seedOnlyTokens(sameTokenKey);
        _swap(alice, key, true, -1 ether);
        _swap(alice, sameTokenKey, true, -2 ether);
        _swap(alice, secondKey, true, -3 ether);
        assertEq(hook.claimableFees(key.toId()), _fee(1 ether));
        assertEq(hook.claimableFees(sameTokenKey.toId()), _fee(2 ether));
        assertEq(hook.claimableFees(secondKey.toId()), _fee(3 ether));
        assertEq(manager.balanceOf(address(hook), 0), _fee(6 ether));
        recipient.setRejecting(false);
        vm.prank(bob);
        hook.claimFees(key.toId());
        assertEq(address(recipient).balance, _fee(1 ether));
        assertEq(hook.claimableFees(key.toId()), 0);
        assertEq(hook.claimableFees(sameTokenKey.toId()), _fee(2 ether));
        assertEq(hook.claimableFees(secondKey.toId()), _fee(3 ether));
        assertEq(manager.balanceOf(address(hook), 0), _fee(5 ether));
        hook.claimFees(secondKey.toId());
        hook.claimFees(sameTokenKey.toId());
        assertEq(address(recipient).balance, _fee(6 ether));
        assertEq(manager.balanceOf(address(hook), 0), 0);
        _assertSettled();
    }

    function test_reentrantRecipientCannotReenterSwapsOrClaims() public {
        ReentrantRecipient recipient = new ReentrantRecipient();
        _useRecipient(address(recipient));
        // Try a different pool too: the payment guard covers external recipient interactions.
        recipient.configure(hook, manager, secondKey);
        _swap(alice, key, true, -1 ether); // manager is empty -> mint; recipient not called.
        assertEq(recipient.attempts(), 0);
        _swap(bob, key, true, -2 ether); // direct take calls recipient.
        assertEq(recipient.attempts(), 1);
        assertFalse(recipient.claimSucceeded());
        assertFalse(recipient.swapSucceeded());
        assertEq(hook.nextSwapAt(secondKey.toId(), bob), 0);
        assertEq(address(recipient).balance, _fee(2 ether));
        hook.claimFees(key.toId());
        assertEq(recipient.attempts(), 2);
        assertFalse(recipient.claimSucceeded());
        assertFalse(recipient.swapSucceeded());
        assertEq(address(recipient).balance, _fee(3 ether));
        assertEq(manager.balanceOf(address(hook), 0), 0);
        _assertSettled();
    }

    function test_emptyClaimDoesNotRequireUnlockOrChangeBalances() public {
        assertEq(hook.claimFees(key.toId()), 0);
        assertEq(hook.claimFees(secondKey.toId()), 0);
        _assertSettled();
    }

    function _useRecipient(address recipient) internal {
        hook = ReedGuard(new ReedGuardDeployer(manager, OWNER, recipient).hook());
        key = _key(asset, hook, 3_000);
        secondKey = _key(secondAsset, hook, 12_500);
        _seedOnlyTokens(key);
        _seedOnlyTokens(secondKey);
    }
}
