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
forge install Metricxyz/metric-periphery
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
git clone --recursive https://github.com/Metricxyz/metric-periphery.git
cd metric-periphery
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

## License

MIT — see [`licenses/MIT_LICENSE`](licenses/MIT_LICENSE). `LiquidityLadder.sol` (used by `MetricOmmPoolDataProvider`) compiles in metric-core's `FeeMath.sol` and `SwapMath.sol`, which are `BUSL-1.1`.
