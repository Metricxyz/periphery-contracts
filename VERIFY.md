# Verifying audit-0069084

The tag `audit-0069084` publishes the contracts at commit `0069084b927ebe891c6e7712c459ce4ac7e3118f` of our private repository `metric-periphery`. That commit is the version named in:

- **Zellic audit, June 2026** (`Metric OMM - Zellic Audit Report.pdf`, p. 10: "Version 0069084b92…")

The public tag is a new commit without the private history, so its own hash is not `0069084`. The `contracts/`
folder is unchanged, though, and git hashes let you prove that without access to the private repo.

## What the two files are

Both are in the `verify/` folder of this tag, next to `verify.py`.

- `commit.raw`: the audited commit object, byte for byte. Its git hash is `0069084…`. It names the commit's root
  tree, its parents, author, signature and message.
- `tree.raw`: the root tree object of that commit, byte for byte. It lists the top-level files and folders with
  their hashes, including `contracts`. It contains names and hashes only, no file contents.

## The check

1. `sha1("commit <size>\0" + commit.raw)` must equal `0069084b927ebe891c6e7712c459ce4ac7e3118f`, the hash in the reports.
2. `commit.raw` names root tree `74f863a869235443b1460d6e6e1797e83c3d4fd6`, and `sha1("tree <size>\0" + tree.raw)` must equal it.
3. In `tree.raw`, the `contracts` entry is `4c9d8d975e89e4975abddfebddf21f6c53a1919e`.
4. In the public tag, `contracts/` must hash to the same `4c9d8d975e89e4975abddfebddf21f6c53a1919e`.

Because each hash covers the full content beneath it, a match at step 4 means every file in `contracts/` is
identical to the audited code.

## Run it

```bash
git clone --branch audit-0069084 https://github.com/Metricxyz/periphery-contracts.git
cd periphery-contracts
python verify/verify.py .
```

Expected output ends with:

```
OK: contracts/ at this tag is identical to contracts/ in audited commit 0069084b927ebe891c6e7712c459ce4ac7e3118f
```

Or by hand with git only:

```bash
git hash-object -t commit verify/commit.raw   # 0069084b927ebe891c6e7712c459ce4ac7e3118f
git hash-object -t tree verify/tree.raw       # 74f863a869235443b1460d6e6e1797e83c3d4fd6
git hash-object -w -t tree verify/tree.raw    # stores the tree object locally
git ls-tree 74f863a869235443b1460d6e6e1797e83c3d4fd6 contracts   # ... tree 4c9d8d975e89e4975abddfebddf21f6c53a1919e  contracts
git rev-parse HEAD:contracts              # 4c9d8d975e89e4975abddfebddf21f6c53a1919e
```

## What is not published

CI workflows, git hooks and internal scripts (`.github/`, `.githooks/`, `scripts/`, `justfile`) are left out. Everything else is as in the audited commit, plus this `VERIFY.md` and its `verify/` folder. Only
`contracts/` is claimed identical to the audited commit.

`lib/metric-core` is a submodule pinned to `6aa6c3b489b84b8b1c50dc6a4967184df17aa395` in the private repository, so `git submodule update` can't fetch it. That commit is published, with its own proof, as tag [`audit-6aa6c3b`](https://github.com/Metricxyz/pool-contracts/tree/audit-6aa6c3b) of `pool-contracts`.

Note: the reports link to `github.com/Metricxyz/metric-periphery` and `github.com/Metric-OMM/metric-periphery`, the private repository. It is not public.
