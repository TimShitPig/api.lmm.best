# Repository agent instructions

## CodeGraph

This repository is indexed by CodeGraph when `.codegraph/` exists. Before
using `rg`, `find`, or opening source files to locate or understand code, use:

```sh
codegraph explore "<symbols or question>"
```

Prefer one focused exploration that names the relevant file, symbol, or call
path. Skip CodeGraph only when `.codegraph/` is absent.

## Instruction scope

- Preserve unrelated working-tree changes. Never stage, commit, overwrite, or
  discard them as part of another task.
- Read nested instruction files before editing their trees. In particular,
  `go/AGENTS.md` governs the upstream Go tree and `go/web/AGENTS.md` governs
  its bundled upstream frontend.
- Use feature branches for changes and do not push directly to `main`.

## Maintained Go source

- `go/` is the maintained Go service tree and a squash Git subtree of
  `https://github.com/QuantumNous/new-api.git`.
- The configured upstream remote name is `new-api-upstream`. The recorded
  initial upstream snapshot is maintained in `FORK.md`.
- LMM API Go changes, including channel-aware top-up pricing and FastPay
  compatibility, live directly in `go/`. Do not recreate
  `legacy-go-backup/`, `legacy-go-hotfix/`, or a separate hotfix patch flow.
- The repository root `web/` is the LMM API frontend. `go/web/` is the
  upstream subtree copy and must remain present so future subtree merges retain
  the upstream layout and history.
- Ignored Go binaries and packages belong under `go/out/`.

## Pulling new-api upstream

Perform upstream imports only from a clean, dedicated synchronization branch:

```sh
git switch -c chore/sync-new-api-YYYYMMDD
bash go/sync-upstream.sh main
```

Resolve subtree conflicts while preserving local payment, branding, migration,
and compatibility behavior. After a successful import, update the upstream
snapshot in `FORK.md` and follow `go/LMM-MAINTENANCE.md`.

At minimum, verify Go-specific changes with:

```sh
bash go/verify-channel-pricing-hotfix.sh
```

For a complete Go validation when dependencies and time permit:

```sh
(
  cd go
  go test ./...
)
```

Changes under `go/relaykit/` must also pass the independent-module check
required by `go/AGENTS.md`.

## Rust migration oracle

- Rust behavior-oracle and differential scripts consume the maintained source
  at `go/`; do not point them back to a frozen ignored directory.
- Use `rust/behavior-oracle/go-source-manifest.sh` when evidence needs a stable
  hash of current Go inputs.
- Updating upstream Go source can change the oracle contract. Review affected
  Rust differential results before claiming parity or changing route ownership.
