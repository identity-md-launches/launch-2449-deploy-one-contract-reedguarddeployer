// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {ReedGuard} from "../src/ReedGuard.sol";
import {ReedGuardDeployer} from "../src/ReedGuardDeployer.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @dev Models the launch factory's raw CREATE2; never invokes a separate hook deploy function.
contract ConstructorDeploymentProbe {
    function deploy(bytes memory initCode, bytes32 applicationSalt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), applicationSalt)
        }
        require(deployed != address(0), "application creation failed");
    }
}

contract ReedGuardDeployerTest is Test {
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant OWNER = 0x5Bff2a2FEcD1d6152676813b21346238733bEAB1;

    function test_launchConstructorWorksOnEmptyChainAndCreatesHook() public {
        vm.chainId(4663);
        assertEq(POOL_MANAGER.code.length, 0);
        assertEq(OWNER.code.length, 0);
        vm.recordLogs();
        ReedGuardDeployer deployer = new ReedGuardDeployer(IPoolManager(POOL_MANAGER), OWNER, OWNER);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        ReedGuard hook = ReedGuard(deployer.hook());
        assertGt(address(hook).code.length, 0);
        assertEq(address(hook.poolManager()), POOL_MANAGER);
        assertEq(hook.owner(), OWNER);
        assertEq(hook.feeRecipient(), OWNER);
        assertTrue(HookFlags.matches(address(hook), HookFlags.REED_GUARD));
        assertLe(address(hook).code.length, 24_576);
        assertLe(address(deployer).code.length, 24_576);
        assertLe(type(ReedGuardDeployer).creationCode.length + 96, 49_152);

        bytes32 chosenSalt = abi.decode(logs[logs.length - 1].data, (bytes32));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(ReedGuard).creationCode, abi.encode(IPoolManager(POOL_MANAGER), OWNER, OWNER)
            )
        );
        for (uint256 i; i < uint256(chosenSalt); ++i) {
            assertFalse(
                HookFlags.matches(
                    _predict(address(deployer), bytes32(i), initCodeHash), HookFlags.REED_GUARD
                ),
                "skipped an earlier valid salt"
            );
        }
        assertEq(_predict(address(deployer), chosenSalt, initCodeHash), address(hook));
        assertEq(address(uint160(uint256(logs[logs.length - 1].topics[1]))), address(hook));
    }

    function test_parametersArePassedUnchangedNotReplacedByCallerOrOrigin() public {
        address chosenOwner = makeAddr("distinct owner");
        address recipient = makeAddr("distinct recipient");
        address factory = makeAddr("factory");
        address origin = makeAddr("launch wallet");
        vm.prank(factory, origin);
        ReedGuardDeployer deployer = new ReedGuardDeployer(IPoolManager(POOL_MANAGER), chosenOwner, recipient);
        ReedGuard hook = ReedGuard(deployer.hook());
        assertEq(hook.owner(), chosenOwner);
        assertEq(hook.feeRecipient(), recipient);
        assertEq(address(hook.poolManager()), POOL_MANAGER);
        assertNotEq(hook.owner(), factory);
        assertNotEq(hook.owner(), origin);
    }

    function test_factoryCreatesApplicationAndHookAtomically() public {
        ConstructorDeploymentProbe factory = new ConstructorDeploymentProbe();
        bytes memory initCode = abi.encodePacked(
            type(ReedGuardDeployer).creationCode, abi.encode(IPoolManager(POOL_MANAGER), OWNER, OWNER)
        );
        uint256 gasBefore = gasleft();
        ReedGuardDeployer deployer = ReedGuardDeployer(factory.deploy(initCode, bytes32(0)));
        uint256 used = gasBefore - gasleft();
        ReedGuard hook = ReedGuard(deployer.hook());
        assertGt(address(hook).code.length, 0);
        assertTrue(HookFlags.matches(address(hook), HookFlags.REED_GUARD));
        assertEq(hook.owner(), OWNER);
        assertEq(hook.feeRecipient(), OWNER);
        assertEq(address(hook.poolManager()), POOL_MANAGER);
        emit log_named_uint("factory application creation gas (local address only)", used);
    }

    function test_noDeploymentOrAdminFunctionAfterConstruction() public {
        ReedGuardDeployer deployer = new ReedGuardDeployer(IPoolManager(POOL_MANAGER), OWNER, OWNER);
        address original = deployer.hook();
        (bool ok,) = address(deployer).call(abi.encodeWithSignature("deploy()"));
        assertFalse(ok);
        (ok,) = address(deployer).call(abi.encodeWithSignature("deploy(bytes32)", bytes32(uint256(7))));
        assertFalse(ok);
        (ok,) = address(deployer).call(abi.encodeWithSignature("transferOwnership(address)", address(this)));
        assertFalse(ok);
        assertEq(deployer.hook(), original);
    }

    function test_neitherConstructorCallsAnExternalContract() public {
        vm.startStateDiffRecording();
        ReedGuardDeployer deployer = new ReedGuardDeployer(IPoolManager(POOL_MANAGER), OWNER, OWNER);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        uint256 creates;
        for (uint256 i; i < accesses.length; ++i) {
            VmSafe.AccountAccessKind kind = accesses[i].kind;
            assertFalse(kind == VmSafe.AccountAccessKind.Call || kind == VmSafe.AccountAccessKind.StaticCall);
            assertFalse(
                kind == VmSafe.AccountAccessKind.DelegateCall || kind == VmSafe.AccountAccessKind.CallCode
            );
            assertFalse(
                kind == VmSafe.AccountAccessKind.Extcodesize || kind == VmSafe.AccountAccessKind.Extcodehash
            );
            if (kind == VmSafe.AccountAccessKind.Create) {
                creates++;
                assertTrue(accesses[i].account == address(deployer) || accesses[i].account == deployer.hook());
            }
        }
        assertEq(creates, 2, "only deployer and its hook are created");
    }

    function test_deployedRuntimesContainNoEscapeOpcodes() public {
        ReedGuardDeployer deployer = new ReedGuardDeployer(IPoolManager(POOL_MANAGER), OWNER, OWNER);
        _checkRuntime(address(deployer).code);
        _checkRuntime(deployer.hook().code);
    }

    function _checkRuntime(bytes memory code) private pure {
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) require(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
            if (op == 0 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                reachable = false;
            }
        }
    }

    function test_zeroConfigurationRejectedByHookConstructor() public {
        vm.expectRevert(ReedGuardDeployer.HookDeploymentFailed.selector);
        new ReedGuardDeployer(IPoolManager(address(0)), OWNER, OWNER);
        vm.expectRevert(ReedGuardDeployer.HookDeploymentFailed.selector);
        new ReedGuardDeployer(IPoolManager(POOL_MANAGER), address(0), OWNER);
        vm.expectRevert(ReedGuardDeployer.HookDeploymentFailed.selector);
        new ReedGuardDeployer(IPoolManager(POOL_MANAGER), OWNER, address(0));
    }

    function _predict(address deployer, bytes32 salt, bytes32 initCodeHash) private pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
