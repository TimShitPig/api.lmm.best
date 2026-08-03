#!/usr/bin/env bash
set -euo pipefail

readonly UPSTREAM_URL='https://github.com/QuantumNous/new-api.git'
readonly REMOTE_NAME='new-api-upstream'
UPSTREAM_REF=${1:-main}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

[[ "$SCRIPT_DIR" == "$REPO_DIR/go" ]] || {
  printf 'go/ is not at the repository root: %s\n' "$SCRIPT_DIR" >&2
  exit 1
}
if [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
  printf '%s\n' 'upstream sync requires a clean worktree' >&2
  exit 1
fi

if git -C "$REPO_DIR" remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
  configured_url=$(git -C "$REPO_DIR" remote get-url "$REMOTE_NAME")
  [[ "$configured_url" == "$UPSTREAM_URL" ]] || {
    printf 'remote %s points to %s, expected %s\n' \
      "$REMOTE_NAME" "$configured_url" "$UPSTREAM_URL" >&2
    exit 1
  }
else
  git -C "$REPO_DIR" remote add "$REMOTE_NAME" "$UPSTREAM_URL"
fi

git -C "$REPO_DIR" fetch "$REMOTE_NAME" "$UPSTREAM_REF"
git -C "$REPO_DIR" subtree pull --prefix=go "$REMOTE_NAME" "$UPSTREAM_REF" --squash

printf 'merged %s/%s into go/\n' "$REMOTE_NAME" "$UPSTREAM_REF"
printf '%s\n' 'resolve any conflicts, update FORK.md, then run go/verify-channel-pricing-hotfix.sh'
