#!/usr/bin/env bash
# Start only disposable local dependencies, then replay the safe (non-mutating)
# half of missing-routes-matrix.tsv.  No listener or datastore outside the
# mktemp directory is read, written, or stopped.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
pg_port=${LMM_MISSING_ROUTES_PG_PORT:-55477}
rust_port=${LMM_MISSING_ROUTES_RUST_PORT:-33047}
oracle_port=${LMM_MISSING_ROUTES_GO_PORT:-13017}
valkey_port=6380 # Config intentionally permits this port only for test mode.
oracle_valkey_port=${LMM_MISSING_ROUTES_GO_VALKEY_PORT:-16397}
runtime_base=${LMM_MISSING_ROUTES_RUNTIME_BASE:-/home/lightjunction/.cache}
include_classes=${MISSING_ROUTES_INCLUDE_CLASSES:-no-side-effect,external-gateway}
[[ -d $runtime_base ]] || { echo "runtime base does not exist: $runtime_base" >&2; exit 1; }
runtime=$(mktemp -d "$runtime_base/lmm-missing-routes-listeners.XXXXXX")
cargo_target="$runtime/cargo-target"
rust_binary=${LMM_MISSING_ROUTES_RUST_BINARY:-"$repo_root/rust/target/debug/lmm-api-rs"}
schema=lmm_test_missing_routes
role=lmm_test_missing_routes
database=lmm_test_missing_routes

cleanup() {
  for pid in ${go_pid:-} ${go_valkey_pid:-} ${rust_pid:-} ${valkey_pid:-}; do kill "$pid" 2>/dev/null || true; done
  wait ${go_pid:-} ${go_valkey_pid:-} ${rust_pid:-} ${valkey_pid:-} 2>/dev/null || true
  [[ -d $runtime/pg ]] && pg_ctl -D "$runtime/pg" -m fast -w stop >/dev/null 2>&1 || true
  case "$runtime" in
    "$runtime_base"/lmm-missing-routes-listeners.*) rm -rf "$runtime" ;;
    *) echo "refusing to remove unexpected runtime: $runtime" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM

for command in cargo createdb createuser curl go initdb jq pg_ctl postgres psql valkey-cli valkey-server; do
  command -v "$command" >/dev/null || { echo "required command unavailable: $command" >&2; exit 1; }
done
[[ $(postgres --version) == *"PostgreSQL) 18."* ]] || { echo "requires PostgreSQL 18" >&2; exit 1; }
for port in "$pg_port" "$rust_port" "$oracle_port" "$valkey_port" "$oracle_valkey_port"; do
  if ss -ltn "sport = :$port" | grep -q LISTEN; then
    echo "refusing to reuse occupied local port: $port" >&2
    exit 1
  fi
done

if [[ ${LMM_MISSING_ROUTES_SKIP_RUST_BUILD:-0} == 1 ]]; then
  [[ -x $rust_binary ]] || { echo "Rust listener binary unavailable: $rust_binary" >&2; exit 1; }
else
  TMPDIR="$runtime" CARGO_TARGET_DIR="$cargo_target" \
    cargo build --manifest-path "$repo_root/rust/Cargo.toml" -p lmm-api-rs --locked
  rust_binary="$cargo_target/debug/lmm-api-rs"
fi

initdb --no-locale --encoding=UTF8 --auth=trust -D "$runtime/pg" >/dev/null
pg_ctl -D "$runtime/pg" -l "$runtime/postgres.log" \
  -o "-h 127.0.0.1 -p $pg_port -k $runtime" -w start >/dev/null
createuser -h 127.0.0.1 -p "$pg_port" "$role"
createdb -h 127.0.0.1 -p "$pg_port" -O "$role" "$database"

# The baseline is installed into a fresh schema owned by the disposable role.
# This makes every SQL reference resolve through the exact test namespace that
# Config validates when LMM_RS_TEST_INSTANCE=1.
sed "s/public\./$schema./g" "$repo_root/rust/crates/lmm-db-migrate/schema/postgresql-baseline.sql" > "$runtime/baseline.sql"
psql -h 127.0.0.1 -p "$pg_port" -U "$role" -d "$database" -v ON_ERROR_STOP=1 <<SQL >/dev/null
CREATE SCHEMA $schema AUTHORIZATION $role;
SET search_path TO $schema;
\i $runtime/baseline.sql
CREATE TABLE lmm_schema_contract (singleton BOOLEAN PRIMARY KEY, min_reader_version BIGINT NOT NULL, max_reader_version BIGINT NOT NULL);
INSERT INTO lmm_schema_contract VALUES (TRUE, 1, 1);
SQL

valkey-server --bind 127.0.0.1 --port "$valkey_port" --save '' --appendonly no \
  --dir "$runtime" --logfile "$runtime/valkey.log" > /dev/null 2>&1 &
valkey_pid=$!
for _ in {1..100}; do valkey-cli -h 127.0.0.1 -p "$valkey_port" ping >/dev/null 2>&1 && break; sleep .05; done
valkey-cli -h 127.0.0.1 -p "$valkey_port" ping >/dev/null

# The frozen Go oracle is built from a copy under the same home-backed
# runtime.  The root filesystem may intentionally be too small for PostgreSQL
# or a Go build; using /tmp here would make that host constraint look like a
# route failure.
legacy_root="$repo_root/go"
[[ -d $legacy_root ]] || { echo "missing frozen Go oracle source: $legacy_root" >&2; exit 1; }
cp -a "$legacy_root/." "$runtime/go-source"
mkdir -p "$runtime/go-source/web/dist"
: > "$runtime/go-source/web/dist/index.html"
(
  cd "$runtime/go-source"
  GOTOOLCHAIN=local CGO_ENABLED=1 go build -buildvcs=false -o "$runtime/legacy-go" .
)
valkey-server --bind 127.0.0.1 --port "$oracle_valkey_port" --save '' --appendonly no \
  --dir "$runtime" --logfile "$runtime/go-valkey.log" > /dev/null 2>&1 &
go_valkey_pid=$!
for _ in {1..100}; do valkey-cli -h 127.0.0.1 -p "$oracle_valkey_port" ping >/dev/null 2>&1 && break; sleep .05; done
valkey-cli -h 127.0.0.1 -p "$oracle_valkey_port" ping >/dev/null
env \
  SQLITE_PATH="$runtime/oracle.db" \
  PORT="$oracle_port" \
  REDIS_CONN_STRING="redis://127.0.0.1:$oracle_valkey_port" \
  SESSION_SECRET='MissingRoutes-2026!SyntheticOnly' \
  GLOBAL_API_RATE_LIMIT_ENABLE=false \
  TRUSTED_PROXIES=none \
  GIN_MODE=release \
  "$runtime/legacy-go" >"$runtime/go.log" 2>&1 &
go_pid=$!
for _ in {1..300}; do
  [[ $(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$oracle_port/api/status" || true) == 200 ]] && break
  sleep .05
done
if [[ $(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$oracle_port/api/status" || true) != 200 ]]; then
  echo "Go oracle did not become ready; log follows" >&2
  sed -n '1,240p' "$runtime/go.log" >&2
  exit 1
fi

database_url="postgresql://$role@127.0.0.1:$pg_port/$database?options=-csearch_path=$schema"
env \
  LMM_RS_TEST_INSTANCE=1 \
  LMM_RS_SLOT=blue \
  LMM_RS_LISTEN_ADDR="127.0.0.1:$rust_port" \
  DATABASE_URL="$database_url" \
  VALKEY_URL="redis://127.0.0.1:$valkey_port" \
  LMM_SCHEMA_CONTRACT=1 \
  SESSION_SECRET='MissingRoutes-2026!SyntheticOnly' \
  CRYPTO_SECRET='MissingRoutesCrypto-2026!SyntheticOnly' \
  GLOBAL_API_RATE_LIMIT_ENABLE=false \
  PASSWORD_LOGIN_ENABLED=false \
  TRUSTED_PROXIES=none \
  VERSION=v0.0.0 \
  "$rust_binary" >"$runtime/rust.log" 2>&1 &
rust_pid=$!
for _ in {1..300}; do
  [[ $(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$rust_port/readyz" || true) == 200 ]] && break
  sleep .05
done
if [[ $(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$rust_port/readyz" || true) != 200 ]]; then
  echo "Rust test-instance did not become ready; log follows" >&2
  sed -n '1,240p' "$runtime/rust.log" >&2
  exit 1
fi

GO_BASE_URL="http://127.0.0.1:$oracle_port" RUST_BASE_URL="http://127.0.0.1:$rust_port" \
  MISSING_ROUTES_MODE=transport \
  MISSING_ROUTES_INCLUDE_CLASSES="$include_classes" \
  "$repo_root/rust/behavior-oracle/tests/missing-routes-listener-differential.sh"
