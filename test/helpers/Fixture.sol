// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {ReedGuard} from "../../src/ReedGuard.sol";
import {ReedGuardDeployer} from "../../src/ReedGuardDeployer.sol";
import {TestToken} from "./TestToken.sol";
import {TestRouter} from "./TestRouter.sol";

abstract contract Fixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant OWNER = 0x5Bff2a2FEcD1d6152676813b21346238733bEAB1;
    uint160 internal constant PRICE = 1 << 96;
    uint256 internal constant FUNDS = 1_000_000 ether;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    PoolManager internal manager;
    ReedGuard internal hook;
    TestRouter internal router;
    TestToken internal asset;
    TestToken internal secondAsset;
    PoolKey internal key;
    PoolKey internal secondKey;
    PoolKey internal sameTokenKey;
    address internal alice;
    address internal bob;

    function setUp() public virtual {
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
        sameTokenKey = _key(asset, hook, 500);
        _fund(address(this));
        _fund(alice);
        _fund(bob);
        _initializeAndSeed(key);
        _initializeAndSeed(secondKey);
        _initializeAndSeed(sameTokenKey);
    }

    function _key(TestToken token_, ReedGuard hook_, uint24 lpFee) internal pure returns (PoolKey memory) {
        return
            PoolKey(
                Currency.wrap(address(0)), Currency.wrap(address(token_)), lpFee, 60, IHooks(address(hook_))
            );
    }

    function _fund(address wallet) internal {
        vm.deal(wallet, FUNDS);
        asset.mint(wallet, FUNDS);
        secondAsset.mint(wallet, FUNDS);
        vm.startPrank(wallet);
        asset.approve(address(router), FUNDS);
        secondAsset.approve(address(router), FUNDS);
        vm.stopPrank();
    }

    function _initializeAndSeed(PoolKey memory poolKey) internal {
        manager.initialize(poolKey, PRICE);
        router.modify{value: 100_000 ether}(
            poolKey, ModifyLiquidityParams(-600, 600, 10_000 ether, bytes32(0)), 100_000 ether
        );
    }

    function _swap(address wallet, PoolKey memory poolKey, bool buy, int256 amount)
        internal
        returns (BalanceDelta)
    {
        vm.prank(wallet, wallet);
        return router.swap{value: buy ? 100 ether : 0}(
            poolKey,
            SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            "",
            buy ? 0 : 100 ether
        );
    }

    function _readSwap(Vm.Log[] memory logs) internal view returns (int128 raw0, int128 raw1) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (raw0, raw1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return (raw0, raw1);
            }
        }
        revert("missing actual PoolManager Swap event");
    }

    function _assertSettled() internal view {
        IPoolManager pm = IPoolManager(address(manager));
        assertEq(pm.getNonzeroDeltaCount(), 0, "all manager debts settled");
        assertFalse(pm.isUnlocked(), "manager relocked");
        assertEq(pm.currencyDelta(address(hook), key.currency0), 0, "hook ETH delta zero");
        assertEq(pm.currencyDelta(address(hook), key.currency1), 0, "hook token delta zero");
        assertEq(address(hook).balance, 0, "no ETH custody in hook");
        assertEq(asset.balanceOf(address(hook)), 0, "no token custody in hook");
        assertEq(address(router).balance, 0, "router refunds ETH");
        assertEq(asset.balanceOf(address(router)), 0, "router refunds token");
    }

    function _fee(uint256 amount) internal pure returns (uint256) {
        return FullMath.mulDiv(amount, 100, 10_000);
    }

    function _abs128(int128 amount) internal pure returns (uint256) {
        return uint256(amount < 0 ? -int256(amount) : int256(amount));
    }

    receive() external payable {}
}
