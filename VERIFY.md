# Verifying audit-d210a84

The tag `audit-d210a84` publishes the contracts at commit `d210a84daf694c52a591d371ceb9b82cece0f79f` of our private repository `metric-periphery`. That commit is the version named in:

- **Sherlock collaborative audit, May–June 2026** (`2026.07.06 - Final - Metric Collaborative Audit Report`, p. 3: "FinalCommit: d210a84daf…")
- **Sherlock bug bounty contest, September 2026** (`2026.09.15 - Final - Metric Public Bug Bounty Audit Contest Report`, p. 3: "AuditedCommit: d210a84daf…")

The public tag is a new commit without the private history, so its own hash is not `d210a84`. The `contracts/`
folder is unchanged, though, and git hashes let you prove that without access to the private repo.

## What the two files are

Both are in the `verify/` folder of this tag, next to `verify.py`.

- `commit.raw`: the audited commit object, byte for byte. Its git hash is `d210a84…`. It names the commit's root
  tree, its parents, author, signature and message.
- `tree.raw`: the root tree object of that commit, byte for byte. It lists the top-level files and folders with
  their hashes, including `contracts`. It contains names and hashes only, no file contents.

## The check

1. `sha1("commit <size>\0" + commit.raw)` must equal `d210a84daf694c52a591d371ceb9b82cece0f79f`, the hash in the reports.
2. `commit.raw` names root tree `39860d7097a4272d731ef24491af7154c351ff96`, and `sha1("tree <size>\0" + tree.raw)` must equal it.
3. In `tree.raw`, the `contracts` entry is `fa3c0ec0b2ad2f804ac71ee5f2f3a593a2ff10aa`.
4. In the public tag, `contracts/` must hash to the same `fa3c0ec0b2ad2f804ac71ee5f2f3a593a2ff10aa`.

Because each hash covers the full content beneath it, a match at step 4 means every file in `contracts/` is
identical to the audited code.

## Run it

```bash
git clone --branch audit-d210a84 https://github.com/Metricxyz/periphery-contracts.git
cd periphery-contracts
python verify/verify.py .
```

Expected output ends with:

```
OK: contracts/ at this tag is identical to contracts/ in audited commit d210a84daf694c52a591d371ceb9b82cece0f79f
```

Or by hand with git only:

```bash
git hash-object -t commit verify/commit.raw   # d210a84daf694c52a591d371ceb9b82cece0f79f
git hash-object -t tree verify/tree.raw       # 39860d7097a4272d731ef24491af7154c351ff96
git hash-object -w -t tree verify/tree.raw    # stores the tree object locally
git ls-tree 39860d7097a4272d731ef24491af7154c351ff96 contracts   # ... tree fa3c0ec0b2ad2f804ac71ee5f2f3a593a2ff10aa  contracts
git rev-parse HEAD:contracts              # fa3c0ec0b2ad2f804ac71ee5f2f3a593a2ff10aa
```

## What is not published

CI workflows, git hooks and internal scripts (`.github/`, `.githooks/`, `scripts/`, `justfile`) are left out. Everything else is as in the audited commit, plus this `VERIFY.md` and its `verify/` folder. Only
`contracts/` is claimed identical to the audited commit.

`lib/metric-core` is a submodule pinned to `7b9ab567631a234ba5d467c646a1da9cbfb25479` in the private repository, so `git submodule update` can't fetch it. That commit is published, with its own proof, as tag [`audit-7b9ab56`](https://github.com/Metricxyz/pool-contracts/tree/audit-7b9ab56) of `pool-contracts`.

Note: the reports link to `github.com/Metricxyz/metric-periphery` and `github.com/Metric-OMM/metric-periphery`, the private repository. It is not public.
