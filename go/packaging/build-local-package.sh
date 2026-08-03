#!/usr/bin/env bash
# Build a local Arch package from a separately built Go binary. This script
# never builds code, fetches sources, or reads the production environment file.

set -Eeuo pipefail

if (( EUID == 0 )); then
  printf '%s\n' 'error: run makepkg as an unprivileged build user' >&2
  exit 1
fi

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
go_root=$(cd -- "$package_dir/.." && pwd)
repo_root=$(cd -- "$go_root/.." && pwd)
input_binary="$go_root/out/lmm-api"
package_output=${LMM_API_PKGDEST:-"$go_root/out/packages"}

for tool in makepkg pacman bsdtar vercmp file readelf ldd sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'error: required command not found: %s\n' "$tool" >&2
    exit 1
  }
done

[[ -x $input_binary ]] || {
  printf 'error: expected executable prebuilt binary: %s\n' "$input_binary" >&2
  exit 1
}

for license_file in LICENSE NOTICE THIRD-PARTY-LICENSES.md; do
  [[ -f $repo_root/$license_file ]] || {
    printf 'error: missing repository legal file: %s\n' "$license_file" >&2
    exit 1
  }
done

current_version='0.1.0.r28.g3e39995.payrate1-1'
target_version=$(sed -n "s/^pkgver=['\"]\{0,1\}\([^'\"]*\).*/\1/p" "$package_dir/PKGBUILD")
target_pkgrel=$(sed -n "s/^pkgrel=['\"]\{0,1\}\([^'\"]*\).*/\1/p" "$package_dir/PKGBUILD")
[[ -n $target_version ]] || {
  printf '%s\n' 'error: could not read pkgver from PKGBUILD' >&2
  exit 1
}
[[ -n $target_pkgrel ]] || {
  printf '%s\n' 'error: could not read pkgrel from PKGBUILD' >&2
  exit 1
}
if (( $(vercmp "$current_version" "${target_version}-${target_pkgrel}") >= 0 )); then
  printf 'error: target version does not upgrade %s: %s-%s\n' \
    "$current_version" "$target_version" "$target_pkgrel" >&2
  exit 1
fi

file -b "$input_binary" | grep -Fq 'ELF 64-bit LSB executable, x86-64' || {
  printf 'error: expected x86-64 ELF executable: %s\n' "$input_binary" >&2
  exit 1
}
readelf -h "$input_binary" | grep -Fq 'Class:                             ELF64'
readelf -h "$input_binary" | grep -Fq 'Machine:                           Advanced Micro Devices X86-64'
binary_version=$("$input_binary" --version)
[[ $binary_version == "$target_version" ]] || {
  printf 'error: binary --version mismatch: expected %s, got %s\n' \
    "$target_version" "$binary_version" >&2
  exit 1
}
if readelf -d "$input_binary" | grep -Fq '(NEEDED)'; then
  printf '%s\n' 'error: expected statically linked binary; DT_NEEDED was present' >&2
  exit 1
fi
ldd_output=$(ldd "$input_binary" 2>&1 || true)
case $ldd_output in
  *'not a dynamic executable'*|*'statically linked'*) ;;
  *)
    printf 'error: expected static ldd result, got: %s\n' "$ldd_output" >&2
    exit 1
    ;;
esac

staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-git-package.XXXXXX")
build_pkgdest=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-git-pkgdest.XXXXXX")
trap 'rm -rf -- "$staging_dir" "$build_pkgdest"' EXIT
mkdir -p -- "$package_output"

for package_file in PKGBUILD lmm-api-git.install lmm-api.service lmm-api.env; do
  cp -- "$package_dir/$package_file" "$staging_dir/$package_file"
done
cp -- "$input_binary" "$staging_dir/lmm-api"
for license_file in LICENSE NOTICE THIRD-PARTY-LICENSES.md; do
  cp -- "$repo_root/$license_file" "$staging_dir/$license_file"
done

(
  cd -- "$staging_dir"
  PKGDEST="$build_pkgdest" makepkg --cleanbuild --force --noconfirm
)

shopt -s nullglob
package_matches=("$build_pkgdest/lmm-api-git-${target_version}-${target_pkgrel}-x86_64.pkg.tar."*)
shopt -u nullglob
[[ ${#package_matches[@]} -eq 1 ]] || {
  printf 'error: expected exactly one newly built package, found %s\n' \
    "${#package_matches[@]}" >&2
  exit 1
}
package_file=${package_matches[0]}

package_info=$(pacman -Qip "$package_file")
grep -Fqx 'Name            : lmm-api-git' <<<"$package_info"
grep -Fqx "Version         : ${target_version}-${target_pkgrel}" <<<"$package_info"
grep -Fqx 'Architecture    : x86_64' <<<"$package_info"

final_package="$package_output/$(basename -- "$package_file")"
final_checksum="${final_package}.sha256"
[[ ! -e $final_package && ! -e $final_checksum ]] || {
  printf 'error: exact output already exists; preserve it or remove it explicitly: %s\n' \
    "$final_package" >&2
  exit 1
}
package_sha256=$(sha256sum "$package_file")
package_sha256=${package_sha256%% *}
install -Dm0644 "$package_file" "$final_package"
printf '%s  %s\n' "$package_sha256" "$(basename -- "$final_package")" >"$final_checksum"
chmod 0644 "$final_checksum"

printf '%s\n' "$package_info"
bsdtar -tf "$final_package" | sort
printf 'package sha256: %s\n' "$(<"$final_checksum")"
printf 'built package: %s\n' "$final_package"
