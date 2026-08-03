#!/usr/bin/env bash
# Create a complete, local rollback snapshot before installing lmm-api-git.

set -Eeuo pipefail

usage() {
  printf '%s\n' 'usage: backup-server-state.sh --destination /absolute/rollback-root [--retain 3]'
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

destination=''
retain=3
prune_only=false
while (( $# > 0 )); do
  case $1 in
    --destination) destination=${2:-}; shift 2 ;;
    --retain) retain=${2:-}; shift 2 ;;
    --prune-only) prune_only=true; shift ;;
    --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

(( EUID == 0 )) || die 'run as root on the production host'
[[ $destination == /* && $destination != / && $destination != *'..'* ]] || die 'destination must be a safe absolute path'
[[ $retain =~ ^[1-9][0-9]*$ ]] || die 'retain must be a positive integer'
for command in sha256sum find sort stat realpath; do command -v "$command" >/dev/null || die "missing command: $command"; done

prune_snapshots() {
  local candidate delete_count
  local -a complete_snapshots valid_snapshots
  mapfile -t complete_snapshots < <(find "$destination" -mindepth 1 -maxdepth 1 -type d -name 'lmm-api-*' -print | sort)
  for candidate in "${complete_snapshots[@]}"; do
    candidate=$(realpath -e -- "$candidate")
    [[ $candidate == "$destination"/lmm-api-* && -f $candidate/COMPLETE && -f $candidate/sha256sums.txt ]] || continue
    if ( cd -- "$candidate" && sha256sum -c sha256sums.txt >/dev/null ); then
      valid_snapshots+=("$candidate")
    fi
  done
  (( ${#valid_snapshots[@]} > retain )) || return 0
  delete_count=$(( ${#valid_snapshots[@]} - retain ))
  for candidate in "${valid_snapshots[@]:0:delete_count}"; do
    rm -rf -- "$candidate"
  done
}

install -d -m 0700 -- "$destination"
destination=$(realpath -e -- "$destination")
if $prune_only; then
  prune_snapshots
  exit 0
fi

for command in sqlite3 pacman; do command -v "$command" >/dev/null || die "missing command: $command"; done
binary=/usr/bin/lmm-api
unit=/usr/lib/systemd/system/lmm-api.service
env_file=/etc/lmm-api/lmm-api.env
dropins=/etc/systemd/system/lmm-api.service.d
database=/var/lib/private/lmm-api/one-api.db
for path in "$binary" "$unit" "$env_file" "$database"; do [[ -f $path ]] || die "required file missing: $path"; done

package_version=$(pacman -Q lmm-api-git | awk '{print $2}')
safe_version=${package_version//[^A-Za-z0-9._-]/_}
snapshot="$destination/lmm-api-$(date -u +%Y%m%dT%H%M%SZ)-$safe_version"
[[ ! -e $snapshot ]] || die "snapshot already exists: $snapshot"
install -d -m 0700 -- "$snapshot"

copy_file() {
  local source=$1 target="$snapshot$1"
  install -d -m 0700 -- "$(dirname -- "$target")"
  cp -a -- "$source" "$target"
}

copy_file "$binary"
copy_file "$unit"
copy_file "$env_file"
if [[ -d $dropins ]]; then
  install -d -m 0700 -- "$snapshot/etc/systemd/system"
  cp -a -- "$dropins" "$snapshot/etc/systemd/system/lmm-api.service.d"
fi
install -d -m 0700 -- "$snapshot/var/lib/private/lmm-api"
sqlite3 -cmd '.timeout 30000' "$database" \
  ".backup '$snapshot/var/lib/private/lmm-api/one-api.db'"
[[ $(sqlite3 "$snapshot/var/lib/private/lmm-api/one-api.db" 'PRAGMA quick_check;') == ok ]] || die 'SQLite backup quick_check failed'

pacman -Qi lmm-api-git >"$snapshot/package-info.txt"
pacman -Ql lmm-api-git >"$snapshot/package-files.txt"
pacman -Qkk lmm-api-git >"$snapshot/package-integrity.txt" || true
find "$snapshot" -type f ! -name sha256sums.txt ! -name COMPLETE -print0 | \
  sort -z | xargs -0 sha256sum >"$snapshot/sha256sums.txt"
( cd -- "$snapshot" && sha256sum -c sha256sums.txt >/dev/null ) || die 'snapshot checksum validation failed'
printf 'version=%s\ncreated_at=%s\n' "$package_version" "$(date -u +%FT%TZ)" >"$snapshot/COMPLETE"

prune_snapshots

printf 'snapshot ready: %s\n' "$snapshot"
