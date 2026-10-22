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
    IHooks
} from "./helpers/Fixture.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract ReedGuardControlsTest is Fixture {
    function test_onlyRequiredPermissionsAndCorrectAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), 0x20cc);
        assertTrue(HookFlags.matches(address(hook), HookFlags.REED_GUARD));
    }

    function test_anyoneMayInitializeNativePoolAndTokenSupplyIsLive() public {
        PoolKey memory another = key;
        another.fee = 12_500;
        vm.prank(bob);
        manager.initialize(another, PRICE);
        assertEq(hook.token(another.toId()), address(asset));
        assertEq(hook.token(secondKey.toId()), address(secondAsset));
        assertEq(hook.totalSupply(another.toId()), asset.totalSupply());
        assertEq(hook.totalSupply(secondKey.toId()), secondAsset.totalSupply());
        asset.mint(alice, 7);
        assertEq(hook.totalSupply(another.toId()), asset.totalSupply());
        assertEq(hook.totalSupply(key.toId()), asset.totalSupply());
    }

    function test_erc20PairInitializationReverts() public {
        PoolKey memory invalid = key;
        (address low, address high) = address(asset) < address(secondAsset)
            ? (address(asset), address(secondAsset))
            : (address(secondAsset), address(asset));
        invalid.currency0 = Currency.wrap(low);
        invalid.currency1 = Currency.wrap(high);
        vm.expectRevert(
            _wrapped(
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(ReedGuard.NativeETHPairRequired.selector)
            )
        );
        manager.initialize(invalid, PRICE);
        vm.expectRevert(abi.encodeWithSelector(ReedGuard.UnknownPool.selector, invalid.toId()));
        hook.token(invalid.toId());
    }

    function test_pauseIsOwnerOnlyAndPoolSpecific() public {
        vm.prank(alice);
        vm.expectRevert(ReedGuard.OnlyOwner.selector);
        hook.pause(key.toId());
        vm.prank(alice, OWNER);
        vm.expectRevert(ReedGuard.OnlyOwner.selector);
        hook.pause(key.toId());
        vm.prank(OWNER);
        hook.pause(key.toId());
        assertTrue(hook.paused(key.toId()));
        assertFalse(hook.paused(secondKey.toId()));
        assertFalse(hook.paused(sameTokenKey.toId()));
        vm.expectRevert(
            _wrapped(
                IHooks.beforeSwap.selector, abi.encodeWithSelector(ReedGuard.PoolPaused.selector, key.toId())
            )
        );
        _swap(alice, key, true, -1 ether);
        _swap(alice, secondKey, true, -1 ether);
        _swap(alice, sameTokenKey, true, -1 ether);
        vm.prank(alice);
        vm.expectRevert(ReedGuard.OnlyOwner.selector);
        hook.unpause(key.toId());
        vm.prank(OWNER);
        hook.unpause(key.toId());
        assertFalse(hook.paused(key.toId()));
        _swap(alice, key, true, -1 ether);
        _assertSettled();
    }

    function test_pauseNeverBlocksWithdrawalOrLPFeeCollection() public {
        _swap(alice, key, true, -1 ether);
        vm.prank(OWNER);
        hook.pause(key.toId());
        uint256 beforeFee = OWNER.balance;
        BalanceDelta collected = router.modify(key, ModifyLiquidityParams(-600, 600, 0, bytes32(0)), 0);
        assertGe(collected.amount0(), 0);
        assertGe(collected.amount1(), 0);
        BalanceDelta removed =
            router.modify(key, ModifyLiquidityParams(-600, 600, -10_000 ether, bytes32(0)), 0);
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        assertEq(OWNER.balance, beforeFee, "no fee on liquidity operations");
        _assertSettled();
    }

    function test_liquidityCanAlsoBeAddedWhilePaused() public {
        vm.prank(OWNER);
        hook.pause(key.toId());
        router.modify{value: 1 ether}(key, ModifyLiquidityParams(-600, 600, 1 ether, bytes32(0)), 1 ether);
        _assertSettled();
    }

    function test_cooldownBoundaryAndBothSwapDirections() public {
        _swap(alice, key, true, -1 ether);
        uint256 allowed = hook.nextSwapAt(key.toId(), alice);
        assertEq(allowed, 1_030);
        vm.warp(allowed - 1);
        vm.expectRevert(
            _wrapped(
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ReedGuard.SwapTooSoon.selector, key.toId(), alice, allowed)
            )
        );
        _swap(alice, key, false, -1 ether);
        assertEq(hook.nextSwapAt(key.toId(), alice), allowed);
        vm.warp(allowed);
        _swap(alice, key, false, -1 ether);
        assertEq(hook.nextSwapAt(key.toId(), alice), allowed + 30);
    }

    function test_cooldownIsByOriginAndPoolNotTokenOrRouter() public {
        _swap(alice, key, true, -1 ether);
        _swap(bob, key, true, -1 ether);
        _swap(alice, secondKey, true, -1 ether);
        _swap(alice, sameTokenKey, true, -1 ether);
        assertEq(hook.nextSwapAt(key.toId(), alice), 1_030);
        assertEq(hook.nextSwapAt(key.toId(), bob), 1_030);
        assertEq(hook.nextSwapAt(secondKey.toId(), alice), 1_030);
        assertEq(hook.nextSwapAt(sameTokenKey.toId(), alice), 1_030);
        assertEq(hook.nextSwapAt(key.toId(), address(router)), 0);

        // A different payer and fabricated hookData cannot substitute for the origin.
        vm.prank(bob, alice);
        vm.expectRevert();
        router.swap{value: 1 ether}(
            key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), abi.encode(bob), 0
        );

        // A different router cannot reset the same origin's timer.
        TestRouter otherRouter = new TestRouter(manager);
        vm.prank(alice, alice);
        vm.expectRevert();
        otherRouter.swap{value: 1 ether}(key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), "", 0);
    }

    function test_unpausingDoesNotResetCooldown() public {
        _swap(alice, key, true, -1 ether);
        vm.startPrank(OWNER);
        hook.pause(key.toId());
        hook.unpause(key.toId());
        vm.stopPrank();
        assertEq(hook.nextSwapAt(key.toId(), alice), 1_030);
        vm.expectRevert();
        _swap(alice, key, true, -1 ether);
    }

    function test_unknownPoolCannotBeConfiguredOrClaimed() public {
        PoolId unknown = PoolId.wrap(keccak256("not initialized"));
        bytes memory reason = abi.encodeWithSelector(ReedGuard.UnknownPool.selector, unknown);
        vm.prank(OWNER);
        vm.expectRevert(reason);
        hook.pause(unknown);
        vm.prank(OWNER);
        vm.expectRevert(reason);
        hook.unpause(unknown);
        vm.expectRevert(reason);
        hook.claimFees(unknown);
        vm.expectRevert(reason);
        hook.totalSupply(unknown);
        assertFalse(hook.paused(unknown));
        assertEq(hook.nextSwapAt(unknown, alice), 0);
        assertEq(hook.claimableFees(unknown), 0);
    }

    function test_everyImplementedCallbackRefusesNonManager() public {
        SwapParams memory p = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(ReedGuard.OnlyPoolManager.selector);
        hook.beforeInitialize(alice, key, PRICE);
        vm.expectRevert(ReedGuard.OnlyPoolManager.selector);
        hook.beforeSwap(alice, key, p, "");
        vm.expectRevert(ReedGuard.OnlyPoolManager.selector);
        hook.afterSwap(alice, key, p, BalanceDelta.wrap(0), "");
        vm.expectRevert(ReedGuard.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(key.toId(), 1 ether));
        vm.prank(address(manager));
        vm.expectRevert(ReedGuard.UnexpectedUnlock.selector);
        hook.unlockCallback(abi.encode(key.toId(), 1 ether));
    }

    function test_ownerHasNoOtherAdministrativeFunctions() public {
        bytes[] memory calls = new bytes[](8);
        calls[0] = abi.encodeWithSignature("transferOwnership(address)", alice);
        calls[1] = abi.encodeWithSignature("renounceOwnership()");
        calls[2] = abi.encodeWithSignature("setFee(uint256)", 5_000);
        calls[3] = abi.encodeWithSignature("setFeeRecipient(address)", alice);
        calls[4] = abi.encodeWithSignature("upgradeTo(address)", alice);
        calls[5] = abi.encodeWithSignature("withdraw(address,uint256)", alice, 1 ether);
        calls[6] = abi.encodeWithSignature("setCooldown(uint256)", 0);
        calls[7] = abi.encodeWithSignature("pause()");
        vm.startPrank(OWNER);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(hook).call(calls[i]);
            assertFalse(ok);
        }
        vm.stopPrank();
        assertEq(hook.owner(), OWNER);
        assertEq(hook.feeRecipient(), OWNER);
    }

    function _wrapped(bytes4 selector, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            selector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}
