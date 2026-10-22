# Vendored dependencies

The verifier can compile and test without downloading dependencies. The following upstream files are copied as ordinary files, with their licenses, and contain no Git submodules, package installation steps or symlinks.

| Directory | Source and pin | Included files |
| --- | --- | --- |
| `lib/v4-core` | [Uniswap/v4-core, `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75) | `src/` excluding upstream test helpers, plus `licenses/` |
| `lib/forge-std` | [foundry-rs/forge-std v1.9.7, `77041d2ce690e692d6e03cc812b57d1ddaa4d505`](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | `src/` and licenses; tests only |
| `lib/solmate` | [transmissions11/solmate, `4b47a19038b798b4a33d9749d25e570443520647`](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | `Owned.sol` for the test PoolManager, `ERC20.sol` for test tokens, and license |

The solmate revision is the revision pinned by the chosen v4-core commit. No upstream Solidity source was modified. Source-level SPDX identifiers and upstream licenses apply to their respective files. The core PoolManager is used only as the local integration test implementation; the launch uses the PoolManager address supplied by the assignment. Production hook imports are the MIT-licensed v4 interfaces, types and internal libraries. Project-authored contracts and tests use MIT.

Useful protocol references: [v4 hooks](https://developers.uniswap.org/docs/protocols/v4/concepts/hooks), [flash accounting](https://developers.uniswap.org/docs/protocols/v4/concepts/flash-accounting), and the pinned [Hooks.sol delta handling](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/libraries/Hooks.sol).
