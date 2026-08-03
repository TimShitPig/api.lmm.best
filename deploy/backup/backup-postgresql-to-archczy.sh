#!/usr/bin/env bash
# Creates a verified PostgreSQL custom-format dump and streams it to archczy.
set -Eeuo pipefail

readonly SNAPSHOT_PREFIX='lmm-api-postgresql-'
readonly SNAPSHOT_PATTERN='^lmm-api-postgresql-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{16}\.dump$'

PG_DUMP_BIN="${PG_DUMP_BIN:-pg_dump}"
PG_RESTORE_BIN="${PG_RESTORE_BIN:-pg_restore}"
SHA256SUM_BIN="${SHA256SUM_BIN:-sha256sum}"
SSH_BIN="${SSH_BIN:-ssh}"
LOCK_FILE="${POSTGRES_BACKUP_LOCK_FILE:-/run/lmm-api-postgresql-backup/backup.lock}"
REMOTE_INSTANCE="${POSTGRES_BACKUP_REMOTE_INSTANCE:-production}"

log() { printf '[lmm-api-postgresql-backup] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

require_absolute_path() {
  local value="$1" label="$2"
  [[ "$value" == /* && "$value" != *$'\n'* ]] || die "$label must be an absolute path"
}

require_tools() {
  local tool
  for tool in "$PG_DUMP_BIN" "$PG_RESTORE_BIN" "$SHA256SUM_BIN" "$SSH_BIN" \
    flock mktemp date chmod awk tr od dirname mkdir stat rm; do
    command -v "$tool" >/dev/null 2>&1 || die "missing command: $tool"
  done
}

require_configuration() {
  : "${POSTGRES_BACKUP_DATABASE:?POSTGRES_BACKUP_DATABASE must be set}"
  : "${POSTGRES_BACKUP_REMOTE_HOST:?POSTGRES_BACKUP_REMOTE_HOST must be set}"
  : "${CREDENTIALS_DIRECTORY:?CREDENTIALS_DIRECTORY must be set by systemd LoadCredential}"
  require_absolute_path "$LOCK_FILE" 'POSTGRES_BACKUP_LOCK_FILE'
  require_absolute_path "$CREDENTIALS_DIRECTORY" 'CREDENTIALS_DIRECTORY'
  [[ "$POSTGRES_BACKUP_DATABASE" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,62}$ ]] ||
    die 'POSTGRES_BACKUP_DATABASE contains unsupported characters'
  [[ "$POSTGRES_BACKUP_REMOTE_HOST" =~ ^[A-Za-z0-9_.@:-]+$ ]] ||
    die 'POSTGRES_BACKUP_REMOTE_HOST contains unsupported characters'
  [[ "$REMOTE_INSTANCE" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] ||
    die 'POSTGRES_BACKUP_REMOTE_INSTANCE is unsafe'
  IDENTITY_FILE="$CREDENTIALS_DIRECTORY/archczy-postgresql-backup.identity"
  KNOWN_HOSTS_FILE="$CREDENTIALS_DIRECTORY/archczy-postgresql-backup.known_hosts"
  [[ -f "$IDENTITY_FILE" && -r "$IDENTITY_FILE" ]] || die 'missing archczy backup SSH identity credential'
  [[ -f "$KNOWN_HOSTS_FILE" && -r "$KNOWN_HOSTS_FILE" ]] || die 'missing archczy backup known_hosts credential'
}

temporary_dir=''
cleanup() {
  local status=$?
  [[ -z "$temporary_dir" ]] || rm -rf -- "$temporary_dir"
  return "$status"
}
trap cleanup EXIT

main() {
  local lock_parent dump_file dump_hash dump_size snapshot_id snapshot_name remote_command
  local -a transport_options

  require_tools
  require_configuration
  transport_options=(
    -F /dev/null
    -i "$IDENTITY_FILE"
    -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE"
    -o StrictHostKeyChecking=yes
    -o IdentitiesOnly=yes
    -o BatchMode=yes
    -o ConnectTimeout=30
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
  )

  lock_parent="$(dirname -- "$LOCK_FILE")"
  if [[ ! -d "$lock_parent" ]]; then
    mkdir -m 0700 -- "$lock_parent"
  fi
  exec 9>"$LOCK_FILE"
  flock -n 9 || die 'another PostgreSQL backup is already running'

  temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/lmm-api-postgresql-backup.XXXXXXXX")"
  chmod 0700 -- "$temporary_dir"
  dump_file="$temporary_dir/production.dump"

  # pg_dump's custom format is a transactionally consistent logical snapshot.
  "$PG_DUMP_BIN" --format=custom --file="$dump_file" --dbname="$POSTGRES_BACKUP_DATABASE"
  chmod 0600 -- "$dump_file"
  "$PG_RESTORE_BIN" --list "$dump_file" >/dev/null

  dump_hash="$("$SHA256SUM_BIN" -- "$dump_file" | awk '{print $1}')"
  [[ "$dump_hash" =~ ^[a-f0-9]{64}$ ]] || die 'could not calculate dump SHA-256'
  dump_size="$(stat -c '%s' -- "$dump_file")"
  [[ "$dump_size" =~ ^[1-9][0-9]*$ ]] || die 'dump is unexpectedly empty'
  snapshot_id="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  snapshot_name="${SNAPSHOT_PREFIX}${snapshot_id}.dump"
  [[ "$snapshot_name" =~ $SNAPSHOT_PATTERN ]] || die 'generated an unsafe snapshot name'

  remote_command="receive-postgresql-backup $REMOTE_INSTANCE $snapshot_name $dump_hash $dump_size"
  "$SSH_BIN" "${transport_options[@]}" "$POSTGRES_BACKUP_REMOTE_HOST" "$remote_command" <"$dump_file"
  log "backup completed: $snapshot_name ($dump_size bytes, SHA-256 $dump_hash)"
}

main "$@"
