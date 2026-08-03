#!/usr/bin/env bash
# Self-contained, real-TCP API-token differential.  Everything below is local:
# a frozen Go binary, the candidate Rust binary, PostgreSQL 18, and two Valkey
# instances.  It deliberately does not accept listener URLs or credentials.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
legacy_root="$repo_root/go"
pg_port=${LMM_API_TOKEN_TCP_PG_PORT:-55437}
go_port=${LMM_API_TOKEN_TCP_GO_PORT:-13004}
rust_port=${LMM_API_TOKEN_TCP_RUST_PORT:-33034}
go_valkey_port=${LMM_API_TOKEN_TCP_GO_VALKEY_PORT:-16383}
rust_valkey_port=${LMM_API_TOKEN_TCP_RUST_VALKEY_PORT:-56383}
tmp_root=${TMPDIR:-/dev/shm}
[[ -d $tmp_root && -w $tmp_root ]] || { echo "temporary directory is not writable: $tmp_root" >&2; exit 1; }
runtime=$(mktemp -d "$tmp_root/lmm-api-token-listener.XXXXXX")
rust_binary=${LMM_API_TOKEN_RUST_BINARY:-"$repo_root/rust/target/debug/lmm-api-rs"}

cleanup() {
  for pid in ${go_pid:-} ${rust_pid:-}; do kill "$pid" 2>/dev/null || true; done
  wait ${go_pid:-} ${rust_pid:-} 2>/dev/null || true
  for port in "$go_valkey_port" "$rust_valkey_port"; do valkey-cli -h 127.0.0.1 -p "$port" shutdown nosave >/dev/null 2>&1 || true; done
  [[ -d $runtime/pg ]] && pg_ctl -D "$runtime/pg" -m fast -w stop >/dev/null 2>&1 || true
  case "$runtime" in "$tmp_root"/lmm-api-token-listener.*) rm -rf "$runtime";; *) echo "refusing unexpected runtime: $runtime" >&2;; esac
}
trap cleanup EXIT INT TERM
trap 'echo "API-token listener differential failed at line $LINENO" >&2' ERR

for command in cargo curl createdb git go initdb jq pg_ctl postgres psql valkey-cli valkey-server; do
  command -v "$command" >/dev/null || { echo "required command unavailable: $command" >&2; exit 1; }
done
[[ $(postgres --version) == *"PostgreSQL) 18."* ]] || { echo "requires PostgreSQL 18" >&2; exit 1; }

if [[ ${LMM_API_TOKEN_SKIP_RUST_BUILD:-0} != 1 ]]; then
  cargo build --manifest-path "$repo_root/rust/Cargo.toml" -p lmm-api-rs --locked
fi
[[ -x $rust_binary ]] || { echo "Rust API-token listener binary unavailable: $rust_binary" >&2; exit 1; }
cp -a "$legacy_root/." "$runtime/go-source"
mkdir -p "$runtime/go-source/web/dist"; : >"$runtime/go-source/web/dist/index.html"
( cd "$runtime/go-source"; GOTOOLCHAIN=local CGO_ENABLED=1 GOCACHE="$runtime/go-cache" go build -buildvcs=false -o "$runtime/legacy-go" . )
initdb --no-locale --encoding=UTF8 --auth=trust -D "$runtime/pg" >/dev/null
if ! pg_ctl -D "$runtime/pg" -l "$runtime/postgres.log" -o "-h 127.0.0.1 -p $pg_port -k $runtime" -w start >/dev/null; then
  echo "PostgreSQL failed to start; captured log follows:" >&2
  sed -n '1,160p' "$runtime/postgres.log" >&2
  exit 1
fi
createdb -h 127.0.0.1 -p "$pg_port" token_go
createdb -h 127.0.0.1 -p "$pg_port" token_rust
for pair in "go:$go_valkey_port" "rust:$rust_valkey_port"; do
  name=${pair%%:*}; port=${pair##*:}
  valkey-server --bind 127.0.0.1 --port "$port" --save '' --appendonly no --daemonize yes --dir "$runtime" --logfile "$runtime/$name-valkey.log"
  for _ in {1..100}; do valkey-cli -h 127.0.0.1 -p "$port" ping >/dev/null 2>&1 && break; sleep .05; done
  valkey-cli -h 127.0.0.1 -p "$port" ping >/dev/null
done

# Frozen Go migrates its own disposable PostgreSQL database.  Rust receives
# the exact columns used by dashboard auth and API-token routes.
SQL_DSN="postgresql://127.0.0.1:$pg_port/token_go?sslmode=disable" PORT="$go_port" \
  REDIS_CONN_STRING="redis://127.0.0.1:$go_valkey_port" SESSION_SECRET='TokenListener-2026!Synthetic' \
  PASSWORD_LOGIN_ENABLED=true GLOBAL_API_RATE_LIMIT_ENABLE=false CRITICAL_RATE_LIMIT_ENABLE=false GIN_MODE=release \
  "$runtime/legacy-go" >"$runtime/go.log" 2>&1 & go_pid=$!
for _ in {1..300}; do curl -fsS "http://127.0.0.1:$go_port/api/status" >/dev/null 2>&1 && break; sleep .05; done
if ! curl -fsS "http://127.0.0.1:$go_port/api/status" >/dev/null; then
  echo "Legacy Go listener failed to become ready; captured log follows:" >&2
  sed -n '1,200p' "$runtime/go.log" >&2
  exit 1
fi

psql -h 127.0.0.1 -p "$pg_port" -d token_rust -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
CREATE ROLE lmm_token_runtime LOGIN;
CREATE TABLE lmm_schema_contract (singleton BOOLEAN PRIMARY KEY, min_reader_version BIGINT NOT NULL, max_reader_version BIGINT NOT NULL);
INSERT INTO lmm_schema_contract VALUES (TRUE,1,1);
CREATE TABLE options (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE custom_oauth_providers (id BIGINT PRIMARY KEY, name TEXT NOT NULL, slug TEXT NOT NULL, icon TEXT, enabled BOOLEAN, client_id TEXT, authorization_endpoint TEXT, scopes TEXT);
CREATE TABLE setups (id BIGINT PRIMARY KEY);
CREATE TABLE users (id BIGINT PRIMARY KEY, username TEXT UNIQUE, password TEXT NOT NULL, display_name TEXT, role BIGINT DEFAULT 1, status BIGINT DEFAULT 1, email TEXT, github_id TEXT, discord_id TEXT, oidc_id TEXT, wechat_id TEXT, telegram_id TEXT, access_token TEXT, quota BIGINT DEFAULT 0, used_quota BIGINT DEFAULT 0, request_count BIGINT DEFAULT 0, "group" TEXT DEFAULT 'default', aff_code TEXT, aff_count BIGINT DEFAULT 0, aff_quota BIGINT DEFAULT 0, aff_history BIGINT DEFAULT 0, inviter_id BIGINT, deleted_at TIMESTAMPTZ, linux_do_id TEXT, setting TEXT DEFAULT '{}', stripe_customer TEXT, last_login_at BIGINT DEFAULT 0, auth_version BIGINT NOT NULL DEFAULT 1);
CREATE TABLE user_sessions (sid TEXT PRIMARY KEY, user_id BIGINT NOT NULL, version BIGINT NOT NULL, user_auth_version BIGINT NOT NULL, status TEXT NOT NULL, refresh_hash CHAR(64) NOT NULL, previous_refresh_hash TEXT, previous_valid_until BIGINT NOT NULL DEFAULT 0, login_method TEXT NOT NULL, ip TEXT, user_agent TEXT, created_at BIGINT NOT NULL, last_active_at BIGINT NOT NULL, expires_at BIGINT NOT NULL, revoked_at BIGINT NOT NULL DEFAULT 0, revoked_reason TEXT);
CREATE TABLE two_fas (id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, user_id BIGINT NOT NULL, secret TEXT NOT NULL, is_enabled BOOLEAN NOT NULL DEFAULT FALSE, failed_attempts BIGINT DEFAULT 0, locked_until TIMESTAMPTZ, last_used_at TIMESTAMPTZ, created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ, deleted_at TIMESTAMPTZ);
CREATE TABLE casbin_rule (id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ptype TEXT, v0 TEXT, v1 TEXT, v2 TEXT, v3 TEXT, v4 TEXT, v5 TEXT);
CREATE TABLE auth_flows (id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, token_hash CHAR(64) NOT NULL UNIQUE, purpose TEXT NOT NULL, provider TEXT, intent TEXT, user_id BIGINT, session_id TEXT, payload TEXT, created_at TIMESTAMPTZ, expires_at TIMESTAMPTZ NOT NULL, consumed_at TIMESTAMPTZ);
CREATE TABLE two_fa_backup_codes (id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, user_id BIGINT NOT NULL, code_hash TEXT NOT NULL, is_used BOOLEAN DEFAULT FALSE, used_at TIMESTAMPTZ, created_at TIMESTAMPTZ, deleted_at TIMESTAMPTZ);
CREATE SEQUENCE tokens_id_seq;
CREATE TABLE tokens (id BIGINT PRIMARY KEY DEFAULT nextval('tokens_id_seq'), user_id BIGINT NOT NULL, key VARCHAR(128) UNIQUE, status INTEGER DEFAULT 1, name TEXT DEFAULT '', created_time BIGINT DEFAULT 0, accessed_time BIGINT DEFAULT 0, expired_time BIGINT DEFAULT -1, remain_quota BIGINT DEFAULT 0, unlimited_quota BOOLEAN DEFAULT FALSE, model_limits_enabled BOOLEAN DEFAULT FALSE, model_limits TEXT, allow_ips TEXT DEFAULT '', used_quota BIGINT DEFAULT 0, "group" TEXT DEFAULT '', cross_group_retry BOOLEAN DEFAULT FALSE, deleted_at TIMESTAMPTZ);
ALTER SEQUENCE tokens_id_seq OWNED BY tokens.id;
GRANT USAGE ON SCHEMA public TO lmm_token_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON options, custom_oauth_providers, setups, users, user_sessions, two_fas, casbin_rule, auth_flows, two_fa_backup_codes, lmm_schema_contract, tokens TO lmm_token_runtime;
GRANT USAGE ON SEQUENCE auth_flows_id_seq, tokens_id_seq TO lmm_token_runtime;
SQL

# This bcrypt fixture intentionally contains dollar signs as literal data.
# shellcheck disable=SC2016
root_hash='$2a$10$5Rm09lSOGBsP.6RiFTuleun103cKGxh/grNS/rcy7HPxJDvY9EEt2'
# Defaults are explicit fixtures.  The non-default values below are applied
# before each listener starts, proving that the route observes option storage,
# rather than a process-local main configuration constant.
for database in token_go token_rust; do
  psql -h 127.0.0.1 -p "$pg_port" -d "$database" -v ON_ERROR_STOP=1 -c "INSERT INTO users (id,username,password,display_name,role,status,\"group\",setting,auth_version,quota) VALUES (1,'root','$root_hash','root',100,1,'default','{}',1,100000000)" >/dev/null
  psql -h 127.0.0.1 -p "$pg_port" -d "$database" -v ON_ERROR_STOP=1 -c "INSERT INTO options (key,value) VALUES ('token_setting.max_user_tokens','2'),('QuotaPerUnit','2') ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value" >/dev/null
done

# Go caches options during process initialization.  Restart only the local
# disposable listener after seeding, so its in-memory settings and PostgreSQL
# fixture describe the same non-default contract as Rust's per-request read.
kill "$go_pid"; wait "$go_pid" || true
SQL_DSN="postgresql://127.0.0.1:$pg_port/token_go?sslmode=disable" PORT="$go_port" \
  REDIS_CONN_STRING="redis://127.0.0.1:$go_valkey_port" SESSION_SECRET='TokenListener-2026!Synthetic' \
  PASSWORD_LOGIN_ENABLED=true GLOBAL_API_RATE_LIMIT_ENABLE=false CRITICAL_RATE_LIMIT_ENABLE=false GIN_MODE=release \
  "$runtime/legacy-go" >"$runtime/go-restarted.log" 2>&1 & go_pid=$!
for _ in {1..300}; do curl -fsS "http://127.0.0.1:$go_port/api/status" >/dev/null 2>&1 && break; sleep .05; done
if ! curl -fsS "http://127.0.0.1:$go_port/api/status" >/dev/null; then
  echo "Restarted legacy Go listener failed to become ready; captured log follows:" >&2
  sed -n '1,200p' "$runtime/go-restarted.log" >&2
  exit 1
fi

DATABASE_URL="postgresql://lmm_token_runtime@127.0.0.1:$pg_port/token_rust" VALKEY_URL="redis://127.0.0.1:$rust_valkey_port" \
  LMM_RS_LISTEN_ADDR="127.0.0.1:$rust_port" LMM_RS_SLOT=blue LMM_SCHEMA_CONTRACT=1 \
  SESSION_SECRET='TokenListener-Session-2026-Synthetic-Only!' \
  CRYPTO_SECRET='TokenListener-Crypto-2026-Synthetic-Only!' \
  PASSWORD_LOGIN_ENABLED=true GLOBAL_API_RATE_LIMIT_ENABLE=false CRITICAL_RATE_LIMIT_ENABLE=false VERSION=v0.0.0 \
  "$rust_binary" >"$runtime/rust.log" 2>&1 & rust_pid=$!
for _ in {1..300}; do curl -fsS "http://127.0.0.1:$rust_port/readyz" >/dev/null 2>&1 && break; sleep .05; done
if ! curl -fsS "http://127.0.0.1:$rust_port/readyz" >/dev/null; then
  echo "Rust listener failed to become ready; captured log follows:" >&2
  sed -n '1,240p' "$runtime/rust.log" >&2
  exit 1
fi

login() {
  local base=$1 result
  result=$(curl -fsS -H 'content-type: application/json' -d '{"username":"root","password":"password"}' "$base/api/user/login")
  jq -er 'select(.success == true) | .data.access_token | select(type == "string" and length > 0)' <<<"$result"
}
go_bearer=$(login "http://127.0.0.1:$go_port")
rust_bearer=$(login "http://127.0.0.1:$rust_port")

# The delegated TCP sequence includes authenticated and unauthenticated
# preflight, malformed IDs, paging, secret-read headers, delete replay, and
# CRUD.  It intentionally gets credentials only from the local login calls.
GO_BASE_URL="http://127.0.0.1:$go_port" RUST_BASE_URL="http://127.0.0.1:$rust_port" \
  GO_AUTH_BEARER="$go_bearer" RUST_AUTH_BEARER="$rust_bearer" \
  GO_POSTGRES_URL="postgresql://127.0.0.1:$pg_port/token_go" \
  RUST_POSTGRES_URL="postgresql://127.0.0.1:$pg_port/token_rust" \
  GO_VALKEY_PORT="$go_valkey_port" RUST_VALKEY_PORT="$rust_valkey_port" \
  LMM_API_TOKEN_EXPECT_LIMIT=2 \
  bash "$repo_root/rust/behavior-oracle/captures/api-token/tcp-differential.sh"

jq -cn '{test:"api-token-local-tcp-differential",postgres_major:18,go_tcp_listener:true,rust_tcp_listener:true,real_valkey:true,isolated:true,options:{QuotaPerUnit:"2",max_user_tokens:2},result:"passed"}'
