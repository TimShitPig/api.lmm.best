#!/usr/bin/env bash
# Validate package metadata and execute its real pacman scriptlet transaction
# in a disposable user namespace and chroot. No sudo or host pacman DB is used.

set -Eeuo pipefail

digest() {
  sha256sum "$1" | awk '{print $1}'
}

copy_runtime_file() {
  local source=$1 resolved
  resolved=$(readlink -f -- "$source")
  install -D -m 0755 "$source" "$PACMAN_ROOT$source"
  if [[ $resolved != "$source" ]]; then
    install -D -m 0755 "$resolved" "$PACMAN_ROOT$resolved"
  fi
}

copy_runtime_program() {
  local program=$1 resolved library
  resolved=$(readlink -f -- "$(command -v "$program")")
  copy_runtime_file "$(command -v "$program")"
  while IFS= read -r library; do
    [[ -n $library && -e $library ]] && copy_runtime_file "$library"
  done < <(ldd "$resolved" | awk '/=> \/.*\(/ {print $1; print $3} /^\// {print $1}')
}

if [[ ${1:-} == '--pacman-transaction' ]]; then
  old_package=$2
  new_package=$3
  PACMAN_ROOT=$4
  mkdir -p -- "$PACMAN_ROOT/var/lib/pacman" "$PACMAN_ROOT/var/cache/pacman/pkg" \
    "$PACMAN_ROOT/var/log" "$PACMAN_ROOT/var/lib/private/lmm-api"
  copy_runtime_program bash
  copy_runtime_program env
  copy_runtime_program cp
  copy_runtime_program install
  mkdir -p -- "$PACMAN_ROOT/bin"
  ln -s /usr/bin/bash "$PACMAN_ROOT/bin/sh"
  ln -s /usr/bin/bash "$PACMAN_ROOT/bin/bash"
  chroot "$PACMAN_ROOT" /usr/bin/env bash -c 'command -v cp; command -v install'
  cat >"$PACMAN_ROOT/pacman.conf" <<EOF
[options]
RootDir = $PACMAN_ROOT
DBPath = $PACMAN_ROOT/var/lib/pacman
CacheDir = $PACMAN_ROOT/var/cache/pacman/pkg
LogFile = $PACMAN_ROOT/var/log/pacman.log
SigLevel = Never
EOF
  pacman_args=(--config "$PACMAN_ROOT/pacman.conf" --noconfirm --nodeps --nodeps)
  pacman "${pacman_args[@]}" -U "$old_package" >/dev/null
  custom_env="$PACMAN_ROOT/etc/lmm-api/lmm-api.env"
  printf '%s\n' 'DATABASE_URL=sqlite:///secret-not-a-real-value' >"$custom_env"
  chmod 0600 "$custom_env"
  env_hash_before=$(digest "$custom_env")
  env_mode_before=$(stat -c '%a' "$custom_env")
  db_path="$PACMAN_ROOT/var/lib/private/lmm-api/one-api.db"
  printf '%s\n' 'database sentinel: must remain untouched' >"$db_path"
  db_hash_before=$(digest "$db_path")

  pacman "${pacman_args[@]}" -U "$new_package" >/dev/null
  [[ $(digest "$custom_env") == "$env_hash_before" ]]
  [[ $(stat -c '%a' "$custom_env") == "$env_mode_before" ]]
  [[ $(digest "$db_path") == "$db_hash_before" ]]
  snapshot="$PACMAN_ROOT/var/lib/lmm-api/package-backups/lmm-api.env.pre-upgrade-0.1.0.r29.g3e39995.payrate2-1"
  [[ -f $snapshot ]]
  [[ $(stat -c '%a' "$(dirname -- "$snapshot")") == '700' ]]
  [[ $(digest "$snapshot") == "$env_hash_before" ]]
  pacnew="${custom_env}.pacnew"
  if [[ -e $pacnew ]]; then
    [[ -f $pacnew ]]
    [[ $(stat -c '%a' "$pacnew") == '600' ]]
    grep -Fqx '# Deliberately non-secret package default.' "$pacnew"
  fi
  exit 0
fi

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$package_dir/../.." && pwd)
current_version='0.1.0.r28.g3e39995.payrate1-1'
target_version='0.1.0.r29.g3e39995.payrate2-1'

for tool in bash shellcheck vercmp makepkg pacman bsdtar sha256sum stat readlink ldd awk unshare chroot; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'error: missing %s\n' "$tool" >&2; exit 1; }
done
bash -n "$package_dir/lmm-api-git.install" "$package_dir/build-local-package.sh" "$package_dir/test-package.sh"
shellcheck "$package_dir/lmm-api-git.install" "$package_dir/build-local-package.sh" "$package_dir/test-package.sh"
(( $(vercmp "$current_version" "$target_version") < 0 ))
grep -Fqx "backup=('etc/lmm-api/lmm-api.env')" "$package_dir/PKGBUILD"
grep -Fqx 'DynamicUser=yes' "$package_dir/lmm-api.service"
if grep -Eq '^(User|Group)=' "$package_dir/lmm-api.service"; then exit 1; fi
if grep -Eq 'LMM_API_INSTALL_ROOT|systemctl|sqlite3|one-api\.db' "$package_dir/lmm-api-git.install"; then exit 1; fi

staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-git-package-test.XXXXXX")
trap 'rm -rf -- "$staging_dir"' EXIT
cp -- "$package_dir/PKGBUILD" "$package_dir/lmm-api-git.install" \
  "$package_dir/lmm-api.service" "$package_dir/lmm-api.env" "$staging_dir/"
printf '#!/usr/bin/env sh\nexit 0\n' >"$staging_dir/lmm-api"
chmod 0755 "$staging_dir/lmm-api"
for license_file in LICENSE NOTICE THIRD-PARTY-LICENSES.md; do cp -- "$repo_root/$license_file" "$staging_dir/$license_file"; done
(
  cd -- "$staging_dir"
  makepkg --nodeps --cleanbuild --force --noconfirm >/dev/null
)
new_package=$(find "$staging_dir" -maxdepth 1 -type f -name 'lmm-api-git-0.1.0.r29.g3e39995.payrate2-1-x86_64.pkg.tar.*' -print -quit)
[[ -n $new_package ]]
pacman -Qip "$new_package" | grep -Fqx 'Name            : lmm-api-git'
bsdtar -xOf "$new_package" .PKGINFO | grep -Fqx 'backup = etc/lmm-api/lmm-api.env'

old_stage="$staging_dir/old"
mkdir -p -- "$old_stage"
cat >"$old_stage/PKGBUILD" <<'EOF'
pkgname=lmm-api-git
pkgver=0.1.0.r28.g3e39995.payrate1
pkgrel=1
pkgdesc='test-only old lmm-api package'
arch=('x86_64')
license=('AGPL-3.0-only')
source=('lmm-api' 'lmm-api.env')
sha256sums=('SKIP' 'SKIP')
backup=('etc/lmm-api/lmm-api.env')
package() {
  install -Dm0755 "$srcdir/lmm-api" "$pkgdir/usr/bin/lmm-api"
  install -Dm0600 "$srcdir/lmm-api.env" "$pkgdir/etc/lmm-api/lmm-api.env"
}
EOF
printf '#!/usr/bin/env sh\nexit 0\n' >"$old_stage/lmm-api"
chmod 0755 "$old_stage/lmm-api"
printf '%s\n' 'OLD_PACKAGE_DEFAULT=1' >"$old_stage/lmm-api.env"
(
  cd -- "$old_stage"
  makepkg --nodeps --cleanbuild --force --noconfirm >/dev/null
)
old_package=$(find "$old_stage" -maxdepth 1 -type f -name 'lmm-api-git-0.1.0.r28.g3e39995.payrate1-1-x86_64.pkg.tar.*' -print -quit)
[[ -n $old_package ]]
bsdtar -xOf "$old_package" .PKGINFO | grep -Fqx 'backup = etc/lmm-api/lmm-api.env'

pacman_root="$staging_dir/pacman-root"
unshare --user --map-root-user --mount --fork \
  bash "$package_dir/test-package.sh" --pacman-transaction \
  "$old_package" "$new_package" "$pacman_root"

printf '%s\n' 'lmm-api-git package checks passed'
