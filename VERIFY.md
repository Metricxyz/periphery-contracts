# Verifying audit-90039f9

The tag `audit-90039f9` publishes the contracts at commit `90039f9b68f6b2253425acfb6497fcf38e28cc17` of our private repository `metric-periphery`. That commit is the version named in:

- **Sherlock collaborative audit, May–June 2026** (`2026.07.06 - Final - Metric Collaborative Audit Report`, p. 3: "AuditedCommit: 90039f9b68…")

The public tag is a new commit without the private history, so its own hash is not `90039f9`. The `contracts/`
folder is unchanged, though, and git hashes let you prove that without access to the private repo.

## What the two files are

Both are in the `verify/` folder of this tag, next to `verify.py`.

- `commit.raw`: the audited commit object, byte for byte. Its git hash is `90039f9…`. It names the commit's root
  tree, its parents, author, signature and message.
- `tree.raw`: the root tree object of that commit, byte for byte. It lists the top-level files and folders with
  their hashes, including `contracts`. It contains names and hashes only, no file contents.

## The check

1. `sha1("commit <size>\0" + commit.raw)` must equal `90039f9b68f6b2253425acfb6497fcf38e28cc17`, the hash in the reports.
2. `commit.raw` names root tree `8ec18d11ef4a33aa3c53aebff1fcb724cdeb3a85`, and `sha1("tree <size>\0" + tree.raw)` must equal it.
3. In `tree.raw`, the `contracts` entry is `607ff7f1c5ceb6342b4053854acdfb868787a65c`.
4. In the public tag, `contracts/` must hash to the same `607ff7f1c5ceb6342b4053854acdfb868787a65c`.

Because each hash covers the full content beneath it, a match at step 4 means every file in `contracts/` is
identical to the audited code.

## Run it

```bash
git clone --branch audit-90039f9 https://github.com/Metricxyz/periphery-contracts.git
cd periphery-contracts
python verify/verify.py .
```

Expected output ends with:

```
OK: contracts/ at this tag is identical to contracts/ in audited commit 90039f9b68f6b2253425acfb6497fcf38e28cc17
```

Or by hand with git only:

```bash
git hash-object -t commit verify/commit.raw   # 90039f9b68f6b2253425acfb6497fcf38e28cc17
git hash-object -t tree verify/tree.raw       # 8ec18d11ef4a33aa3c53aebff1fcb724cdeb3a85
git hash-object -w -t tree verify/tree.raw    # stores the tree object locally
git ls-tree 8ec18d11ef4a33aa3c53aebff1fcb724cdeb3a85 contracts   # ... tree 607ff7f1c5ceb6342b4053854acdfb868787a65c  contracts
git rev-parse HEAD:contracts              # 607ff7f1c5ceb6342b4053854acdfb868787a65c
```

## What is not published

CI workflows, git hooks and internal scripts (`.github/`, `.githooks/`, `scripts/`, `justfile`) are left out. Everything else is as in the audited commit, plus this `VERIFY.md` and its `verify/` folder. Only
`contracts/` is claimed identical to the audited commit.

`lib/metric-core` is a submodule pinned to `6aa6c3b489b84b8b1c50dc6a4967184df17aa395` in the private repository, so `git submodule update` can't fetch it. That commit is published, with its own proof, as tag [`audit-6aa6c3b`](https://github.com/Metricxyz/pool-contracts/tree/audit-6aa6c3b) of `pool-contracts`.

Note: the reports link to `github.com/Metricxyz/metric-periphery` and `github.com/Metric-OMM/metric-periphery`, the private repository. It is not public.
