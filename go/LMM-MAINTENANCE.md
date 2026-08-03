# LMM API Go source maintenance

`go/` is the maintained Go service tree. It combines:

- the `QuantumNous/new-api` upstream subtree, initially imported from commit
  `66ee6b8f9889050ffef1f863a4314ce4a0516fb9`;
- the former frozen LMM API Go snapshot from commit
  `5418ce6b6d45ed69167b0aad53f2f595e5bc8de9`;
- the channel-aware top-up pricing and signed ePay callback checks that were
  formerly stored as `legacy-go-hotfix/channel-pricing.patch`.

The hotfix is now ordinary Go source and tests, so it is reviewed and merged
alongside upstream changes. The original freeze manifests are retained under
`.legacy-archive/` for provenance checks.

The root `web/` directory remains the LMM API frontend. `go/web/` belongs to
the upstream subtree and is kept so subtree pulls retain the complete upstream
history and layout. Production Go builds explicitly receive a verified web
distribution with `--web-dist`.

## Pull upstream changes

Start from a clean worktree on a dedicated branch:

```sh
git switch -c chore/sync-new-api-YYYYMMDD
bash go/sync-upstream.sh main
```

The sync script registers `https://github.com/QuantumNous/new-api.git` as the
`new-api-upstream` remote when needed, fetches the requested ref, and performs
a squash subtree merge into `go/`. Resolve conflicts in favor of current LMM
API behavior where local payment, branding, or migration compatibility differs
from upstream. Then update the snapshot recorded in `FORK.md` and verify:

```sh
bash go/verify-channel-pricing-hotfix.sh
(
  cd go
  go test ./...
)
```

## Build and package

The production builder archives the committed `go/` tree from `HEAD` by
default, injects a separately verified frontend distribution, and performs the
same static-binary assertions as the former hotfix builder:

```sh
bash go/build-production-binary.sh --web-dist /path/to/verified/web/dist
bash go/packaging/build-local-package.sh
```

Pass `--source-ref REF` to build another committed revision. Package and server
backup details remain in `packaging/README.md`.
