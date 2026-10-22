# ReedGuard adversarial tests

The existing deployment, controls, swaps, claims and invariant suites are preserved. These additional suites use the vendored real Uniswap v4 `PoolManager`; they require no RPC, FFI, downloaded dependency or environment mutation.

| Suite | Additional coverage |
| --- | --- |
| `ReedGuardTransactions.t.sol` | Multiple swaps within one unlock; settlement after each swap versus after the whole batch; separate claims for pools differing only in tick spacing; cross-token settlement; repeated-origin refusal within one transaction; rollback after a later pool fails or the router leaves debts unsettled; retry after a claim attempted inside another unlock. |
| `ReedGuardBoundaries.t.sol` | Failed and duplicate initialization; zero and maximum live token supply; mint/burn changes; supply-read failure without blocking unrelated operations; exact signed fee-cast boundaries; one-wei rounding; no-cash and partial claim recovery; unsolicited ERC-6909 claims; untaxed donations and LP fee collection while paused. |
| `ReedGuardLiquidityInvariant.t.sol` | Random trades, pauses, unauthorized controls, clock advances, liquidity addition, partial/full removal, LP fee collection, redemption and unsolicited claims across three pools and multiple actors. |

`BatchProbe` checks hook currency deltas and the manager's nonzero-delta count **inside the same unlock**, before transient storage disappears. The deliberate unsettled-debt path lets PoolManager reject the transaction; tests check that both an already-paid fee and a newly minted claim roll back.

The new invariant handler maintains independent expected liquidity, fee claims, pause state and wallet timers. It checks physical ETH/token conservation and the identities:

```text
hook ERC-6909 balance = sum(pool fee liabilities) + unsolicited claims
fees paid to recipient + outstanding pool fee liabilities = fees earned
```

Trade fees in this handler are independently derived from the actual ETH delta emitted by PoolManager for token-specified trades. Unexpected reverts fail the campaign. The model permits only the exact pause, cooldown or v4 price-limit error applicable to the current state. An exhausted pool can reach v4's extreme price limit; this is modeled explicitly rather than treated as a hook defect or ignored in a catch-all.

Every invariant campaign begins with a real trade, a refused paused trade, a full withdrawal while paused, a fee redemption, liquidity replenishment and a claim donation. After each random sequence, it pauses every pool, fully withdraws its remaining position, and redeems its earned claims. Unsolicited claims must not be assigned to a pool or paid as earned fees. Inline configuration pins 256 sequences of 96 calls, with unexpected reverts fatal. The four new stateless fuzz tests each run 1,000 cases.

Run from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x6f3abb40f6e8e0ab01bbac70f5d9de1e1c5158618d84eeb732fd96b25f53612e forge test
```

The partial-cash redemption test deliberately changes the manager's ETH balance to exercise recovery branches; it does not claim that an otherwise solvent manager naturally reaches that state. The fee-cast boundary test calls the authenticated callback directly to isolate arithmetic limits that exceed practical pool liquidity. All random lifecycle operations use real manager accounting without storage or balance injection after setup.

These are offline integration tests, not a fork rehearsal of the supplied Robinhood Chain address or an exact deployment-gas simulation. No implementation defect was reproduced by these additions.
