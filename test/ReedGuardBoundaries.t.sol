// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BatchFixture} from "./helpers/BatchFixture.sol";
import {TestToken} from "./helpers/TestToken.sol";
import {
    PoolKey,
    PoolId,
    SwapParams,
    ModifyLiquidityParams,
    BalanceDelta,
    TickMath,
    ReedGuard
} from "./helpers/Fixture.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

contract BurnableSupplyProbe is TestToken {
    constructor() TestToken(6) {}

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract ReedGuardBoundariesTest is BatchFixture {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    function test_invalidPriceCannotLeavePhantomPoolRegistered() public {
        PoolKey memory uninitialized = key;
        uninitialized.fee = 500;
        PoolId id = uninitialized.toId();
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, TickMath.MAX_SQRT_PRICE));
        manager.initialize(uninitialized, TickMath.MAX_SQRT_PRICE);
        vm.expectRevert(abi.encodeWithSelector(ReedGuard.UnknownPool.selector, id));
        hook.token(id);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ReedGuard.UnknownPool.selector, id));
        hook.pause(id);
        vm.expectRevert(abi.encodeWithSelector(ReedGuard.UnknownPool.selector, id));
        hook.claimFees(id);
        // The same PoolId can subsequently be initialized successfully by any account.
        vm.prank(bob);
        manager.initialize(uninitialized, PRICE);
        assertEq(hook.token(id), address(asset));
        assertFalse(hook.paused(id));
    }

    function test_duplicateInitializationCannotResetPauseCooldownOrClaims() public {
        _swap(alice, key, true, -1 ether);
        vm.prank(OWNER);
        hook.pause(key.toId());
        vm.prank(bob);
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        manager.initialize(key, PRICE);
        assertTrue(hook.paused(key.toId()));
        assertEq(hook.nextSwapAt(key.toId(), alice), 1_030);
        assertEq(hook.claimableFees(key.toId()), 0.01 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.01 ether);
        assertEq(hook.token(key.toId()), address(asset));
        assertFalse(hook.paused(sameTokenKey.toId()));
    }

    function test_zeroTokenSupplyIsEligibleAndReadWithoutInventedMinimum() public {
        _checkSupply(0);
    }

    function test_maximumTokenSupplyCanBeReadThenBurnedToZero() public {
        _checkSupply(type(uint256).max);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_supplyReadsRemainLiveAcrossMintAndBurn(uint256 supply) public {
        _checkSupply(supply);
    }

    function _checkSupply(uint256 supply) private {
        BurnableSupplyProbe token = new BurnableSupplyProbe();
        PoolKey memory pool = _key(token, hook, 12_500);
        manager.initialize(pool, PRICE);
        assertEq(hook.totalSupply(pool.toId()), 0);
        token.mint(alice, supply);
        assertEq(hook.totalSupply(pool.toId()), supply);
        assertEq(hook.token(pool.toId()), address(token));
        assertEq(hook.totalSupply(key.toId()), asset.totalSupply(), "other pool's supply is unchanged");
        token.burn(alice, supply);
        assertEq(hook.totalSupply(pool.toId()), 0, "supply cannot be cached at initialization or first read");
    }

    function test_supplyReadFailureDoesNotBecomeATradingOrLiquidityDependency() public {
        bytes memory failure = abi.encodeWithSignature("SupplyReadUnavailable()");
        vm.mockCallRevert(address(asset), abi.encodeWithSignature("totalSupply()"), failure);
        vm.expectRevert(failure);
        hook.totalSupply(key.toId());

        PoolKey memory another = key;
        another.fee = 10_000;
        _seedTokens(another);
        _swap(alice, another, true, -1 ether);
        _swap(bob, another, false, -0.1 ether);
        vm.prank(OWNER);
        hook.pause(another.toId());
        router.modify(another, ModifyLiquidityParams(-600, -60, -10_000 ether, bytes32(0)), 0);
        assertGt(hook.claimFees(another.toId()), 0);
        assertEq(hook.totalSupply(secondKey.toId()), secondAsset.totalSupply());
    }

    function test_maximumRepresentableBeforeSwapFeeAndFirstOverflow() public {
        uint256 firstOverflow = (uint256(uint128(type(int128).max)) + 1) * 100;
        _checkFeeCast(firstOverflow - 1, true);
        vm.warp(block.timestamp + 30);
        _checkFeeCast(firstOverflow, false);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_feeCastAtSigned128BitBoundary(uint8 offset, bool buy) public {
        uint256 firstOverflow = (uint256(uint128(type(int128).max)) + 1) * 100;
        _checkFeeCast(firstOverflow - 128 + uint256(offset), buy);
    }

    function _checkFeeCast(uint256 size, bool buy) private {
        uint256 expectedFee = size / 100;
        uint256 nextBefore = hook.nextSwapAt(key.toId(), alice);
        SwapParams memory params = SwapParams(
            buy,
            buy ? -int256(size) : int256(size),
            buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        // Unit-level callback test: these values probe the cast, not economically possible pool liquidity.
        vm.prank(address(manager), alice);
        if (expectedFee > uint256(uint128(type(int128).max))) {
            vm.expectRevert(SafeCast.SafeCastOverflow.selector);
            hook.beforeSwap(alice, key, params, "");
            assertEq(hook.nextSwapAt(key.toId(), alice), nextBefore, "failed cast cannot consume cooldown");
        } else {
            (, BeforeSwapDelta delta, uint24 overrideFee) = hook.beforeSwap(alice, key, params, "");
            assertEq(uint256(int256(delta.getSpecifiedDelta())), expectedFee);
            assertEq(delta.getUnspecifiedDelta(), 0);
            assertEq(overrideFee, 0);
            assertEq(hook.nextSwapAt(key.toId(), alice), block.timestamp + 30);
        }
    }

    function test_feeRoundingAtOneWeiAndEachSideOfWholeFeeBoundaries() public {
        uint256[6] memory amounts = [uint256(1), 99, 100, 101, 199, 200];
        uint256 started = block.timestamp;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 before = OWNER.balance + hook.claimableFees(key.toId());
            BalanceDelta delta = _swap(alice, key, true, -int256(amounts[i]));
            assertEq(int256(delta.amount0()), -int256(amounts[i]));
            assertEq(OWNER.balance + hook.claimableFees(key.toId()) - before, amounts[i] / 100);
            assertEq(asset.balanceOf(OWNER), 0);
            vm.warp(started + (i + 1) * 30);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_redemptionRespectsAvailableCashAndRetainsRemainder(uint96 input, uint96 cash) public {
        uint256 amount = bound(input, 100, 3 ether);
        _swap(alice, key, true, -int256(amount));
        uint256 owed = amount / 100;
        uint256 available = bound(cash, 0, owed);
        uint256 originalCash = address(manager).balance;
        uint256 recipientBefore = OWNER.balance;
        // Fault injection only: a solvent manager normally backs all outstanding claims.
        // This covers ReedGuard's explicit no-cash/partial-redemption recovery branches.
        vm.deal(address(manager), available);
        vm.prank(bob);
        assertEq(hook.claimFees(key.toId()), available);
        assertEq(OWNER.balance - recipientBefore, available);
        assertEq(hook.claimableFees(key.toId()), owed - available);
        assertEq(manager.balanceOf(address(hook), 0), owed - available);
        assertEq(address(manager).balance, 0);
        assertEq(hook.claimFees(key.toId()), 0);
        assertEq(hook.nextSwapAt(key.toId(), alice), 1_030);

        vm.deal(address(manager), originalCash - available);
        assertEq(hook.claimFees(key.toId()), owed - available);
        assertEq(OWNER.balance - recipientBefore, owed);
        assertEq(hook.claimFees(key.toId()), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_unsolicitedClaimsCannotIncreaseAnyPoolsEntitlement() public {
        _swap(alice, key, true, -1 ether);
        vm.prank(bob);
        batch.donateClaims{value: 1 ether}(address(hook));
        assertEq(manager.balanceOf(address(hook), 0), 1.01 ether);
        assertEq(hook.claimableFees(key.toId()), 0.01 ether);
        assertEq(hook.claimFees(sameTokenKey.toId()), 0);
        uint256 recipientBefore = OWNER.balance;
        vm.prank(bob);
        assertEq(hook.claimFees(key.toId()), 0.01 ether);
        assertEq(OWNER.balance - recipientBefore, 0.01 ether);
        assertEq(manager.balanceOf(address(hook), 0), 1 ether);
        assertEq(hook.claimFees(key.toId()), 0, "donation cannot be redeemed as a second fee claim");
        assertEq(hook.claimFees(secondKey.toId()), 0);
    }

    function test_donationsWhilePausedAreUntaxedAndDoNotAlterCooldownOrClaims() public {
        _swap(alice, key, true, -1 ether); // enter the token-only liquidity range
        vm.prank(OWNER);
        hook.pause(key.toId());
        uint256 recipientBefore = OWNER.balance;
        uint256 managerETH = address(manager).balance;
        uint256 managerTokens = asset.balanceOf(address(manager));
        uint256 timerBefore = hook.nextSwapAt(key.toId(), alice);
        uint256 claimsBefore = hook.claimableFees(key.toId());
        vm.startPrank(alice, alice);
        asset.approve(address(batch), 0.2 ether);
        batch.donate{value: 0.1 ether}(key, 0.1 ether, 0.2 ether);
        vm.stopPrank();
        assertEq(address(manager).balance - managerETH, 0.1 ether);
        assertEq(asset.balanceOf(address(manager)) - managerTokens, 0.2 ether);
        assertEq(OWNER.balance, recipientBefore);
        assertEq(hook.nextSwapAt(key.toId(), alice), timerBefore);
        assertEq(hook.claimableFees(key.toId()), claimsBefore);
        assertEq(manager.balanceOf(address(hook), 0), claimsBefore);
        assertEq(batch.checkedUnlocks(), 1);
        BalanceDelta collected = router.modify(key, ModifyLiquidityParams(-600, -60, 0, bytes32(0)), 0);
        assertGe(collected.amount0(), int128(0.1 ether - 1));
        assertGe(collected.amount1(), int128(0.2 ether - 1));
        assertEq(OWNER.balance, recipientBefore);
    }
}
