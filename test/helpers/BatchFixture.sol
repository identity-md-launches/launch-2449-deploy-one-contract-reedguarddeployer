// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    Fixture,
    PoolManager,
    ReedGuard,
    ReedGuardDeployer,
    PoolKey,
    ModifyLiquidityParams,
    BalanceDelta
} from "./Fixture.sol";
import {TestRouter} from "./TestRouter.sol";
import {TestToken} from "./TestToken.sol";
import {BatchProbe} from "./BatchProbe.sol";

abstract contract BatchFixture is Fixture {
    BatchProbe internal batch;

    function setUp() public virtual override {
        vm.warp(1_000);
        alice = makeAddr("batch alice");
        bob = makeAddr("batch bob");
        manager = new PoolManager(address(this));
        hook = ReedGuard(new ReedGuardDeployer(manager, OWNER, OWNER).hook());
        router = new TestRouter(manager);
        batch = new BatchProbe(manager);
        asset = new TestToken(18);
        secondAsset = new TestToken(6);
        key = _key(asset, hook, 12_500);
        sameTokenKey = key;
        sameTokenKey.tickSpacing = 30; // The only difference is spacing, not the token or fee.
        secondKey = _key(secondAsset, hook, 12_500);
        _fund(address(this));
        _fund(alice);
        _fund(bob);
        _seedTokens(key);
        _seedTokens(sameTokenKey);
        _seedTokens(secondKey);
        assertEq(address(manager).balance, 0);
    }

    function _seedTokens(PoolKey memory poolKey) internal {
        manager.initialize(poolKey, PRICE);
        BalanceDelta delta =
            router.modify(poolKey, ModifyLiquidityParams(-600, -60, 10_000 ether, bytes32(0)), 100_000 ether);
        assertEq(delta.amount0(), 0);
        assertLt(delta.amount1(), 0);
    }

    function _twoPools(PoolKey memory first, PoolKey memory second, uint256 a, uint256 b)
        internal
        pure
        returns (PoolKey[] memory keys, uint256[] memory amounts)
    {
        keys = new PoolKey[](2);
        amounts = new uint256[](2);
        keys[0] = first;
        keys[1] = second;
        amounts[0] = a;
        amounts[1] = b;
    }
}
