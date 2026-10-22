// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture, ReedGuard, ReedGuardDeployer, PoolKey, PoolId} from "./helpers/Fixture.sol";
import {InvariantHandler} from "./helpers/InvariantHandler.sol";
import {SwitchableRecipient} from "./helpers/FeeRecipients.sol";

contract ReedGuardInvariantTest is Fixture {
    InvariantHandler internal handler;
    SwitchableRecipient internal recipient;
    uint256 internal initialETH;
    uint256 internal initialToken;
    uint256 internal initialSecondToken;

    function setUp() public override {
        super.setUp();
        recipient = new SwitchableRecipient();
        hook = ReedGuard(new ReedGuardDeployer(manager, OWNER, address(recipient)).hook());
        key = _key(asset, hook, 3_000);
        secondKey = _key(secondAsset, hook, 12_500);
        sameTokenKey = _key(asset, hook, 500);
        _initializeAndSeed(key);
        _initializeAndSeed(secondKey);
        _initializeAndSeed(sameTokenKey);
        handler = new InvariantHandler(hook, router, recipient, [key, secondKey, sameTokenKey], [alice, bob]);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = InvariantHandler.advance.selector;
        selectors[1] = InvariantHandler.pausePool.selector;
        selectors[2] = InvariantHandler.rejectPayment.selector;
        selectors[3] = InvariantHandler.trade.selector;
        selectors[4] = InvariantHandler.claim.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
        initialETH = _ethHeld();
        initialToken = _tokenHeld(false);
        initialSecondToken = _tokenHeld(true);
    }

    function invariant_eachPoolsClaimsAndControlsRemainIsolated() public view {
        PoolId[3] memory ids = [key.toId(), secondKey.toId(), sameTokenKey.toId()];
        uint256 claims;
        for (uint256 i; i < ids.length; ++i) {
            PoolId id = ids[i];
            uint256 pending = hook.claimableFees(id);
            assertEq(pending, handler.expectedClaims(id));
            claims += pending;
            assertEq(hook.paused(id), handler.expectedPaused(id));
            assertEq(hook.nextSwapAt(id, alice), handler.expectedNext(id, alice));
            assertEq(hook.nextSwapAt(id, bob), handler.expectedNext(id, bob));
        }
        assertEq(manager.balanceOf(address(hook), 0), claims);
        assertEq(
            address(recipient).balance + claims, handler.totalFees(), "every fee either paid or claim-backed"
        );
    }

    function invariant_ETHAndBothTokensAreConserved() public view {
        assertEq(_ethHeld(), initialETH);
        assertEq(_tokenHeld(false), initialToken);
        assertEq(_tokenHeld(true), initialSecondToken);
        assertEq(address(hook).balance, 0);
        assertEq(asset.balanceOf(address(hook)), 0);
        assertEq(secondAsset.balanceOf(address(hook)), 0);
        assertEq(asset.balanceOf(address(recipient)), 0);
        assertEq(secondAsset.balanceOf(address(recipient)), 0);
        assertEq(hook.owner(), OWNER);
        assertEq(hook.feeRecipient(), address(recipient));
    }

    function afterInvariant() public {
        recipient.setRejecting(false);
        hook.claimFees(key.toId());
        hook.claimFees(secondKey.toId());
        hook.claimFees(sameTokenKey.toId());
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(address(recipient).balance, handler.totalFees());
        assertEq(_ethHeld(), initialETH);
    }

    function _ethHeld() private view returns (uint256) {
        return alice.balance + bob.balance + address(manager).balance + address(recipient).balance
            + address(router).balance + address(hook).balance;
    }

    function _tokenHeld(bool second) private view returns (uint256) {
        if (second) {
            return secondAsset.balanceOf(alice) + secondAsset.balanceOf(bob)
                + secondAsset.balanceOf(address(manager)) + secondAsset.balanceOf(address(router))
                + secondAsset.balanceOf(address(hook)) + secondAsset.balanceOf(address(recipient));
        }
        return asset.balanceOf(alice) + asset.balanceOf(bob) + asset.balanceOf(address(manager))
            + asset.balanceOf(address(router)) + asset.balanceOf(address(hook))
            + asset.balanceOf(address(recipient));
    }
}
