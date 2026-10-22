// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BatchFixture} from "./helpers/BatchFixture.sol";
import {LiquidityHandler} from "./helpers/LiquidityHandler.sol";
import {PoolId, IPoolManager, StateLibrary} from "./helpers/Fixture.sol";

contract ReedGuardLiquidityInvariantTest is BatchFixture {
    using StateLibrary for IPoolManager;

    LiquidityHandler internal handler;
    uint256 internal initialETH;
    uint256 internal initialToken;
    uint256 internal initialSecondToken;
    uint256 internal initialRecipient;

    function setUp() public override {
        super.setUp();
        handler = new LiquidityHandler(hook, router, batch, [key, sameTokenKey, secondKey], [alice, bob]);
        _fund(address(handler));
        initialETH = _ethHeld();
        initialToken = _tokenHeld(false);
        initialSecondToken = _tokenHeld(true);
        initialRecipient = OWNER.balance;

        // A deterministic prefix proves every campaign starts from reachable fee-bearing state.
        // It also exercises full withdrawal while paused before any random calls are generated.
        handler.trade(0, 0, true, 0.01 ether);
        handler.pausePool(0, true);
        handler.trade(0, 1, true, 0.01 ether);
        handler.removeLiquidity(0, 0, true);
        handler.claim(0, 1);
        handler.addLiquidity(0, 10_000 ether);
        handler.pausePool(0, false);
        handler.donateClaims(1);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = LiquidityHandler.trade.selector;
        selectors[1] = LiquidityHandler.pausePool.selector;
        selectors[2] = LiquidityHandler.advance.selector;
        selectors[3] = LiquidityHandler.addLiquidity.selector;
        selectors[4] = LiquidityHandler.removeLiquidity.selector;
        selectors[5] = LiquidityHandler.claim.selector;
        selectors[6] = LiquidityHandler.donateClaims.selector;
        selectors[7] = LiquidityHandler.unauthorizedControl.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_poolLiabilitiesAreBackedWithoutCreditingDonatedClaims() public view {
        PoolId[3] memory ids = [key.toId(), sameTokenKey.toId(), secondKey.toId()];
        uint256 pending;
        for (uint256 i; i < 3; ++i) {
            PoolId id = ids[i];
            assertEq(hook.claimableFees(id), handler.expectedClaims(id));
            pending += hook.claimableFees(id);
            assertEq(hook.paused(id), handler.expectedPaused(id));
            assertEq(hook.nextSwapAt(id, alice), handler.expectedNext(id, alice));
            assertEq(hook.nextSwapAt(id, bob), handler.expectedNext(id, bob));
            (uint128 liquidity,,) =
                IPoolManager(address(manager)).getPositionInfo(id, address(router), -600, -60, bytes32(0));
            assertEq(uint256(liquidity), handler.expectedLiquidity(id));
        }
        assertEq(manager.balanceOf(address(hook), 0), pending + handler.donatedClaims());
        assertGe(address(manager).balance, manager.balanceOf(address(hook), 0), "claims have cash backing");
        assertEq(
            OWNER.balance - initialRecipient + pending,
            handler.totalFees(),
            "fees are paid or owed exactly once"
        );
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_liquidityAndTradingConserveETHAndBothTokens() public view {
        assertEq(_ethHeld(), initialETH);
        assertEq(_tokenHeld(false), initialToken);
        assertEq(_tokenHeld(true), initialSecondToken);
        assertEq(address(hook).balance, 0);
        assertEq(address(router).balance, 0);
        assertEq(address(batch).balance, 0);
        assertEq(asset.balanceOf(address(hook)), 0);
        assertEq(secondAsset.balanceOf(address(hook)), 0);
        assertEq(asset.balanceOf(OWNER), 0);
        assertEq(secondAsset.balanceOf(OWNER), 0);
        assertGt(handler.traded(), 0, "real trades must be reachable");
        assertGt(handler.refused(), 0, "rejected swaps must be exercised");
        assertGt(handler.removed(), 0);
        assertGt(handler.added(), 0);
        assertGt(handler.redeemed(), 0);
    }

    function afterInvariant() public {
        for (uint8 i; i < 3; ++i) {
            handler.pausePool(i, true);
            handler.removeLiquidity(i, 0, true);
            handler.claim(i, 0);
        }
        assertEq(hook.claimableFees(key.toId()), 0);
        assertEq(hook.claimableFees(sameTokenKey.toId()), 0);
        assertEq(hook.claimableFees(secondKey.toId()), 0);
        assertEq(
            manager.balanceOf(address(hook), 0), handler.donatedClaims(), "only unsolicited claims remain"
        );
        assertEq(OWNER.balance - initialRecipient, handler.totalFees());
        invariant_poolLiabilitiesAreBackedWithoutCreditingDonatedClaims();
        invariant_liquidityAndTradingConserveETHAndBothTokens();
    }

    function _ethHeld() private view returns (uint256) {
        return alice.balance + bob.balance + address(handler).balance + address(manager).balance
            + address(hook).balance + address(router).balance + address(batch).balance + OWNER.balance;
    }

    function _tokenHeld(bool second) private view returns (uint256) {
        if (second) {
            return secondAsset.balanceOf(alice) + secondAsset.balanceOf(bob)
                + secondAsset.balanceOf(address(handler)) + secondAsset.balanceOf(address(manager))
                + secondAsset.balanceOf(address(hook)) + secondAsset.balanceOf(address(router))
                + secondAsset.balanceOf(address(batch)) + secondAsset.balanceOf(OWNER);
        }
        return asset.balanceOf(alice) + asset.balanceOf(bob) + asset.balanceOf(address(handler))
            + asset.balanceOf(address(manager)) + asset.balanceOf(address(hook))
            + asset.balanceOf(address(router)) + asset.balanceOf(address(batch)) + asset.balanceOf(OWNER);
    }
}
