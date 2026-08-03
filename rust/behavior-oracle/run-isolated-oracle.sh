#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
legacy="$repo_root/go"
runtime=$(mktemp -d /tmp/lmm-legacy-oracle.XXXXXX)
oracle_port=${ORACLE_PORT:-13001}
valkey_port=${ORACLE_VALKEY_PORT:-16379}

for command in curl go valkey-cli valkey-server; do
  command -v "$command" >/dev/null || { echo "required command is unavailable: $command" >&2; exit 1; }
done

cleanup() {
  [[ -n ${oracle_pid:-} ]] && kill "$oracle_pid" 2>/dev/null || true
  [[ -n ${valkey_pid:-} ]] && kill "$valkey_pid" 2>/dev/null || true
  wait "${oracle_pid:-}" "${valkey_pid:-}" 2>/dev/null || true
  case "$runtime" in
    /tmp/lmm-legacy-oracle.*) rm -rf "$runtime" ;;
    *) echo "refusing to remove unexpected oracle directory: $runtime" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM

cp -a "$legacy/." "$runtime/source"
mkdir -p "$runtime/source/web/dist"
: >"$runtime/source/web/dist/index.html"
(
  cd "$runtime/source"
  env GOTOOLCHAIN=local CGO_ENABLED=1 go build -o "$runtime/legacy-oracle" .
)

valkey-server \
  --bind 127.0.0.1 \
  --port "$valkey_port" \
  --save '' \
  --appendonly no \
  --dir "$runtime" \
  --dbfilename oracle.rdb \
  >"$runtime/valkey.log" 2>&1 &
valkey_pid=$!

for _ in {1..100}; do
  valkey-cli -h 127.0.0.1 -p "$valkey_port" ping >/dev/null 2>&1 && break
  sleep 0.05
done
valkey-cli -h 127.0.0.1 -p "$valkey_port" ping >/dev/null

env \
  SQLITE_PATH="$runtime/oracle.db" \
  PORT="$oracle_port" \
  REDIS_CONN_STRING="redis://127.0.0.1:$valkey_port" \
  SESSION_SECRET=oracle-only-fixed-synthetic-secret-never-production \
  GLOBAL_API_RATE_LIMIT_ENABLE=false \
  TRUSTED_PROXIES=none \
  GIN_MODE=release \
  "$runtime/legacy-oracle" >"$runtime/oracle.log" 2>&1 &
oracle_pid=$!

for _ in {1..200}; do
  curl --silent --fail "http://localhost:$oracle_port/api/status" >/dev/null 2>&1 && break
  sleep 0.05
done
curl --silent --fail "http://localhost:$oracle_port/api/status" >/dev/null

export GO_BASE_URL="http://127.0.0.1:$oracle_port"
export ORACLE_SQLITE_PATH="$runtime/oracle.db"
export ORACLE_REDIS_URL="redis://127.0.0.1:$valkey_port"
export ORACLE_RUNTIME_DIR="$runtime"
oracle_marker="$runtime/.isolated-loopback-marker"
: >"$oracle_marker"
export ORACLE_ISOLATED_LOOPBACK_MARKER="$oracle_marker"

if (($# == 0)); then
  echo "GO_BASE_URL=$GO_BASE_URL"
  echo "ORACLE_SQLITE_PATH=$ORACLE_SQLITE_PATH"
  echo "ORACLE_REDIS_URL=$ORACLE_REDIS_URL"
  wait "$oracle_pid"
else
  # The API-token capture must reject a non-loopback URL before curl is ever
  # reached.  Keep this negative assertion in the wrapper that owns the marker.
  if GO_BASE_URL='http://example.invalid:80' CAPTURE_LIVE_VALIDATE_ONLY=1 \
    "$repo_root/rust/behavior-oracle/captures/api-token/capture-live.sh" >/dev/null 2>&1; then
    echo "API-token capture accepted an external listener URL" >&2
    exit 1
  fi
  "$@"
fi
