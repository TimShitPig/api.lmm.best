#!/usr/bin/env bash
# Fail-closed TCP probe for the frozen Go relay-misc surface and the Rust
# candidate seam. Everything runs on loopback with disposable PostgreSQL 18,
# Valkey, listeners, and provider fixture processes. It deliberately exits
# non-zero while the candidate owns no TokenAuth/distribution/accounting
# executor: a 503 is evidence of a safe boundary, not parity approval.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
legacy_root="$repo_root/go"
runtime_base=${LMM_RELAY_MISC_RUNTIME_BASE:-/tmp}
pg_port=${LMM_RELAY_MISC_PG_PORT:-55483}
go_port=${LMM_RELAY_MISC_GO_PORT:-13053}
rust_port=${LMM_RELAY_MISC_RUST_PORT:-33083}
go_valkey_port=${LMM_RELAY_MISC_GO_VALKEY_PORT:-16433}
rust_valkey_port=${LMM_RELAY_MISC_RUST_VALKEY_PORT:-6380}
provider_port=${LMM_RELAY_MISC_PROVIDER_PORT:-38083}
runtime=$(mktemp -d "$runtime_base/lmm-relay-misc-differential.XXXXXX")
rust_schema=lmm_test_relay_misc
rust_role=lmm_test_relay_misc
rust_database=lmm_test_relay_misc
go_valkey_password=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
rust_valkey_password=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
go_session_secret=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
go_crypto_secret=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
rust_session_secret=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
rust_crypto_secret=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
fixture_bearer='sk-relaymiscfixture'

# shellcheck disable=SC2329 # invoked through the process-exit trap below
cleanup() {
  for pid in "${go_pid:-}" "${rust_pid:-}" "${go_valkey_pid:-}" "${rust_valkey_pid:-}" "${provider_pid:-}"; do
    [[ -z $pid ]] || kill "$pid" 2>/dev/null || true
  done
  for pid in "${go_pid:-}" "${rust_pid:-}" "${go_valkey_pid:-}" "${rust_valkey_pid:-}" "${provider_pid:-}"; do
    [[ -z $pid ]] || wait "$pid" 2>/dev/null || true
  done
  [[ ! -d $runtime/pg ]] || pg_ctl -D "$runtime/pg" -m fast -w stop >/dev/null 2>&1 || true
  case "$runtime" in
    "$runtime_base"/lmm-relay-misc-differential.*) rm -rf "$runtime" ;;
    *) echo "refusing unexpected runtime removal: $runtime" >&2 ;;
  esac
}
trap cleanup EXIT INT TERM
trap 'echo "relay-misc differential failed at line $LINENO" >&2' ERR

for command in cargo createdb createuser curl git go initdb jq pg_ctl postgres psql python3 valkey-cli valkey-server; do
  command -v "$command" >/dev/null || { echo "required command unavailable: $command" >&2; exit 127; }
done
[[ $(postgres --version) == *"PostgreSQL) 18."* ]] || { echo "requires PostgreSQL 18" >&2; exit 1; }
[[ -d $legacy_root ]] || { echo "missing frozen Go source: $legacy_root" >&2; exit 1; }
[[ -d $runtime_base && -w $runtime_base ]] || { echo "runtime base is not writable: $runtime_base" >&2; exit 1; }

preflight_port() {
  local name=$1 port=$2
  if (exec 3<>"/dev/tcp/127.0.0.1/$port"; exec 3>&-) 2>/dev/null; then
    echo "refusing occupied $name port: 127.0.0.1:$port" >&2
    exit 1
  fi
}
for entry in \
  "postgres:$pg_port" "go:$go_port" "rust:$rust_port" \
  "go-valkey:$go_valkey_port" "rust-valkey:$rust_valkey_port" "provider:$provider_port"; do
  preflight_port "${entry%%:*}" "${entry##*:}"
done

wait_for_pid_http() {
  local pid=$1 port=$2 path=$3
  for _ in {1..300}; do
    kill -0 "$pid" 2>/dev/null || return 1
    [[ $(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$port$path" || true) =~ ^(200|204)$ ]] && return 0
    sleep .05
  done
  return 1
}

start_valkey() {
  local name=$1 port=$2 password=$3 pid_var=$4
  local config="$runtime/$name-valkey.conf"
  umask 077
  printf '%s\n' \
    'bind 127.0.0.1' \
    "port $port" \
    'save ""' \
    'appendonly no' \
    'protected-mode yes' \
    "requirepass $password" \
    "dir $runtime" \
    "logfile $runtime/$name-valkey.log" > "$config"
  chmod 600 "$config"
  env -i PATH="$PATH" valkey-server "$config" &
  local pid=$!
  printf -v "$pid_var" '%s' "$pid"
  for _ in {1..200}; do
    kill -0 "$pid" 2>/dev/null || return 1
    VALKEYCLI_AUTH="$password" valkey-cli --no-auth-warning -h 127.0.0.1 -p "$port" ping >/dev/null 2>&1 && return 0
    sleep .05
  done
  return 1
}

start_loopback_provider() {
  : > "$runtime/provider-hits.log"
  python3 -u - "$provider_port" "$runtime/provider-hits.log" <<'PY' &
import http.server
import sys

port = int(sys.argv[1])
hits = sys.argv[2]

class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"fixture":"healthy"}')

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length)
        with open(hits, "a", encoding="utf-8") as output:
            output.write(
                f"{self.path}\t{self.headers.get('authorization', '')}\t"
                f"{self.headers.get('accept-encoding', '')}\t{len(body)}\n"
            )
        if self.headers.get("authorization") != "Bearer provider-owned-secret":
            self.send_response(400)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"credential-boundary"}')
            return
        if self.headers.get("x-fixture-mode") == "sse":
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("cache-control", "no-cache")
            self.end_headers()
            self.wfile.write(b'data: {"fixture":true}\n\ndata: [DONE]\n\n')
            self.wfile.flush()
            return
        if self.headers.get("x-fixture-mode") == "error":
            self.send_response(429)
            self.send_header("content-type", "application/json")
            self.send_header("retry-after", "7")
            self.end_headers()
            self.wfile.write(b'{"error":"fixture-rate-limit"}')
            return
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"fixture":"loopback"}')

http.server.ThreadingHTTPServer(("127.0.0.1", port), Fixture).serve_forever()
PY
  provider_pid=$!
  wait_for_pid_http "$provider_pid" "$provider_port" /health || {
    sed -n '1,160p' "$runtime/provider-hits.log" 2>/dev/null || true
    return 1
  }
}

start_loopback_provider
start_valkey go "$go_valkey_port" "$go_valkey_password" go_valkey_pid
start_valkey rust "$rust_valkey_port" "$rust_valkey_password" rust_valkey_pid

initdb --no-locale --encoding=UTF8 --auth=trust -D "$runtime/pg" >/dev/null
pg_ctl -D "$runtime/pg" -l "$runtime/postgres.log" \
  -o "-h 127.0.0.1 -p $pg_port -k $runtime" -w start >/dev/null
createuser -h 127.0.0.1 -p "$pg_port" "$rust_role"
createdb -h 127.0.0.1 -p "$pg_port" -O "$rust_role" "$rust_database"
sed "s/public\\./$rust_schema./g" "$repo_root/rust/crates/lmm-db-migrate/schema/postgresql-baseline.sql" > "$runtime/baseline.sql"
psql -h 127.0.0.1 -p "$pg_port" -U "$rust_role" -d "$rust_database" -v ON_ERROR_STOP=1 <<SQL >/dev/null
CREATE SCHEMA $rust_schema AUTHORIZATION $rust_role;
SET search_path TO $rust_schema;
\i $runtime/baseline.sql
CREATE TABLE lmm_schema_contract (singleton BOOLEAN PRIMARY KEY, min_reader_version BIGINT NOT NULL, max_reader_version BIGINT NOT NULL);
INSERT INTO lmm_schema_contract VALUES (TRUE, 1, 1);
SQL

mkdir -p "$runtime/go-source/web/dist"
cp -a "$legacy_root/." "$runtime/go-source/"
: > "$runtime/go-source/web/dist/index.html"
(
  cd "$runtime/go-source"
  env -i PATH="$PATH" HOME="$HOME" GOTOOLCHAIN=local CGO_ENABLED=1 \
    go build -buildvcs=false -o "$runtime/legacy-go" .
)
env -i PATH="$PATH" HOME="$HOME" CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}" \
  RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" CARGO_TARGET_DIR="$runtime/cargo-target" \
  cargo build --manifest-path "$repo_root/rust/Cargo.toml" -p lmm-api-rs --locked

# This ignored module test is the only candidate with an injected distributor,
# provider credential, and accounting seam. It must actually reach the
# loopback fixture; a listener-only 503 check is not called a differential.
env -i PATH="$PATH" HOME="$HOME" CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}" \
  RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" CARGO_TARGET_DIR="$runtime/cargo-target" \
  LMM_RELAY_MISC_PROVIDER_URL="http://127.0.0.1:$provider_port" \
  cargo test --manifest-path "$repo_root/rust/Cargo.toml" -p lmm-api-rs --lib --locked \
    migration_routes::relay_misc::tests::loopback_provider_contract -- --ignored --exact

env -i PATH="$PATH" HOME="$HOME" SQL_DSN=local SQLITE_PATH="$runtime/go.db" PORT="$go_port" \
  REDIS_CONN_STRING="redis://:$go_valkey_password@127.0.0.1:$go_valkey_port" \
  SESSION_SECRET="$go_session_secret" CRYPTO_SECRET="$go_crypto_secret" \
  GLOBAL_API_RATE_LIMIT_ENABLE=false CRITICAL_RATE_LIMIT_ENABLE=false \
  MODEL_REQUEST_RATE_LIMIT_ENABLE=false TRUSTED_PROXIES=none GIN_MODE=release \
  "$runtime/legacy-go" >"$runtime/go.log" 2>&1 &
go_pid=$!
wait_for_pid_http "$go_pid" "$go_port" /api/status || { sed -n '1,240p' "$runtime/go.log" >&2; exit 1; }

rust_dsn="postgresql://$rust_role@127.0.0.1:$pg_port/$rust_database?options=-csearch_path=$rust_schema"
env -i PATH="$PATH" HOME="$HOME" LMM_RS_TEST_INSTANCE=1 LMM_RS_SLOT=blue \
  LMM_RS_LISTEN_ADDR="127.0.0.1:$rust_port" DATABASE_URL="$rust_dsn" \
  VALKEY_URL="redis://:$rust_valkey_password@127.0.0.1:$rust_valkey_port" LMM_SCHEMA_CONTRACT=1 \
  SESSION_SECRET="$rust_session_secret" CRYPTO_SECRET="$rust_crypto_secret" \
  GLOBAL_API_RATE_LIMIT_ENABLE=false CRITICAL_RATE_LIMIT_ENABLE=false \
  PASSWORD_LOGIN_ENABLED=false TRUSTED_PROXIES=none VERSION=v0.0.0 \
  "$runtime/cargo-target/debug/lmm-api-rs" >"$runtime/rust.log" 2>&1 &
rust_pid=$!
wait_for_pid_http "$rust_pid" "$rust_port" /readyz || { sed -n '1,240p' "$runtime/rust.log" >&2; exit 1; }

call() {
  local engine=$1 name=$2 method=$3 path=$4 bearer=$5 body=${6:-}
  local port=$go_port
  [[ $engine == rust ]] && port=$rust_port
  local prefix="$runtime/$engine-$name"
  local args=(--silent --show-error --dump-header "$prefix.headers" --output "$prefix.body" --write-out '%{http_code}' --request "$method")
  [[ -z $bearer ]] || args+=(--header "authorization: Bearer $bearer")
  [[ -z $body ]] || args+=(--header 'content-type: application/json' --data-binary "$body")
  curl "${args[@]}" "http://127.0.0.1:$port$path" > "$prefix.status"
}

assert_status() {
  local engine=$1 name=$2 expected=$3 actual
  actual=$(<"$runtime/$engine-$name.status")
  [[ $actual == "$expected" ]] || { echo "$engine $name expected $expected, got $actual" >&2; return 1; }
}

fixture_hits_before=$(wc -l < "$runtime/provider-hits.log")
curl --silent --show-error --no-buffer --request POST "http://127.0.0.1:$provider_port/sse" > "$runtime/provider.sse"
grep -Fx 'data: {"fixture":true}' "$runtime/provider.sse" >/dev/null
grep -Fx 'data: [DONE]' "$runtime/provider.sse" >/dev/null

routes=(
  'POST|/v1/alpha/search|{"model":"gpt-test","query":"hello"}'
  'POST|/v1/embeddings|{"model":"text-embedding-3-small","input":"hello"}'
  'POST|/v1/engines/text-embedding-004/embeddings|{"model":"text-embedding-004","input":"hello"}'
  'POST|/v1/rerank|{"model":"rerank-v3","query":"hello","documents":["hello"]}'
  'POST|/v1/moderations|{"model":"text-moderation-stable","input":"hello"}'
  'POST|/v1/images/variations|{}'
  'GET|/v1/files|'
  'POST|/v1/files|{}'
  'DELETE|/v1/files/file-1|'
  'GET|/v1/files/file-1|'
  'GET|/v1/files/file-1/content|'
  'GET|/v1/fine-tunes|'
  'POST|/v1/fine-tunes|{}'
  'GET|/v1/fine-tunes/ft-1|'
  'POST|/v1/fine-tunes/ft-1/cancel|{}'
  'GET|/v1/fine-tunes/ft-1/events|'
)

for route in "${routes[@]}"; do
  IFS='|' read -r method path body <<< "$route"
  name=$(printf '%s-%s' "$method" "$path" | tr '/:{}' '-----')
  call go "$name-anonymous" "$method" "$path" '' "$body"
  call rust "$name-anonymous" "$method" "$path" '' "$body"
  assert_status go "$name-anonymous" 401
  assert_status rust "$name-anonymous" 401
done

for route in "${routes[@]:0:5}"; do
  IFS='|' read -r method path body <<< "$route"
  name=$(printf '%s-%s' "$method" "$path" | tr '/:{}' '-----')
  call rust "$name-fixture" "$method" "$path" "$fixture_bearer" "$body"
  assert_status rust "$name-fixture" 503
done

for route in "${routes[@]:5}"; do
  IFS='|' read -r method path body <<< "$route"
  name=$(printf '%s-%s' "$method" "$path" | tr '/:{}' '-----')
  call rust "$name-fixture" "$method" "$path" "$fixture_bearer" "$body"
  assert_status rust "$name-fixture" 501
  jq -e '.error.message == "API not implemented" and .error.type == "new_api_error" and .error.code == "api_not_implemented"' \
    < "$runtime/rust-$name-fixture.body" >/dev/null
done

fixture_hits_after=$(wc -l < "$runtime/provider-hits.log")
(( fixture_hits_after == fixture_hits_before + 1 )) || {
  echo "candidate contacted the provider fixture despite fail-closed relay state" >&2
  exit 1
}

jq -cn \
  --arg result blocked \
  --arg reason 'Rust relay-misc has no production TokenAuth/distribution/provider/accounting executor' \
  --arg provider "http://127.0.0.1:$provider_port" \
  --argjson frozen_501_routes 11 \
  --argjson real_relay_routes 5 \
  '{test:"relay-misc-differential",result:$result,reason:$reason,provider_fixture:$provider,provider_loopback_only:true,frozen_501_routes:$frozen_501_routes,real_relay_routes:$real_relay_routes,unauthenticated_order_checked:true,candidate_real_routes_fail_closed_503:true,candidate_frozen_routes_501_checked:true}'
echo 'relay-misc remains unapproved; a production executor and an independent Go/Rust valid-token/channel/accounting differential are required.' >&2
exit 1
