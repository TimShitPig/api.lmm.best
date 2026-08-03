#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
backup_script="$script_dir/backup-server-state.sh"
for tool in bash shellcheck unshare sha256sum find; do
  command -v "$tool" >/dev/null || exit 1
done
bash -n "$backup_script"
shellcheck "$backup_script"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-backup-retention.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
for suffix in 20260101T000000Z 20260102T000000Z 20260103T000000Z 20260104T000000Z; do
  snapshot="$test_root/lmm-api-$suffix-r27"
  mkdir -p -- "$snapshot"
  printf '%s\n' "$suffix" >"$snapshot/payload"
  (
    cd -- "$snapshot"
    sha256sum payload >sha256sums.txt
  )
  printf '%s\n' complete >"$snapshot/COMPLETE"
done
unshare --user --map-root-user --mount --fork \
  bash "$backup_script" --destination "$test_root" --retain 3 --prune-only
[[ ! -e $test_root/lmm-api-20260101T000000Z-r27 ]]
[[ -d $test_root/lmm-api-20260102T000000Z-r27 ]]
[[ -d $test_root/lmm-api-20260103T000000Z-r27 ]]
[[ -d $test_root/lmm-api-20260104T000000Z-r27 ]]
[[ $(find "$test_root" -mindepth 1 -maxdepth 1 -type d -name 'lmm-api-*' | wc -l) == 3 ]]
printf '%s\n' 'backup script retention test passed'
