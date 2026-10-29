# Verifying audit-ed58520

The tag `audit-ed58520` publishes the contracts at commit `ed58520348f2eb05ba1903145c0a91f69cd0afde` of our private repository `metric-periphery`. That commit is the version named in:

- **Sherlock periphery update review, September 2026** (`2026.10.10 - Final - Metric Collaborative Audit Report`, p. 2: "Final Commit: ed58520348…")

The public tag is a new commit without the private history, so its own hash is not `ed58520`. The `contracts/`
folder is unchanged, though, and git hashes let you prove that without access to the private repo.

## What the two files are

Both are in the `verify/` folder of this tag, next to `verify.py`.

- `commit.raw`: the audited commit object, byte for byte. Its git hash is `ed58520…`. It names the commit's root
  tree, its parents, author, signature and message.
- `tree.raw`: the root tree object of that commit, byte for byte. It lists the top-level files and folders with
  their hashes, including `contracts`. It contains names and hashes only, no file contents.

## The check

1. `sha1("commit <size>\0" + commit.raw)` must equal `ed58520348f2eb05ba1903145c0a91f69cd0afde`, the hash in the reports.
2. `commit.raw` names root tree `497c1f2e61064c2aab8e85226460534512827e77`, and `sha1("tree <size>\0" + tree.raw)` must equal it.
3. In `tree.raw`, the `contracts` entry is `4cbfd5aa5866fd1e570ce4f7726ba65c4a6051f5`.
4. In the public tag, `contracts/` must hash to the same `4cbfd5aa5866fd1e570ce4f7726ba65c4a6051f5`.

Because each hash covers the full content beneath it, a match at step 4 means every file in `contracts/` is
identical to the audited code.

## Run it

```bash
git clone --branch audit-ed58520 https://github.com/Metricxyz/periphery-contracts.git
cd periphery-contracts
python verify/verify.py .
```

Expected output ends with:

```
OK: contracts/ at this tag is identical to contracts/ in audited commit ed58520348f2eb05ba1903145c0a91f69cd0afde
```

Or by hand with git only:

```bash
git hash-object -t commit verify/commit.raw   # ed58520348f2eb05ba1903145c0a91f69cd0afde
git hash-object -t tree verify/tree.raw       # 497c1f2e61064c2aab8e85226460534512827e77
git hash-object -w -t tree verify/tree.raw    # stores the tree object locally
git ls-tree 497c1f2e61064c2aab8e85226460534512827e77 contracts   # ... tree 4cbfd5aa5866fd1e570ce4f7726ba65c4a6051f5  contracts
git rev-parse HEAD:contracts              # 4cbfd5aa5866fd1e570ce4f7726ba65c4a6051f5
```

## What is not published

CI workflows, git hooks and internal scripts (`.github/`, `.githooks/`, `scripts/`, `justfile`) are left out. Everything else is as in the audited commit, plus this `VERIFY.md` and its `verify/` folder. Only
`contracts/` is claimed identical to the audited commit.

`lib/metric-core` is a submodule pinned to `d4d0e2a3a7d690fdfed9829239e5ec3d8c4c9575` in the private repository, so `git submodule update` can't fetch it. That commit is published, with its own proof, as tag [`audit-d4d0e2a`](https://github.com/Metricxyz/pool-contracts/tree/audit-d4d0e2a) of `pool-contracts`.

Note: the reports link to `github.com/Metricxyz/metric-periphery` and `github.com/Metric-OMM/metric-periphery`, the private repository. It is not public.
