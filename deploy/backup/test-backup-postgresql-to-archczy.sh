#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/backup-postgresql-to-archczy.sh"
RECEIVER_SCRIPT="$SCRIPT_DIR/receive-postgresql-backup.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
fail() { printf 'test-backup-postgresql-to-archczy: %s\n' "$*" >&2; exit 1; }
command -v fakeroot >/dev/null 2>&1 || fail 'fakeroot is required for offline root-owned receiver simulation'

make_fakes() {
  mkdir -p -- "$test_root/bin" "$test_root/credentials" "$test_root/tmp" "$test_root/remote"
  : >"$test_root/credentials/archczy-postgresql-backup.identity"
  : >"$test_root/credentials/archczy-postgresql-backup.known_hosts"
  chmod 0600 -- "$test_root/credentials"/*

  sed "s|readonly REMOTE_ROOT='/var/backups/lmm-api/postgresql'|readonly REMOTE_ROOT='$test_root/remote/postgresql'|" \
    "$RECEIVER_SCRIPT" >"$test_root/receiver.sh"
  chmod 0755 -- "$test_root/receiver.sh"

  cat >"$test_root/bin/pg_dump" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == --format=custom && "$2" == --file=* && "$3" == --dbname=testdb ]] || exit 80
[[ "${FAKE_PG_DUMP_FAIL:-0}" != 1 ]] || exit 81
printf 'PGDUMP-MOCK\n%s\n' "${FAKE_DUMP_SEQUENCE:-0}" >"${2#--file=}"
EOF
  cat >"$test_root/bin/pg_restore" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == --list && -f "$2" ]] || exit 82
grep -q '^PGDUMP-MOCK$' "$2"
EOF
  cat >"$test_root/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -u ]]; then printf '0\n'; else exec /usr/bin/id "$@"; fi
EOF
  cat >"$test_root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
while [[ "$1" == -F || "$1" == -i || "$1" == -o ]]; do shift 2; done
[[ "$1" == arch@fake-archczy ]] || exit 83
remote_command="$2"
if [[ "${FAKE_SSH_FAIL:-0}" == 1 ]]; then exit 84; fi
if [[ "${FAKE_SSH_CORRUPT:-0}" == 1 ]]; then
  { cat; printf 'corrupt'; } | fakeroot -- env PATH="$FAKE_REMOTE_BIN:$PATH" \
    bash "$FAKE_RECEIVER" --original-command "$remote_command"
else
  fakeroot -- env PATH="$FAKE_REMOTE_BIN:$PATH" \
    bash "$FAKE_RECEIVER" --original-command "$remote_command"
fi
EOF
  chmod 0755 -- "$test_root/bin/pg_dump" "$test_root/bin/pg_restore" \
    "$test_root/bin/id" "$test_root/bin/ssh"
}

run_backup() {
  local sequence="${1:-0}"
  POSTGRES_BACKUP_DATABASE=testdb \
    POSTGRES_BACKUP_REMOTE_HOST=arch@fake-archczy \
    POSTGRES_BACKUP_REMOTE_INSTANCE=production \
    POSTGRES_BACKUP_LOCK_FILE="$test_root/backup.lock" \
    CREDENTIALS_DIRECTORY="$test_root/credentials" \
    PG_DUMP_BIN="$test_root/bin/pg_dump" \
    PG_RESTORE_BIN="$test_root/bin/pg_restore" \
    SSH_BIN="$test_root/bin/ssh" \
    FAKE_DUMP_SEQUENCE="$sequence" \
    FAKE_RECEIVER="$test_root/receiver.sh" \
    FAKE_REMOTE_BIN="$test_root/bin" \
    TMPDIR="$test_root/tmp" \
    bash "$BACKUP_SCRIPT"
}

count_valid() {
  local dir="$test_root/remote/postgresql/production" candidate name count=0
  shopt -s nullglob
  for candidate in "$dir"/lmm-api-postgresql-*.dump; do
    name="$(basename -- "$candidate")"
    [[ -f "$candidate.sha256" ]] || continue
    (cd -- "$dir" && sha256sum -c -- "$name.sha256" >/dev/null) || continue
    "$test_root/bin/pg_restore" --list "$candidate" >/dev/null || continue
    ((count += 1))
  done
  printf '%s\n' "$count"
}

test_transfer_validation_and_retention() {
  local dir="$test_root/remote/postgresql/production" candidate
  for sequence in {1..16}; do run_backup "$sequence"; done
  [[ "$(count_valid)" == 14 ]] || fail 'receiver did not retain exactly 14 valid dumps'
  [[ "$(stat -c '%a' -- "$dir")" == 700 ]] || fail 'remote directory mode is not 0700'
  for candidate in "$dir"/*.dump "$dir"/*.sha256; do
    [[ "$(stat -c '%a' -- "$candidate")" == 600 ]] || fail 'published file mode is not 0600'
  done
}

test_failures_preserve_published_dumps() {
  local before
  before="$(count_valid)"
  if FAKE_SSH_CORRUPT=1 run_backup corrupt; then fail 'corrupt transfer succeeded'; fi
  [[ "$(count_valid)" == "$before" ]] || fail 'corrupt transfer changed valid retention set'
  if FAKE_PG_DUMP_FAIL=1 run_backup dump-failure; then fail 'pg_dump failure succeeded'; fi
  [[ "$(count_valid)" == "$before" ]] || fail 'pg_dump failure changed valid retention set'
}

test_configuration_and_command_guards() {
  if POSTGRES_BACKUP_DATABASE='-unsafe' POSTGRES_BACKUP_REMOTE_HOST=arch@fake-archczy \
    CREDENTIALS_DIRECTORY="$test_root/credentials" bash "$BACKUP_SCRIPT"; then
    fail 'unsafe database name accepted'
  fi
  if fakeroot -- env PATH="$test_root/bin:$PATH" bash "$test_root/receiver.sh" \
    --original-command 'sh -c anything'; then
    fail 'arbitrary forced command accepted'
  fi
  if fakeroot -- env PATH="$test_root/bin:$PATH" bash "$test_root/receiver.sh" \
    --original-command 'receive-postgresql-backup ../escape bad.dump a 1'; then
    fail 'unsafe receiver metadata accepted'
  fi
}

make_fakes
test_transfer_validation_and_retention
test_failures_preserve_published_dumps
test_configuration_and_command_guards
printf 'test-backup-postgresql-to-archczy: OK\n'
