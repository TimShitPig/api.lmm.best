# LMM API fork

LMM API is a maintained fork of [QuantumNous/new-api](https://github.com/QuantumNous/new-api).

- Upstream snapshot: commit `66ee6b8f9889050ffef1f863a4314ce4a0516fb9`, dated 2026-07-29
- License: GNU Affero General Public License v3.0 (`AGPL-3.0`)
- Local user-facing brand: `LMM API`

The upstream copyright notices, attribution, `NOTICE`, and
`THIRD-PARTY-LICENSES.md` are preserved. Modified user interfaces must retain
the original-project link and attribution required by `NOTICE`.

Upstream updates should be imported as reviewed, pinned snapshots. Compare the
new snapshot with the recorded commit, preserve local branding as a small
focused patch, retain compatibility identifiers, and run the relevant
validation before accepting the update.

The maintained upstream subtree now lives in `go/`. Use
`bash go/sync-upstream.sh main` from a clean synchronization branch, resolve
the subtree merge against local LMM API changes, update the snapshot above,
and run the checks documented in `go/LMM-MAINTENANCE.md`.
