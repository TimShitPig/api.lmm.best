# LMM API Go package

This is the retained Go-only legacy package flow. New selectable installations
should use the split pkgbase in `../../packaging/aur/lmm-api/`, where
`lmm-api-go` is the default backend and `lmm-api-rs` is optional. Keep this
flow available for existing `lmm-api-git` upgrades until those hosts migrate.

`build-local-package.sh` packages only a prebuilt, version-checked
`../out/lmm-api` binary. It never reads `/etc/lmm-api/lmm-api.env`, builds Go,
downloads sources, restarts `lmm-api.service`, or accesses the SQLite database.

The package declares `etc/lmm-api/lmm-api.env` as a pacman `backup` file. The
install hook snapshots the existing file before every package upgrade and
restores it after package extraction. This preserves the production-style
`0600` environment file even when pacman chooses a different ordinary backup
resolution for the packaged template. A snapshot contains credentials and must
be treated as a secret. It is stored root-only at:

`/var/lib/lmm-api/package-backups/lmm-api.env.pre-upgrade-<version>`

The directory mode is `0700`; package-hook snapshots are env-only safety copies
and are separate from the complete rollback bundles below. Review and remove
older env-only copies manually as root only after a complete rollback bundle is
verified. Do not copy snapshots into the repository or build output.

Pacman may create `lmm-api.env.pacnew` when its normal backup-file rules call
for it. Its presence is intentionally not required for a successful upgrade:
the original configured environment is restored from the hook snapshot either
way. If a `.pacnew` is created, inspect it, verify it contains no site
configuration, and remove or merge it manually as appropriate.

Before `pacman -U`, run `backup-server-state.sh --destination /root/rollback/lmm-api`.
It snapshots the binary, unit, env, unit drop-ins, package metadata/integrity,
and an online SQLite `.backup`; it validates `quick_check` and checksums before
retaining only the newest three validated complete snapshot directories.
