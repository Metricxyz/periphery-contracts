# Metric OMM Periphery

Periphery smart contracts for the Metric OMM protocol: swap routers, liquidity helpers, quoters, read-only lenses, and optional pool extensions built on top of [pool-contracts](https://github.com/Metricxyz/pool-contracts).

## Overview

Core pools expose low-level `swap` / `addLiquidity` entry points that settle through callbacks. The contracts here wrap those primitives for end users and integrators:

- **Swapping** — exact-input and exact-output swaps through one or more pools, native ETH support, permit, multicall, and composable step sequences.
- **Liquidity** — caller-funded `addLiquidity` for EOAs.
- **Quoting and data** — off-chain quotes and per-bin depth ladders read via `eth_call`.
- **Extensions** — per-pool hooks (allowlists, stop-loss, price velocity guard) that the pool creator selects at pool creation and the pool admin configures.

## Contracts

### Routers and liquidity

- **MetricOmmSimpleRouter.sol** — Exact-input and exact-output swaps through one or more pools; supports native ETH (auto-wrapped to WETH), `selfPermit`, `multicall`, external swaps and sequences.
- **MetricOmmPoolLiquidityAdder.sol** — Adds liquidity (exact shares or weighted, with per-token caps and bin-position bounds) on behalf of a position owner; tokens are pulled from the caller in `metricOmmModifyLiquidityCallback`, with native ETH wrapped for WETH legs.

### Router building blocks (`base/`)

- **MetricOmmSwapRouterBase.sol** — Transient callback context shared by exact-input and exact-output paths.
- **PeripheryPayments.sol** — Payment, WETH unwrap, sweep and refund helpers.
- **SelfPermit.sol** — EIP-2612 / DAI-style permit helpers.
- **Sequence.sol** — Ordered router calls with per-step success and failure policies.
- **ExternalSwap.sol**, **ExternalSwapExecutor.sol** — Swaps through external venues with verified refunds and recipient output. Users approve the router, never the executor.

### Lenses and quoting

- **lens/MetricOmmSwapQuoter.sol** — Off-chain swap quotes via `simulateSwapAndRevert`, using either live oracle prices or caller-supplied prices.
- **lens/MetricOmmPoolDataProvider.sol** — Per-bin bid/ask depth ladders for UIs and indexers.
- **common/MetricOmmPoolStateView.sol** — Raw pool storage reads via `EXTSLOAD`.

Lenses are intended for `eth_call` only and are not gas-optimized for on-chain composition.

### Extensions

All extensions inherit **BaseMetricExtension** (unimplemented hooks revert by default) and are configured per pool.

- **DepositAllowlistExtension.sol** — Restricts `addLiquidity` to allowlisted position owners.
- **SwapAllowlistExtension.sol** — Restricts `swap` to allowlisted senders (the pool's `msg.sender`, i.e. the router for routed swaps).
- **OracleValueStopLossExtension.sol** — Tracks per-bin value per share at bid/ask oracle marks against decaying high watermarks and blocks swaps in the direction whose drawdown limit is breached. Only bins the swap crosses are checked; `drawdownE6 == 0` disables the check. All parameter changes are timelocked; cancels are immediate. The initial config applies immediately and its timelock may be 0.
- **PriceVelocityGuardExtension.sol** — Reverts swaps when the oracle reference price moves further from the last anchor than a configured bound scaled by `sqrt(1 + blockDiff)`; `0` (the default) disables the check. The first swap only seeds the anchor; admin setters take effect immediately.

### Libraries

- **MetricOmmSwapPath.sol**, **MetricOmmSwapInputs.sol**, **MetricOmmSwapResults.sol**, **MetricOmmSwapQuoteDecode.sol** — Multihop path helpers (direction bitmap, price limits, connectivity), amount casts, swap results and quote decoding shared by routers and quoters.
- **LiquidityLadder.sol** — Builds depth ladders for the data provider.
- **TransientCallbackPool.sol** — Transient storage for the router's swap callback context.
- **BoundedReturnData.sol** — Bounded copying of external call return data.

## Usage

Add the package to a Foundry project:

```bash
forge install Metricxyz/periphery-contracts
```

```text
@metric-periphery/=lib/metric-periphery/contracts/
@metric-core/=lib/metric-periphery/lib/metric-core/contracts/
@openzeppelin/contracts/=lib/metric-periphery/lib/metric-core/lib/openzeppelin-contracts/contracts/
```

Swap through the router after approving it for the input token (or via `selfPermit`):

```solidity
import {IMetricOmmSimpleRouter} from "@metric-periphery/interfaces/IMetricOmmSimpleRouter.sol";

// Multihop: tokens[i] -> tokens[i + 1] through pools[i]; bit i of zeroForOneBitMap is the direction of pools[i].
uint256 amountOut = router.exactInput(
  IMetricOmmSimpleRouter.ExactInputParams({
    tokens: tokens,
    pools: pools,
    extensionDatas: new bytes[](pools.length),
    zeroForOneBitMap: zeroForOneBitMap,
    amountIn: amountIn,
    amountOutMinimum: minOut,
    recipient: msg.sender,
    deadline: block.timestamp
  })
);
```

Get quotes off-chain from `MetricOmmSwapQuoter` via `eth_call` before submitting a swap.

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation) **1.7.0** (the version pinned in CI) with `solc` **0.8.35**.
- Node.js 20+ (only for formatting and git hooks).
- Optional: [just](https://github.com/casey/just) for the shortcuts in `justfile`.

## Installation

```bash
git clone --recursive https://github.com/Metricxyz/periphery-contracts.git
cd periphery-contracts
forge build
```

If you cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

[`pool-contracts`](https://github.com/Metricxyz/pool-contracts) is included as a submodule under `lib/metric-core` (a private repository; cloning it requires read access).

## Build

```bash
forge build
# or
just build
```

## Testing

```bash
forge test
# or (runs with --isolate; CI and the pre-push hook run forge test without it)
just test

forge test -vvv
forge test --match-path test/MetricOmmSimpleRouter.t.sol
forge test --gas-report
```

## Contributing

### Formatting

```bash
forge fmt                    # Solidity
npm install
npm run format:check         # Prettier + forge fmt --check, same as CI
```

Solidity is formatted with Foundry only; Prettier covers everything else it supports (Markdown, JSON, YAML, JS scripts; see `.prettierignore`).

### Git hooks

`npm install` (or `just hooks`) sets `core.hooksPath` to `.githooks`:

| Hook           | Runs         | Checks                                            |
| -------------- | ------------ | ------------------------------------------------- |
| **pre-commit** | every commit | `forge fmt --check`, Prettier check               |
| **pre-push**   | every push   | `forge fmt --check`, Prettier check, `forge test` |

CI enforces the same checks on pull requests.

## Project structure

```text
contracts/
├── MetricOmmSimpleRouter.sol
├── MetricOmmPoolLiquidityAdder.sol
├── base/          # Router building blocks
├── common/        # EXTSLOAD state view
├── extensions/    # Pool extensions and BaseMetricExtension
├── interfaces/
├── lens/          # Quoter and data provider
└── libraries/

test/              # Foundry tests, helpers and mocks
```

## Security and audits

Audit reports and instructions for reporting vulnerabilities are published at [docs.metric.xyz — Security and audits](https://docs.metric.xyz/reference/security-and-audits).

### Audited code

Every commit named in the audit reports is published here as a tag named `audit-<commit>`. A tag is a new commit without the private history, so its own hash differs from the audited one. Its `contracts/` folder, though, is identical to the audited commit's, and the tag's `VERIFY.md` proves that from the commit hash printed in the report, without access to the private repository.

| Tag                                                                                    | Audits                                                                                               | `contracts/` hash                          | `lib/metric-core`                                                           | Proof                                                                                      |
| -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------ | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| [`audit-0069084`](https://github.com/Metricxyz/periphery-contracts/tree/audit-0069084) | Zellic audit (Jun 2026), audited                                                                     | `4c9d8d975e89e4975abddfebddf21f6c53a1919e` | [`6aa6c3b`](https://github.com/Metricxyz/pool-contracts/tree/audit-6aa6c3b) | [VERIFY.md](https://github.com/Metricxyz/periphery-contracts/blob/audit-0069084/VERIFY.md) |
| [`audit-90039f9`](https://github.com/Metricxyz/periphery-contracts/tree/audit-90039f9) | Sherlock collaborative audit (May–Jun 2026), audited                                                 | `607ff7f1c5ceb6342b4053854acdfb868787a65c` | [`6aa6c3b`](https://github.com/Metricxyz/pool-contracts/tree/audit-6aa6c3b) | [VERIFY.md](https://github.com/Metricxyz/periphery-contracts/blob/audit-90039f9/VERIFY.md) |
| [`audit-d210a84`](https://github.com/Metricxyz/periphery-contracts/tree/audit-d210a84) | Sherlock collaborative audit, fixes. Sherlock bug bounty contest (Jul 2026), audited                 | `fa3c0ec0b2ad2f804ac71ee5f2f3a593a2ff10aa` | [`7b9ab56`](https://github.com/Metricxyz/pool-contracts/tree/audit-7b9ab56) | [VERIFY.md](https://github.com/Metricxyz/periphery-contracts/blob/audit-d210a84/VERIFY.md) |
| [`audit-9b69f75`](https://github.com/Metricxyz/periphery-contracts/tree/audit-9b69f75) | Sherlock bug bounty contest, fixes. Zellic re-audit (Sep 2026), final                                | `85028bfd01808bbb50d8621c84803ce583791abd` | [`4410fec`](https://github.com/Metricxyz/pool-contracts/tree/audit-4410fec) | [VERIFY.md](https://github.com/Metricxyz/periphery-contracts/blob/audit-9b69f75/VERIFY.md) |
| [`audit-cc8fef9`](https://github.com/Metricxyz/periphery-contracts/tree/audit-cc8fef9) | Zellic re-audit (Sep 2026), starting point: the re-audit reviewed the changes from here to `9b69f75` | `b756bf2b72b53390f13a0102c38d1a669a122178` | [`72c65de`](https://github.com/Metricxyz/pool-contracts/tree/audit-72c65de) | [VERIFY.md](https://github.com/Metricxyz/periphery-contracts/blob/audit-cc8fef9/VERIFY.md) |
| [`audit-378a748`](https://github.com/Metricxyz/periphery-contracts/tree/audit-378a748) | Sherlock periphery update review (Sep 2026), audited                                                 | `97b1ec583933735d23a3e250e25978591b57e8cf` | [`d4d0e2a`](https://github.com/Metricxyz/pool-contracts/tree/audit-d4d0e2a) | [VERIFY.md](https://github.com/Metricxyz/periphery-contracts/blob/audit-378a748/VERIFY.md) |
| [`audit-ed58520`](https://github.com/Metricxyz/periphery-contracts/tree/audit-ed58520) | Sherlock periphery update review (Sep 2026), fixes                                                   | `4cbfd5aa5866fd1e570ce4f7726ba65c4a6051f5` | [`d4d0e2a`](https://github.com/Metricxyz/pool-contracts/tree/audit-d4d0e2a) | [VERIFY.md](https://github.com/Metricxyz/periphery-contracts/blob/audit-ed58520/VERIFY.md) |

In these tags the `lib/metric-core` submodule points at the private repository where the code was developed, so `git submodule update` can't fetch it. The same metric-core code is published in [pool-contracts](https://github.com/Metricxyz/pool-contracts) under the tag in the `lib/metric-core` column.

To verify a tag, clone it and run its check script (Python 3 and git only):

```bash
git clone --branch audit-ed58520 https://github.com/Metricxyz/periphery-contracts.git
cd periphery-contracts
python verify/verify.py .
```

It ends with `OK: contracts/ at this tag is identical to contracts/ in audited commit …`. Each tag's `VERIFY.md` explains the check step by step. For a quick look, compare the hash directly:

```bash
git rev-parse audit-ed58520:contracts   # 4cbfd5aa5866fd1e570ce4f7726ba65c4a6051f5
```

### Changes since the last audit

Since `ed58520` there is one logic change: `02096b5` makes the quoter's live quotes revert with `PoolPaused` for paused pools. Unused code was also removed (an internal helper and the unused `InvalidPriceLimitForDirection` error), and the quoter's return values are now named. Every other change is to NatSpec, documentation or formatting.

## License

MIT — see [`licenses/MIT_LICENSE`](licenses/MIT_LICENSE). `LiquidityLadder.sol` (used by `MetricOmmPoolDataProvider`) compiles in metric-core's `FeeMath.sol` and `SwapMath.sol`, which are `BUSL-1.1`.
