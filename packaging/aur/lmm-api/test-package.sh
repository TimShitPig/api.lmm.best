#!/usr/bin/env bash
set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly HERE

die() {
  printf 'test-package: %s\n' "$*" >&2
  exit 1
}

for command in bash bsdtar makepkg pacman shellcheck tar; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

bash -n "$HERE/lmm-api-launcher" "$HERE/lmm-api-select" \
  "$HERE/lmm-api.install" "$HERE/build-local-package.sh" "$HERE/test-package.sh"
shellcheck "$HERE/lmm-api-launcher" "$HERE/lmm-api-select" \
  "$HERE/lmm-api.install" "$HERE/build-local-package.sh" "$HERE/test-package.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-split-test.XXXXXXXX")
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

backend_root="$tmp/backends"
mkdir -p -- "$backend_root/go" "$backend_root/rs" "$tmp/etc"
# shellcheck disable=SC2016 # Write literal fixture source for a child process.
printf '%s\n' '#!/usr/bin/env bash' 'printf "go:%s\n" "$*"' \
  >"$backend_root/go/lmm-api"
# shellcheck disable=SC2016 # Write literal fixture source for a child process.
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "rs:%s:%s:%s\n" "$LMM_RS_SLOT" "$LMM_RS_LISTEN_ADDR" "$LMM_WEB_DIST_DIR"' \
  >"$backend_root/rs/lmm-api-rs"
chmod 0755 "$backend_root/go/lmm-api" "$backend_root/rs/lmm-api-rs"

output=$(LMM_API_BACKEND_ROOT="$backend_root" LMM_API_BACKEND=auto \
  "$HERE/lmm-api-launcher" marker)
[[ $output == 'go:marker' ]] || die 'auto did not prefer Go'
output=$(LMM_API_BACKEND_ROOT="$backend_root" LMM_API_BACKEND=rs PORT=3456 \
  LMM_API_FRONTEND_DIR="$tmp/frontend" "$HERE/lmm-api-launcher")
[[ $output == "rs:blue:127.0.0.1:3456:$tmp/frontend" ]] || \
  die 'Rust defaults were not exported'

config="$tmp/etc/backend.conf"
LMM_API_BACKEND_ROOT="$backend_root" LMM_API_BACKEND_CONFIG="$config" \
  "$HERE/lmm-api-select" rs >/dev/null
grep -Fqx 'LMM_API_BACKEND=rs' "$config" || die 'selector did not persist Rust'
status=$(LMM_API_BACKEND_ROOT="$backend_root" LMM_API_BACKEND_CONFIG="$config" \
  "$HERE/lmm-api-select" status)
grep -Fqx 'configured=rs' <<<"$status" || die 'selector status lost configuration'
grep -Fqx 'resolved=rs' <<<"$status" || die 'selector status did not resolve Rust'

stage="$tmp/stage"
mkdir -p -- "$stage/frontend-source" "$tmp/makepkg"
cp -- "$HERE/PKGBUILD" "$HERE/lmm-api-launcher" "$HERE/lmm-api-select" \
  "$HERE/lmm-api.service" "$HERE/lmm-api.env" "$HERE/backend.conf" \
  "$HERE/lmm-api.install" "$HERE/lmm-api-rs.env.example" "$stage/"
printf '#!/usr/bin/env bash\nexit 0\n' >"$stage/lmm-api-go-bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$stage/lmm-api-rs-bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$stage/lmm-db-migrate-bin"
chmod 0755 "$stage/lmm-api-go-bin" "$stage/lmm-api-rs-bin" \
  "$stage/lmm-db-migrate-bin"
printf '<!doctype html>\n' >"$stage/frontend-source/index.html"
tar -C "$stage/frontend-source" -cf "$stage/frontend-dist.tar" .
for file in LICENSE NOTICE THIRD-PARTY-LICENSES.md; do
  printf 'test fixture\n' >"$stage/$file"
done
(
  cd -- "$stage"
  BUILDDIR="$tmp/makepkg" LMM_API_PKGVER=0.1.0.test LMM_API_PKGREL=1 \
    makepkg --force --nodeps --noconfirm --cleanbuild >/dev/null
)

common=$(find "$stage" -maxdepth 1 -type f -name 'lmm-api-0.1.0.test-1-x86_64.pkg.tar.*' -print -quit)
go_package=$(find "$stage" -maxdepth 1 -type f -name 'lmm-api-go-0.1.0.test-1-x86_64.pkg.tar.*' -print -quit)
rs_package=$(find "$stage" -maxdepth 1 -type f -name 'lmm-api-rs-0.1.0.test-1-x86_64.pkg.tar.*' -print -quit)
[[ -n $common && -n $go_package && -n $rs_package ]] || die 'split package build is incomplete'

bsdtar -tf "$common" | grep -Fxq 'usr/bin/lmm-api' || die 'common launcher is missing'
bsdtar -tf "$common" | grep -Fxq 'usr/bin/lmm-api-select' || die 'selector is missing'
bsdtar -tf "$go_package" | grep -Fxq 'usr/lib/lmm-api/backends/go/lmm-api' || \
  die 'Go backend is missing'
bsdtar -tf "$rs_package" | grep -Fxq 'usr/lib/lmm-api/backends/rs/lmm-api-rs' || \
  die 'Rust backend is missing'
bsdtar -tf "$rs_package" | grep -Fxq 'usr/share/lmm-api/frontend-dist/index.html' || \
  die 'Rust frontend is missing'
if bsdtar -tf "$common" | grep -Eq 'usr/lib/lmm-api/backends/(go|rs)/'; then
  die 'common package owns backend files'
fi
pacman -Qip "$common" | grep -Fq 'lmm-api-go=0.1.0.test-1: default upstream Go backend' || \
  die 'Go optional dependency is missing'
pacman -Qip "$common" | grep -Fq 'lmm-api-rs=0.1.0.test-1: optional Rust migration-preview backend' || \
  die 'Rust optional dependency is missing'

printf '%s\n' 'lmm-api split package checks passed'
