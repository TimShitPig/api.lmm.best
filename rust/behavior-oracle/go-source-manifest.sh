#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
go_root="$repo_root/go"

[[ -f "$go_root/go.mod" && -f "$go_root/main.go" ]] || {
  echo "maintained Go source is missing: $go_root" >&2
  exit 1
}

find "$go_root" \
  \( -path "$go_root/.agents" -o -path "$go_root/.github" -o \
     -path "$go_root/.legacy-archive" -o -path "$go_root/docs" -o \
     -path "$go_root/electron" -o -path "$go_root/out" -o \
     -path "$go_root/packaging" -o -path "$go_root/web" \) -prune -o \
  -type f -print0 |
  LC_ALL=C sort -z |
  while IFS= read -r -d '' path; do
    relative=${path#"$go_root/"}
    sha256sum "$path" | sed "s#  $path\$#  $relative#"
  done
