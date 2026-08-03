#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
OUT_DIR="$SCRIPT_DIR/out"
WEB_DIST=''
SOURCE_REF='HEAD'

usage() {
  printf 'Usage: %s --web-dist /path/to/verified/web-dist [--source-ref REF]\n' "${0##*/}" >&2
}

while (($# > 0)); do
  case "$1" in
    --web-dist)
      (($# >= 2)) || { usage; exit 2; }
      WEB_DIST="$2"
      shift 2
      ;;
    --source-ref)
      (($# >= 2)) || { usage; exit 2; }
      SOURCE_REF="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -n "$WEB_DIST" ]] || { usage; exit 2; }
[[ -d "$WEB_DIST" ]] || { printf 'web dist is not a directory: %s\n' "$WEB_DIST" >&2; exit 1; }
git -C "$REPO_DIR" rev-parse --verify --quiet "${SOURCE_REF}^{commit}" >/dev/null || {
  printf 'source ref is not a commit: %s\n' "$SOURCE_REF" >&2
  exit 1
}
git -C "$REPO_DIR" cat-file -e "${SOURCE_REF}:go/go.mod" 2>/dev/null || {
  printf 'source ref does not contain go/go.mod: %s\n' "$SOURCE_REF" >&2
  exit 1
}

RELEASE_VERSION=$(sed -n "s/^pkgver=['\"]\{0,1\}\([^'\"]*\).*/\1/p" "$SCRIPT_DIR/packaging/PKGBUILD")
[[ -n "$RELEASE_VERSION" ]] || {
  printf '%s\n' 'could not read pkgver from packaging/PKGBUILD' >&2
  exit 1
}
SOURCE_REVISION=$(git -C "$REPO_DIR" rev-parse "${SOURCE_REF}^{commit}")
SOURCE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lmm-go-build.XXXXXX")"
OUTPUT_TMP=''
cleanup() {
  rm -rf -- "$SOURCE_DIR"
  if [[ -n "$OUTPUT_TMP" ]]; then
    rm -f -- "$OUTPUT_TMP"
  fi
}
trap cleanup EXIT

git -C "$REPO_DIR" archive "${SOURCE_REF}:go" | tar -x -C "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR/web/dist"
cp -a -- "$WEB_DIST/." "$SOURCE_DIR/web/dist/"

mkdir -p "$OUT_DIR"
OUTPUT_TMP="$(mktemp "$OUT_DIR/.lmm-api.XXXXXX")"
(
  cd "$SOURCE_DIR"
  GOPROXY=off CGO_ENABLED=0 go build -trimpath -buildvcs=false \
    -ldflags "-s -w -extldflags '-static' -X github.com/QuantumNous/new-api/common.Version=$RELEASE_VERSION" \
    -o "$OUTPUT_TMP" .
)
chmod 0755 "$OUTPUT_TMP"
version_output="$("$OUTPUT_TMP" --version)"
if [[ "$version_output" != "$RELEASE_VERSION" ]]; then
  printf 'version assertion failed: expected %s, got %s\n' "$RELEASE_VERSION" "$version_output" >&2
  exit 1
fi
file_output="$(file -Lb "$OUTPUT_TMP")"
if [[ "$file_output" != *'statically linked'* ]]; then
  printf 'static file assertion failed: %s\n' "$file_output" >&2
  exit 1
fi
ldd_output="$(ldd "$OUTPUT_TMP" 2>&1 || true)"
if [[ "$ldd_output" != *'not a dynamic executable'* && "$ldd_output" != *'statically linked'* ]]; then
  printf 'static ldd assertion failed: %s\n' "$ldd_output" >&2
  exit 1
fi
mv -f -- "$OUTPUT_TMP" "$OUT_DIR/lmm-api"
OUTPUT_TMP=''

printf 'built %s from %s (%s) version=%s\n' \
  "$OUT_DIR/lmm-api" "$SOURCE_REF" "$SOURCE_REVISION" "$RELEASE_VERSION"
sha256sum "$OUT_DIR/lmm-api"
