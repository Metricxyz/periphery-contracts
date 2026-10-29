# Verifying audit-cc8fef9

The tag `audit-cc8fef9` publishes the contracts at commit `cc8fef9781fba405cfd1945fe6bf49a00da132bb` of our private repository `metric-periphery`. That commit is the version named in:

- **Zellic re-audit, September 2026** (`OMM Reaudit - Zellic Audit Report.pdf`, p. 10: "Only changes between cc8fef9...9b69f75"). The re-audit reviewed the changes from this commit to `9b69f75`, published as tag [`audit-9b69f75`](https://github.com/Metricxyz/periphery-contracts/tree/audit-9b69f75).

The public tag is a new commit without the private history, so its own hash is not `cc8fef9`. The `contracts/`
folder is unchanged, though, and git hashes let you prove that without access to the private repo.

## What the two files are

Both are in the `verify/` folder of this tag, next to `verify.py`.

- `commit.raw`: the audited commit object, byte for byte. Its git hash is `cc8fef9…`. It names the commit's root
  tree, its parents, author, signature and message.
- `tree.raw`: the root tree object of that commit, byte for byte. It lists the top-level files and folders with
  their hashes, including `contracts`. It contains names and hashes only, no file contents.

## The check

1. `sha1("commit <size>\0" + commit.raw)` must equal `cc8fef9781fba405cfd1945fe6bf49a00da132bb`, the hash in the reports.
2. `commit.raw` names root tree `20ba2770025bf62e40f50db42b7d4b605bbebd5b`, and `sha1("tree <size>\0" + tree.raw)` must equal it.
3. In `tree.raw`, the `contracts` entry is `b756bf2b72b53390f13a0102c38d1a669a122178`.
4. In the public tag, `contracts/` must hash to the same `b756bf2b72b53390f13a0102c38d1a669a122178`.

Because each hash covers the full content beneath it, a match at step 4 means every file in `contracts/` is
identical to the audited code.

## Run it

```bash
git clone --branch audit-cc8fef9 https://github.com/Metricxyz/periphery-contracts.git
cd periphery-contracts
python verify/verify.py .
```

Expected output ends with:

```
OK: contracts/ at this tag is identical to contracts/ in audited commit cc8fef9781fba405cfd1945fe6bf49a00da132bb
```

Or by hand with git only:

```bash
git hash-object -t commit verify/commit.raw   # cc8fef9781fba405cfd1945fe6bf49a00da132bb
git hash-object -t tree verify/tree.raw       # 20ba2770025bf62e40f50db42b7d4b605bbebd5b
git hash-object -w -t tree verify/tree.raw    # stores the tree object locally
git ls-tree 20ba2770025bf62e40f50db42b7d4b605bbebd5b contracts   # ... tree b756bf2b72b53390f13a0102c38d1a669a122178  contracts
git rev-parse HEAD:contracts              # b756bf2b72b53390f13a0102c38d1a669a122178
```

## What is not published

CI workflows, git hooks and internal scripts (`.github/`, `.githooks/`, `scripts/`, `justfile`) are left out. Everything else is as in the audited commit, plus this `VERIFY.md` and its `verify/` folder. Only
`contracts/` is claimed identical to the audited commit.

`lib/metric-core` is a submodule pinned to `72c65defe75d97f781596ee3fd74ce7c1f6fd729` in the private repository, so `git submodule update` can't fetch it. That commit is published, with its own proof, as tag [`audit-72c65de`](https://github.com/Metricxyz/pool-contracts/tree/audit-72c65de) of `pool-contracts`.

Note: the reports link to `github.com/Metricxyz/metric-periphery` and `github.com/Metric-OMM/metric-periphery`, the private repository. It is not public.
