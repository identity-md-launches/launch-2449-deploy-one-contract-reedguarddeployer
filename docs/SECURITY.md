# ReedGuard self-review

This document records the local implementation review and the boundaries of the tests. It is not an independent security audit or proof about the implementation deployed at the supplied Robinhood Chain PoolManager address.

## Permissions and entry points

- Permission mask `0x20cc` enables only `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta` and `afterSwapReturnDelta`. The constructor validates the full 14-bit address mask against `getHookPermissions()`.
- All implemented hook callbacks and `unlockCallback` authenticate `msg.sender == poolManager`. Disabled callback selectors have no implementation. There is no receive/fallback accepting arbitrary requests.
- `beforeSwapReturnDelta` is needed for ETH-specified swaps. It returns only the fixed positive 1% fee on the specified ETH amount, never the whole input, never a token delta and never an alternative swap. `afterSwap` verifies the exact adjusted ETH fill before any payout. The hook cannot successfully replace the entire trade with a fee-taking no-op.
- `afterSwapReturnDelta` is used only when ETH is the unspecified currency. Its returned fee is a positive, bounded fraction of the actual ETH delta. The token-side return is always zero.
- `pause` and `unpause` check the immutable owner using `msg.sender`. No other function grants owner privileges. `tx.origin` indexes only the requested public cooldown.
- `claimFees` is permissionless but has no recipient parameter. Its callback can execute only during an internally initiated claim, and consumes that callback authorization before interacting with the manager.

## Accounting and external interactions

For a fee `F`, manager `take` or `mint` creates hook delta `-F`; the hook's returned positive ETH delta creates `+F`. The caller pays the corresponding charge. A claim redemption burns `F` for `+F` and takes `F` for `-F`. All complete unlocks must have zero unsettled deltas; integration tests exercise the real manager's enforcement.

Fee payments happen only after the actual swap delta is known. ETH-specified partial fills revert atomically. Token-specified partial fills use only the realized ETH amount. Percentage calculations use the pinned full-precision `FullMath.mulDiv`; fee casts use `SafeCast`. The signed absolute-value helper handles `int256.min` without negating it directly. Rounding is down to whole wei and is specified in the README.

The cooldown is updated before any external fee transfer. The payment/claim execution guard rejects recursive claims and swaps, including attempts through a different pool. Claim balances decrease before `unlock`, and the claim callback authorization is consumed before burn/take. Failed calls roll back all accounting. `take` failure is caught only for the immediate swap payout: the manager subcall's debit and transfer roll back before the hook mints its replacement claim.

Manager ETH scarcity is exercised with a fresh real PoolManager and token-only liquidity. A fee claim is minted before the router pays its ETH input and is later redeemed. A rejecting recipient is tested both during swaps and during claims. Unsolicited ERC-6909 transfers cannot increase any pool's claim ledger or be redeemed through another pool.

Pool data is keyed by the complete PoolId, including two pools that use the same token. There are no cross-pool windows, fee ledgers or pause switches. The two transient-in-purpose execution booleans are ordinary storage guards for a currently running payment/claim, not pool settings, and are cleared before the call returns. The hook reads total supply directly from the registered pool token only when requested; its swaps and initialization do not call that token or rely on reported supply.

## Deployment

The deployer mines from salt zero with a fixed-size CREATE2 preimage. It performs no external call during construction, only creation of the hook. The hook constructor performs local checks only. Tests inspect constructor account accesses, check the first matching salt and the deployed address, exercise the exact supplied chain/addresses on an empty chain, and scan both deployed runtimes for reachable `DELEGATECALL`, `CALLCODE` and `SELFDESTRUCT` opcodes. Runtime and init-code bounds are checked. Both application bytecodes must have no unresolved library links.

The unbounded constructor mining loop is a deliberate requirement. The final transaction's gas cannot be promised before its exact deployer address and init code are known. The launch pipeline must simulate that deployment within the chain and factory gas limits; this repository neither guesses a factory address nor introduces a salt override.

## Verification scope

The delivered suites cover:

- Native-only and permissionless initialization, current token supply, callback authentication and exact permission bits.
- All four swap modes; actual manager events, net wallet balances, no token fee, LP-fee coexistence and fee rounding.
- Price-limit partial fills, empty-liquidity refusal for ETH-specified swaps and rollback of fee/timer/price state.
- Owner-only pause, per-pool isolation, cooldown boundaries and identity semantics, plus withdrawals and LP fee collection during pause.
- Empty-manager fallback, rejecting recipients, direct payment after a prior deferred fee, permissionless redemption, double-claim prevention and claim isolation.
- Reentrancy attempts during immediate payout and claim redemption.
- Stateful conservation of ETH and both tokens, exact claim backing, cumulative paid/deferred fees and isolated controls under mixed operations.
- Constructor-only deployment, unchanged arguments, no factory/origin ownership, no post-deployment deploy/admin entry point and code-size/opcode limits.

The full suite is run with the assignment's fixed fuzz seed. No test uses `vm.env*`, `vm.setEnv`, an RPC fork, a network account or a wall-clock delay. The compiler's ordinary warnings and Foundry lint observations are reviewed; no global suppression of security checks is configured.

Remaining release work is the independent contributor's adversarial review and an exact deployment/fork rehearsal against the launch chain. Slither, Mythril and formal verification are not claimed. The immutable fee recipient must accept ETH to redeem deferred claims. A lost owner key cannot be replaced; paused swaps may remain paused while liquidity withdrawal and claims stay open. The origin-based cooldown can be bypassed with additional origins and does not provide MEV or identity guarantees.
