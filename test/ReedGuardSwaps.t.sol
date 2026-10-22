// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    Fixture,
    Vm,
    PoolKey,
    PoolId,
    IPoolManager,
    BalanceDelta,
    SwapParams,
    ModifyLiquidityParams,
    TickMath,
    StateLibrary,
    ReedGuard
} from "./helpers/Fixture.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

contract ReedGuardSwapsTest is Fixture {
    using StateLibrary for IPoolManager;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    function test_buyExactInputETH() public {
        _checkSwap(true, -1 ether);
    }

    function test_buyExactOutputToken() public {
        _checkSwap(true, 1 ether);
    }

    function test_sellExactInputToken() public {
        _checkSwap(false, -1 ether);
    }

    function test_sellExactOutputETH() public {
        _checkSwap(false, 1 ether);
    }

    function testFuzz_feesAndConservationAcrossAllFourModes(uint96 size, bool buy, bool exactInput) public {
        uint256 amount = bound(uint256(size), 100, 10 ether);
        _checkSwap(buy, exactInput ? -int256(amount) : int256(amount));
    }

    function _checkSwap(bool buy, int256 specified) internal {
        uint256 userETH = alice.balance;
        uint256 userTokens = asset.balanceOf(alice);
        uint256 pmETH = address(manager).balance;
        uint256 pmTokens = asset.balanceOf(address(manager));
        uint256 recipientETH = OWNER.balance;
        uint256 recipientTokens = asset.balanceOf(OWNER);
        vm.recordLogs();
        BalanceDelta result = _swap(alice, key, buy, specified);
        (int128 raw0, int128 raw1) = _readSwap(vm.getRecordedLogs());

        bool ethSpecified = (specified < 0) == buy;
        uint256 fee = _fee(ethSpecified ? uint256(specified < 0 ? -specified : specified) : _abs128(raw0));
        assertEq(OWNER.balance - recipientETH, fee, "fee sent in ETH inside swap");
        assertEq(asset.balanceOf(OWNER), recipientTokens, "recipient takes no token");
        assertEq(int256(result.amount0()), int256(raw0) - int256(fee), "ETH fee charged to swapper");
        assertEq(result.amount1(), raw1, "token side untouched");
        if (ethSpecified) {
            assertEq(int256(raw0), specified + int256(fee), "full adjusted ETH amount traded");
            assertEq(int256(result.amount0()), specified, "specified ETH budget/output honored");
        }
        assertEq(int256(alice.balance) - int256(userETH), int256(result.amount0()));
        assertEq(int256(asset.balanceOf(alice)) - int256(userTokens), int256(result.amount1()));
        assertEq(int256(address(manager).balance) - int256(pmETH), -int256(raw0));
        assertEq(int256(asset.balanceOf(address(manager))) - int256(pmTokens), -int256(raw1));
        assertEq(alice.balance + address(manager).balance + OWNER.balance, userETH + pmETH + recipientETH);
        assertEq(asset.balanceOf(alice) + asset.balanceOf(address(manager)), userTokens + pmTokens);
        assertEq(hook.claimableFees(key.toId()), 0);
        assertEq(hook.nextSwapAt(key.toId(), alice), block.timestamp + 30);
        _assertSettled();
    }

    function test_partialBuyWithETHSpecifiedRevertsAndRollsBack() public {
        _checkPartialETH(true);
    }

    function test_partialSellWithETHSpecifiedRevertsAndRollsBack() public {
        _checkPartialETH(false);
    }

    function _checkPartialETH(bool buy) internal {
        uint256 recipientBefore = OWNER.balance;
        uint256 userETH = alice.balance;
        uint256 userTokens = asset.balanceOf(alice);
        (uint160 priceBefore,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        bytes memory data = abi.encodeCall(
            TestRouter.swap,
            (
                key,
                SwapParams(
                    buy,
                    buy ? -100 ether : int256(100 ether),
                    TickMath.getSqrtPriceAtTick(buy ? int24(-1) : int24(1))
                ),
                bytes(""),
                buy ? 0 : 100 ether
            )
        );
        vm.prank(alice, alice);
        (bool ok, bytes memory reason) = address(router).call{value: buy ? 100 ether : 0}(data);
        assertFalse(ok);
        assertEq(bytes4(reason), CustomRevert.WrappedError.selector);
        (address target, bytes4 callback, bytes memory inner,) =
            abi.decode(_stripSelector(reason), (address, bytes4, bytes, bytes));
        assertEq(target, address(hook));
        assertEq(callback, IHooks.afterSwap.selector);
        assertEq(bytes4(inner), ReedGuard.PartialETHFill.selector);
        (int256 expected, int256 actual) = abi.decode(_stripSelector(inner), (int256, int256));
        assertEq(expected, buy ? -99 ether : int256(101 ether));
        assertGt(actual < 0 ? -actual : actual, 0, "pool traded a nonzero partial amount");
        assertLt(actual < 0 ? -actual : actual, expected < 0 ? -expected : expected);
        assertEq(OWNER.balance, recipientBefore);
        assertEq(alice.balance, userETH);
        assertEq(asset.balanceOf(alice), userTokens);
        assertEq(hook.nextSwapAt(key.toId(), alice), 0);
        assertEq(hook.claimableFees(key.toId()), 0);
        (uint160 priceAfter,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(priceAfter, priceBefore);
        _assertSettled();
    }

    function test_partialBuyWithTokenSpecifiedChargesActualETH() public {
        _checkPartialToken(true);
    }

    function test_partialSellWithTokenSpecifiedChargesActualETH() public {
        _checkPartialToken(false);
    }

    function _checkPartialToken(bool buy) internal {
        uint256 recipientBefore = OWNER.balance;
        vm.recordLogs();
        vm.prank(alice, alice);
        BalanceDelta result = router.swap{value: buy ? 100 ether : 0}(
            key,
            SwapParams(
                buy,
                buy ? int256(100 ether) : -100 ether,
                TickMath.getSqrtPriceAtTick(buy ? int24(-1) : int24(1))
            ),
            "",
            buy ? 0 : 100 ether
        );
        (int128 raw0, int128 raw1) = _readSwap(vm.getRecordedLogs());
        assertLt(_abs128(raw1), 100 ether, "a real partial fill occurred");
        uint256 fee = _fee(_abs128(raw0));
        assertGt(fee, 0);
        assertEq(OWNER.balance - recipientBefore, fee);
        assertEq(int256(result.amount0()), int256(raw0) - int256(fee));
        assertEq(result.amount1(), raw1);
        _assertSettled();
    }

    function test_zeroSwapRevertsWithoutCooldownOrFee() public {
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        _swap(alice, key, true, 0);
        assertEq(hook.nextSwapAt(key.toId(), alice), 0);
    }

    function test_feeRoundsDownToWei() public {
        _checkSwap(true, -99);
    }

    function test_int256MinimumRevertsCleanlyWithoutCooldown() public {
        vm.prank(address(manager), alice);
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        hook.beforeSwap(alice, key, SwapParams(true, type(int256).min, TickMath.MIN_SQRT_PRICE + 1), "");
        assertEq(hook.nextSwapAt(key.toId(), alice), 0);
    }

    function testFuzz_largeSpecifiedFeeDoesNotOverflowMultiplication(uint256 size, bool buy) public {
        size = bound(size, 1, uint256(type(int256).max));
        uint256 expectedFee = _fee(size);
        SwapParams memory params = SwapParams(
            buy,
            buy ? -int256(size) : int256(size),
            buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.prank(address(manager), alice);
        if (expectedFee > uint256(uint128(type(int128).max))) {
            vm.expectRevert(SafeCast.SafeCastOverflow.selector);
            hook.beforeSwap(alice, key, params, "");
            assertEq(hook.nextSwapAt(key.toId(), alice), 0);
        } else {
            (, BeforeSwapDelta returned, uint24 lpOverride) = hook.beforeSwap(alice, key, params, "");
            assertEq(uint256(int256(returned.getSpecifiedDelta())), expectedFee);
            assertEq(returned.getUnspecifiedDelta(), 0);
            assertEq(lpOverride, 0);
        }
    }

    function test_noLiquidityETHSpecifiedReverts() public {
        PoolKey memory empty = key;
        empty.fee = 10_000;
        manager.initialize(empty, PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(ReedGuard.PartialETHFill.selector, -int256(0.99 ether), int256(0)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        _swap(alice, empty, true, -1 ether);
        assertEq(hook.nextSwapAt(empty.toId(), alice), 0);
    }

    function _stripSelector(bytes memory reason) private pure returns (bytes memory payload) {
        payload = new bytes(reason.length - 4);
        for (uint256 i; i < payload.length; ++i) {
            payload[i] = reason[i + 4];
        }
    }
}
