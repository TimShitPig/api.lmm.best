# LMM API selectable backend packages

This directory is one Arch/AUR split pkgbase with three installable packages:

- `lmm-api`: shared `lmm-api.service`, configuration, launcher, and selector.
- `lmm-api-go`: the default `QuantumNous/new-api` Go backend with maintained
  LMM changes from `go/`.
- `lmm-api-rs`: the optional Rust migration-preview backend from `rust/`.

The backend packages install into separate directories and can coexist. The
default `auto` selection prefers Go, so the normal installation is:

```sh
paru -S lmm-api lmm-api-go
```

Install Rust as an additional optional implementation and switch explicitly:

```sh
paru -S lmm-api-rs
sudo lmm-api-select rs
sudo systemctl restart lmm-api.service
```

Use `sudo lmm-api-select go` to return to Go, or `auto` to prefer Go whenever
it is installed. `lmm-api-select status` is read-only.

Rust currently implements the migration surface and does not yet own every Go
production route. Its PostgreSQL, Valkey, schema-contract, and secret settings
must be added to `/etc/lmm-api/lmm-api.env`; start from
`/usr/share/doc/lmm-api/lmm-api-rs.env.example`. The Rust launcher binds to
`127.0.0.1:${PORT:-3000}` unless `LMM_RS_LISTEN_ADDR` is configured.

## Local package build

Prepare these existing artifacts first:

- `go/out/lmm-api`
- `rust/target/release/lmm-api-rs`
- `rust/target/release/lmm-db-migrate`
- `web/dist/index.html`

Then run:

```sh
bash packaging/aur/lmm-api/build-local-package.sh
```

The builder produces all three packages in `packaging/aur/lmm-api/out/`. It
does not install them or modify services. Run the static and package-layout
contract with:

```sh
bash packaging/aur/lmm-api/test-package.sh
```
