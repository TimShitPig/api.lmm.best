#!/usr/bin/env bash
# Isolated real-TCP Go/Rust differential for the three public-content routes.
# This file deliberately owns no shared helper: its lifecycle boundary is part
# of the evidence.  `/api/status` is covered by status-listener-differential.
set -euo pipefail
set +x

repo_root=$(git rev-parse --show-toplevel)
legacy_root="$repo_root/go"
approval_mode=${LMM_PUBLIC_ROUTES_APPROVAL:-0}
probe_only=${LMM_PUBLIC_ROUTES_PROBE_ONLY:-0}
curl_connect_timeout=2
curl_max_time=12
go_pid=''; rust_pid=''; go_valkey_pid=''; rust_valkey_pid=''; pg_pid=''

case "$approval_mode:$probe_only" in 0:0|1:0|0:1) ;; *) echo 'approval mode refuses probe-only' >&2; exit 2;; esac
for command in cargo curl flock git go initdb jq pg_ctl postgres psql sqlite3 ss valkey-cli valkey-server od sha256sum; do command -v "$command" >/dev/null || { echo "required command unavailable: $command" >&2; exit 1; }; done
[[ $(postgres --version) == *'PostgreSQL) 18.'* ]] || { echo 'requires PostgreSQL 18' >&2; exit 1; }
[[ -f "$legacy_root/go.mod" ]] || { echo 'maintained Go source missing' >&2; exit 1; }
frozen_go_manifest_sha256=$(bash "$repo_root/rust/behavior-oracle/go-source-manifest.sh" | sha256sum | awk '{print $1}')
build_input_hash() {
  (cd "$repo_root" && {
    printf '%s\0' rust/Cargo.toml rust/Cargo.lock rust/apps/lmm-api-rs/Cargo.toml
    [[ ! -f rust/apps/lmm-api-rs/build.rs ]] || printf '%s\0' rust/apps/lmm-api-rs/build.rs
    git ls-files -co --exclude-standard -z -- rust/apps/lmm-api-rs/src rust/apps/lmm-api-rs/assets rust/crates
  } | while IFS= read -r -d '' path; do [[ -f $path ]] && sha256sum "$path"; done | LC_ALL=C sort | sha256sum | awk '{print $1}')
}
rust_source_sha256=$(build_input_hash)
[[ $frozen_go_manifest_sha256 =~ ^[[:xdigit:]]{64}$ && $rust_source_sha256 =~ ^[[:xdigit:]]{64}$ ]] || exit 1
stop_pg() { if [[ -n ${pg_pid:-} ]] && owned pg_pid && listener_owned "$pg_port" "$pg_pid"; then pg_ctl -D "$runtime/pg" -m fast -w stop >/dev/null 2>&1 || true; else [[ -z ${pg_pid:-} ]] || echo "refusing unowned PostgreSQL cleanup" >&2; fi; pg_pid=''; }
if [[ $probe_only == 1 ]]; then
  jq -cn --arg go "$frozen_go_manifest_sha256" --arg rust "$rust_source_sha256" '{test:"public-routes-listener-differential",mode:"probe",approval_eligible:false,frozen_go_manifest_sha256:$go,rust_source_sha256:$rust,result:"passed"}'
  exit 0
fi
runtime=$(mktemp -d /tmp/lmm-public-listener.XXXXXX)
go_build=$(mktemp -d "${TMPDIR:-/tmp}/lmm-public-go.XXXXXX")
exec 9>/tmp/lmm-listener-differential-heavy.lock
flock -n 9 || { echo 'another listener differential owns the heavy lock' >&2; exit 1; }

pid_start() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
# shellcheck disable=SC2034 # start times are accessed through deliberate indirection.
record_pid() { local n=$1 p=$2 s; s=$(pid_start "$p") || return 1; printf -v "$n" %s "$p"; printf -v "${n}_start" %s "$s"; }
owned() { local n=$1 p s want; p=${!n:-}; s=${n}_start; want=${!s:-}; [[ -n $p && -n $want && $(pid_start "$p") == "$want" ]]; }
stop_owned() { local n=$1 p; p=${!n:-}; if [[ -n $p ]] && owned "$n"; then kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; elif [[ -n $p ]]; then echo "refusing recycled PID $p" >&2; fi; printf -v "$n" ''; printf -v "${n}_start" ''; }
cleanup() { stop_owned go_pid; stop_owned rust_pid; stop_owned go_valkey_pid; stop_owned rust_valkey_pid; stop_pg; case "$runtime" in /tmp/lmm-public-listener.*) rm -rf "$runtime";; esac; case "$go_build" in "${TMPDIR:-/tmp}"/lmm-public-go.*) rm -rf "$go_build";; esac; }
trap cleanup EXIT INT TERM
random_port() { local p; while :; do p=$((20000 + 0x$(od -An -N2 -tx2 /dev/urandom | tr -d ' ') % 35000)); [[ -z $(ss -H -ltn "sport = :$p") ]] && { echo "$p"; return; }; done; }
pg_port=$(random_port); go_port=$(random_port); rust_port=$(random_port); go_valkey_port=$(random_port); rust_valkey_port=$(random_port)
[[ $(printf '%s\n' "$pg_port" "$go_port" "$rust_port" "$go_valkey_port" "$rust_valkey_port" | sort -u | wc -l) == 5 ]] || exit 1
port_free() { [[ -z $(ss -H -ltn "sport = :$1" 2>/dev/null) ]]; }
for port in "$pg_port" "$go_port" "$rust_port" "$go_valkey_port" "$rust_valkey_port"; do port_free "$port" || { echo "random port became occupied: $port" >&2; exit 1; }; done
listener_owned() { local port=$1 expected=$2 line; line=$(ss -H -ltnp "sport = :$port" 2>/dev/null || true); [[ $(wc -l <<<"$line") == 1 && $line == *"pid=$expected,"* ]]; }
wait_http() { local port=$1 path=$2 pid=$3; for _ in {1..240}; do listener_owned "$port" "$pid" && curl --connect-timeout "$curl_connect_timeout" --max-time "$curl_max_time" -fsS "http://127.0.0.1:$port$path" >/dev/null 2>&1 && return; sleep .05; done; return 1; }
password() { od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; }
go_password=$(password); rust_password=$(password); go_valkey_config="$runtime/go-valkey.conf"; rust_valkey_config="$runtime/rust-valkey.conf"; umask 077
printf 'bind 127.0.0.1\nport %s\nrequirepass %s\nsave \nappendonly no\ndir %s\n' "$go_valkey_port" "$go_password" "$runtime" >"$go_valkey_config"
printf 'bind 127.0.0.1\nport %s\nrequirepass %s\nsave \nappendonly no\ndir %s\n' "$rust_valkey_port" "$rust_password" "$runtime" >"$rust_valkey_config"
start_valkey_go() { port_free "$go_valkey_port" || return 1; valkey-server "$go_valkey_config" >"$runtime/go-valkey.log" 2>&1 & record_pid go_valkey_pid "$!"; for _ in {1..120}; do listener_owned "$go_valkey_port" "$go_valkey_pid" && valkey-cli --no-auth-warning -h 127.0.0.1 -p "$go_valkey_port" -a "$go_password" ping >/dev/null && return; sleep .05; done; return 1; }
start_valkey_rust() { port_free "$rust_valkey_port" || return 1; valkey-server "$rust_valkey_config" >"$runtime/rust-valkey.log" 2>&1 & record_pid rust_valkey_pid "$!"; for _ in {1..120}; do listener_owned "$rust_valkey_port" "$rust_valkey_pid" && valkey-cli --no-auth-warning -h 127.0.0.1 -p "$rust_valkey_port" -a "$rust_password" ping >/dev/null && return; sleep .05; done; return 1; }

cargo build --manifest-path "$repo_root/rust/Cargo.toml" -p lmm-api-rs --locked
[[ $(build_input_hash) == "$rust_source_sha256" ]] || { echo 'Rust build inputs changed during differential' >&2; exit 1; }
rust_binary_sha256=$(sha256sum "$repo_root/rust/target/debug/lmm-api-rs" | awk '{print $1}')
cp -a "$legacy_root/." "$go_build/source"; mkdir -p "$go_build/source/web/dist"; : >"$go_build/source/web/dist/index.html"; (cd "$go_build/source" && GOTOOLCHAIN=local CGO_ENABLED=1 go build -buildvcs=false -o "$runtime/legacy-go" .)
start_valkey_go; start_valkey_rust
port_free "$go_port" || exit 1; SQLITE_PATH="$runtime/go.db?_busy_timeout=30000" PORT="$go_port" REDIS_CONN_STRING="redis://:$(printf %s "$go_password")@127.0.0.1:$go_valkey_port" SESSION_SECRET='public-differential-synthetic' GLOBAL_API_RATE_LIMIT_ENABLE=false TRUSTED_PROXIES=none GIN_MODE=release "$runtime/legacy-go" >"$runtime/go.log" 2>&1 & record_pid go_pid "$!"; wait_http "$go_port" /api/status "$go_pid"
sqlite3 "$runtime/go.db" "INSERT OR REPLACE INTO options(key,value) VALUES ('Notice','notice value'),('About','about value'),('HomePageContent','home value');"
stop_owned go_pid
port_free "$go_port" || exit 1; SQLITE_PATH="$runtime/go.db?_busy_timeout=30000" PORT="$go_port" REDIS_CONN_STRING="redis://:$(printf %s "$go_password")@127.0.0.1:$go_valkey_port" SESSION_SECRET='public-differential-synthetic' GLOBAL_API_RATE_LIMIT_ENABLE=false TRUSTED_PROXIES=none GIN_MODE=release "$runtime/legacy-go" >"$runtime/go.log" 2>&1 & record_pid go_pid "$!"; wait_http "$go_port" /api/status "$go_pid"
port_free "$pg_port" || exit 1; initdb --no-locale --encoding=UTF8 --auth=trust -D "$runtime/pg" >/dev/null; pg_ctl -D "$runtime/pg" -l "$runtime/pg.log" -o "-h 127.0.0.1 -p $pg_port -k $runtime" -w start >/dev/null; record_pid pg_pid "$(head -n 1 "$runtime/pg/postmaster.pid")"; listener_owned "$pg_port" "$pg_pid" || { echo 'PostgreSQL listener ownership failed' >&2; exit 1; }; createdb -h 127.0.0.1 -p "$pg_port" public_diff
psql -h 127.0.0.1 -p "$pg_port" -d public_diff -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE ROLE lmm_public_runtime LOGIN; CREATE TABLE lmm_schema_contract(singleton BOOLEAN PRIMARY KEY,min_reader_version BIGINT NOT NULL,max_reader_version BIGINT NOT NULL); INSERT INTO lmm_schema_contract VALUES(true,1,1); CREATE TABLE options(key TEXT PRIMARY KEY,value TEXT); INSERT INTO options VALUES('Notice','notice value'),('About','about value'),('HomePageContent','home value'); CREATE TABLE custom_oauth_providers(id BIGINT PRIMARY KEY,name TEXT NOT NULL,slug TEXT NOT NULL,icon TEXT,enabled BOOLEAN,client_id TEXT,authorization_endpoint TEXT,scopes TEXT); CREATE TABLE setups(id BIGINT PRIMARY KEY); CREATE TABLE users(id BIGINT PRIMARY KEY,username TEXT,password TEXT NOT NULL,display_name TEXT,role BIGINT,status BIGINT,email TEXT,github_id TEXT,discord_id TEXT,oidc_id TEXT,wechat_id TEXT,telegram_id TEXT,"group" TEXT,quota BIGINT,used_quota BIGINT,request_count BIGINT,aff_code TEXT,aff_count BIGINT,aff_quota BIGINT,aff_history BIGINT,inviter_id BIGINT,linux_do_id TEXT,setting TEXT,stripe_customer TEXT,auth_version BIGINT,access_token TEXT,deleted_at TIMESTAMPTZ); CREATE TABLE user_sessions(sid TEXT PRIMARY KEY,user_id BIGINT,version BIGINT,user_auth_version BIGINT,status TEXT,refresh_hash CHAR(64),previous_refresh_hash TEXT,previous_valid_until BIGINT,login_method TEXT,ip TEXT,user_agent TEXT,created_at BIGINT,last_active_at BIGINT,expires_at BIGINT,revoked_at BIGINT,revoked_reason TEXT); CREATE TABLE two_fas(id BIGINT PRIMARY KEY,user_id BIGINT,is_enabled BOOLEAN,deleted_at TIMESTAMPTZ); CREATE TABLE casbin_rule(id BIGINT PRIMARY KEY,ptype TEXT,v0 TEXT,v1 TEXT,v2 TEXT,v3 TEXT); CREATE TABLE auth_flows(token_hash CHAR(64),purpose TEXT,user_id BIGINT,payload TEXT,created_at TIMESTAMPTZ,expires_at TIMESTAMPTZ,consumed_at TIMESTAMPTZ); CREATE SEQUENCE tokens_id_seq; CREATE TABLE tokens(id BIGINT PRIMARY KEY DEFAULT nextval('tokens_id_seq'),user_id BIGINT NOT NULL,key VARCHAR(128) UNIQUE,status INTEGER DEFAULT 1,name TEXT DEFAULT '',created_time BIGINT DEFAULT 0,accessed_time BIGINT DEFAULT 0,expired_time BIGINT DEFAULT -1,remain_quota BIGINT DEFAULT 0,unlimited_quota BOOLEAN DEFAULT false,model_limits_enabled BOOLEAN DEFAULT false,model_limits TEXT,allow_ips TEXT DEFAULT '',used_quota BIGINT DEFAULT 0,"group" TEXT DEFAULT '',cross_group_retry BOOLEAN DEFAULT false,deleted_at TIMESTAMPTZ); GRANT USAGE ON SCHEMA public TO lmm_public_runtime; GRANT SELECT ON ALL TABLES IN SCHEMA public TO lmm_public_runtime; GRANT INSERT,UPDATE ON auth_flows TO lmm_public_runtime; GRANT SELECT,INSERT,UPDATE,DELETE ON tokens TO lmm_public_runtime; GRANT USAGE ON SEQUENCE tokens_id_seq TO lmm_public_runtime;
SQL
port_free "$rust_port" || exit 1; DATABASE_URL="postgresql://lmm_public_runtime@127.0.0.1:$pg_port/public_diff" VALKEY_URL="redis://:$(printf %s "$rust_password")@127.0.0.1:$rust_valkey_port" LMM_RS_LISTEN_ADDR="127.0.0.1:$rust_port" LMM_RS_SLOT=blue LMM_SCHEMA_CONTRACT=1 SESSION_SECRET='public-differential-synthetic' GLOBAL_API_RATE_LIMIT_ENABLE=false VERSION=v0.0.0 "$repo_root/rust/target/debug/lmm-api-rs" >"$runtime/rust.log" 2>&1 & record_pid rust_pid "$!"; wait_http "$rust_port" /readyz "$rust_pid"
request() { local base=$1 path=$2 out=$3; curl --connect-timeout "$curl_connect_timeout" --max-time "$curl_max_time" -sS -D "$out.h" -o "$out.b" -w '%{http_code}' -H 'accept: application/json' "$base$path"; }
assert_headers() { awk 'BEGIN{IGNORECASE=1} /^content-type:[[:space:]]*application\/json; charset=utf-8\r?$/ {ct=1} /^x-new-api-version:[[:space:]]*v0\.0\.0\r?$/ {v=1} /^x-oneapi-request-id:[[:space:]]*[^[:space:]]+/ {r=1} END{exit !(ct&&v&&r)}' "$1"; }
scenario_total=0
compare() { local path=$1 name; name=${path##*/}; [[ $(request "http://127.0.0.1:$go_port" "$path" "$runtime/go-$name") == 200 ]]; [[ $(request "http://127.0.0.1:$rust_port" "$path" "$runtime/rust-$name") == 200 ]]; assert_headers "$runtime/go-$name.h"; assert_headers "$runtime/rust-$name.h"; jq -S . "$runtime/go-$name.b" >"$runtime/go-$name.json"; jq -S . "$runtime/rust-$name.b" >"$runtime/rust-$name.json"; diff -u "$runtime/go-$name.json" "$runtime/rust-$name.json"; scenario_total=$((scenario_total+1)); }
options_snapshot() { local engine=$1; if [[ $engine == go ]]; then sqlite3 -json "$runtime/go.db" 'SELECT key,value FROM options ORDER BY key'|jq -S .; else psql -h 127.0.0.1 -p "$pg_port" -d public_diff -qAt -c "SELECT COALESCE(json_agg(to_jsonb(x) ORDER BY x.key),'[]'::json) FROM (SELECT key,value FROM options)x"|jq -S .; fi; }
valkey_snapshot() { local port=$1 secret=$2; valkey-cli --no-auth-warning -h 127.0.0.1 -p "$port" -a "$secret" --scan | LC_ALL=C sort; }
options_snapshot go >"$runtime/go.options.before"; options_snapshot rust >"$runtime/rust.options.before"; valkey_snapshot "$go_valkey_port" "$go_password" >"$runtime/go.valkey.before"; valkey_snapshot "$rust_valkey_port" "$rust_password" >"$runtime/rust.valkey.before"
for route in /api/notice /api/about /api/home_page_content; do compare "$route"; done
[[ $scenario_total == 3 ]] || { echo "scenario count mismatch: $scenario_total" >&2; exit 1; }
options_snapshot go >"$runtime/go.options.after"; options_snapshot rust >"$runtime/rust.options.after"; diff -u "$runtime/go.options.before" "$runtime/go.options.after"; diff -u "$runtime/rust.options.before" "$runtime/rust.options.after"; valkey_snapshot "$go_valkey_port" "$go_password" >"$runtime/go.valkey.after"; valkey_snapshot "$rust_valkey_port" "$rust_password" >"$runtime/rust.valkey.after"; [[ ! -s $runtime/go.valkey.after ]]; diff -u /dev/null "$runtime/rust.valkey.before"; diff -u <(printf '%s\n' lmm:public-content:v1:about lmm:public-content:v1:home-page lmm:public-content:v1:notice) "$runtime/rust.valkey.after"
jq -cn --arg go "$frozen_go_manifest_sha256" --arg rust "$rust_source_sha256" --arg binary "$rust_binary_sha256" --argjson approval "$approval_mode" --argjson scenarios "$scenario_total" '{test:"public-routes-listener-differential",mode:"full",approval_eligible:($approval==1),real_tcp:true,scenario_count:$scenarios,routes:["GET /api/notice","GET /api/about","GET /api/home_page_content"],frozen_go_manifest_sha256:$go,rust_source_sha256:$rust,rust_binary_sha256:$binary,result:"passed"}'
