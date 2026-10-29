# Verifying audit-378a748

The tag `audit-378a748` publishes the contracts at commit `378a748793eee3d0b25e8651c0043fc0add1c37c` of our private repository `metric-periphery`. That commit is the version named in:

- **Sherlock periphery update review, September 2026** (`2026.10.10 - Final - Metric Collaborative Audit Report`, p. 2: "Audited Commit: 378a748793…")

The public tag is a new commit without the private history, so its own hash is not `378a748`. The `contracts/`
folder is unchanged, though, and git hashes let you prove that without access to the private repo.

## What the two files are

Both are in the `verify/` folder of this tag, next to `verify.py`.

- `commit.raw`: the audited commit object, byte for byte. Its git hash is `378a748…`. It names the commit's root
  tree, its parents, author, signature and message.
- `tree.raw`: the root tree object of that commit, byte for byte. It lists the top-level files and folders with
  their hashes, including `contracts`. It contains names and hashes only, no file contents.

## The check

1. `sha1("commit <size>\0" + commit.raw)` must equal `378a748793eee3d0b25e8651c0043fc0add1c37c`, the hash in the reports.
2. `commit.raw` names root tree `067d8d86237c164e2c514b4832a646d4b79d4c59`, and `sha1("tree <size>\0" + tree.raw)` must equal it.
3. In `tree.raw`, the `contracts` entry is `97b1ec583933735d23a3e250e25978591b57e8cf`.
4. In the public tag, `contracts/` must hash to the same `97b1ec583933735d23a3e250e25978591b57e8cf`.

Because each hash covers the full content beneath it, a match at step 4 means every file in `contracts/` is
identical to the audited code.

## Run it

```bash
git clone --branch audit-378a748 https://github.com/Metricxyz/periphery-contracts.git
cd periphery-contracts
python verify/verify.py .
```

Expected output ends with:

```
OK: contracts/ at this tag is identical to contracts/ in audited commit 378a748793eee3d0b25e8651c0043fc0add1c37c
```

Or by hand with git only:

```bash
git hash-object -t commit verify/commit.raw   # 378a748793eee3d0b25e8651c0043fc0add1c37c
git hash-object -t tree verify/tree.raw       # 067d8d86237c164e2c514b4832a646d4b79d4c59
git hash-object -w -t tree verify/tree.raw    # stores the tree object locally
git ls-tree 067d8d86237c164e2c514b4832a646d4b79d4c59 contracts   # ... tree 97b1ec583933735d23a3e250e25978591b57e8cf  contracts
git rev-parse HEAD:contracts              # 97b1ec583933735d23a3e250e25978591b57e8cf
```

## What is not published

CI workflows, git hooks and internal scripts (`.github/`, `.githooks/`, `scripts/`, `justfile`) are left out. Everything else is as in the audited commit, plus this `VERIFY.md` and its `verify/` folder. Only
`contracts/` is claimed identical to the audited commit.

`lib/metric-core` is a submodule pinned to `d4d0e2a3a7d690fdfed9829239e5ec3d8c4c9575` in the private repository, so `git submodule update` can't fetch it. That commit is published, with its own proof, as tag [`audit-d4d0e2a`](https://github.com/Metricxyz/pool-contracts/tree/audit-d4d0e2a) of `pool-contracts`.

Note: the reports link to `github.com/Metricxyz/metric-periphery` and `github.com/Metric-OMM/metric-periphery`, the private repository. It is not public.
