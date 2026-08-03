#!/usr/bin/env bash
# Forced-command receiver for production PostgreSQL dumps on archczy.
set -Eeuo pipefail

readonly REMOTE_ROOT='/var/backups/lmm-api/postgresql'
readonly SNAPSHOT_PREFIX='lmm-api-postgresql-'
readonly SNAPSHOT_PATTERN='^lmm-api-postgresql-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{16}\.dump$'
readonly RETENTION_COUNT=14

log() { printf '[lmm-api-postgresql-receiver] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

original_command=''
if [[ "${1:-}" == '--original-command' && $# == 2 ]]; then
  original_command="$2"
elif (( $# == 0 )); then
  original_command="${SSH_ORIGINAL_COMMAND:-}"
else
  die 'invalid receiver invocation'
fi

# archczy only permits SSH login as arch. The root-owned script is the sole
# sudo target, and it validates the complete original command before writing.
if (( EUID != 0 )); then
  [[ -n "$original_command" ]] || die 'missing SSH original command'
  exec sudo -n -- /usr/local/lib/lmm-api/receive-postgresql-backup.sh \
    --original-command "$original_command"
fi

for tool in realpath sha256sum pg_restore awk sort basename rm mv chmod stat install mktemp flock cat id; do
  command -v "$tool" >/dev/null 2>&1 || die "missing command: $tool"
done
[[ "$(id -u)" == 0 ]] || die 'receiver must run as root'

read -r -a command_fields <<<"$original_command"
(( ${#command_fields[@]} == 5 )) || die 'invalid receiver command field count'
[[ "${command_fields[0]}" == 'receive-postgresql-backup' ]] || die 'receiver command is not allowed'
instance="${command_fields[1]}"
snapshot_name="${command_fields[2]}"
expected_hash="${command_fields[3]}"
expected_size="${command_fields[4]}"

[[ "$instance" == 'production' ]] || die 'only the production backup instance is accepted'
[[ "$snapshot_name" =~ $SNAPSHOT_PATTERN ]] || die 'unsafe snapshot filename'
[[ "$expected_hash" =~ ^[a-f0-9]{64}$ ]] || die 'unsafe expected SHA-256'
[[ "$expected_size" =~ ^[1-9][0-9]*$ ]] || die 'unsafe expected byte count'

install -d -o root -g root -m 0700 -- "$REMOTE_ROOT"
destination_dir="$REMOTE_ROOT/$instance"
install -d -o root -g root -m 0700 -- "$destination_dir"
[[ "$(realpath -e -- "$REMOTE_ROOT")" == "$REMOTE_ROOT" ]] || die 'backup root must not resolve through a symlink'
[[ "$(realpath -e -- "$destination_dir")" == "$destination_dir" ]] || die 'backup directory must not resolve through a symlink'
for candidate in "$REMOTE_ROOT" "$destination_dir"; do
  [[ "$(stat -c '%U:%G:%a' -- "$candidate")" == 'root:root:700' ]] ||
    die 'backup directories must be root:root mode 0700'
done

exec 9>"$destination_dir/.receive.lock"
chmod 0600 -- "$destination_dir/.receive.lock"
flock -n 9 || die 'another PostgreSQL backup is being received'

partial_dump="$(mktemp "$destination_dir/.${snapshot_name}.upload.XXXXXXXX")"
partial_checksum=''
cleanup() {
  local status=$?
  [[ -z "$partial_dump" ]] || rm -f -- "$partial_dump"
  [[ -z "$partial_checksum" ]] || rm -f -- "$partial_checksum"
  return "$status"
}
trap cleanup EXIT
chmod 0600 -- "$partial_dump"
cat >"$partial_dump"

observed_size="$(stat -c '%s' -- "$partial_dump")"
[[ "$observed_size" == "$expected_size" ]] || die 'received dump byte count mismatch'
observed_hash="$(sha256sum -- "$partial_dump" | awk '{print $1}')"
[[ "$observed_hash" == "$expected_hash" ]] || die 'received dump SHA-256 mismatch'
pg_restore --list "$partial_dump" >/dev/null

partial_checksum="$(mktemp "$destination_dir/.${snapshot_name}.sha256.upload.XXXXXXXX")"
printf '%s  %s\n' "$expected_hash" "$snapshot_name" >"$partial_checksum"
chmod 0600 -- "$partial_checksum"
published_dump="$destination_dir/$snapshot_name"
published_checksum="$published_dump.sha256"
[[ ! -e "$published_dump" && ! -e "$published_checksum" ]] || die 'snapshot already exists'

# The checksum is the publication marker and therefore appears last.
mv -T -- "$partial_dump" "$published_dump"
partial_dump=''
chmod 0600 -- "$published_dump"
mv -T -- "$partial_checksum" "$published_checksum"
partial_checksum=''
chmod 0600 -- "$published_checksum"

mapfile -t snapshots < <(
  for candidate in "$destination_dir"/"${SNAPSHOT_PREFIX}"*.dump; do
    [[ -f "$candidate" ]] || continue
    name="$(basename -- "$candidate")"
    [[ "$name" =~ $SNAPSHOT_PATTERN && -f "$candidate.sha256" ]] || continue
    (cd -- "$destination_dir" && sha256sum -c -- "$name.sha256" >/dev/null 2>&1) || continue
    pg_restore --list "$candidate" >/dev/null 2>&1 || continue
    printf '%s\n' "$name"
  done | LC_ALL=C sort -r
)
(( ${#snapshots[@]} >= 1 )) || die 'no valid snapshot remains after publication'
for ((index = RETENTION_COUNT; index < ${#snapshots[@]}; index++)); do
  old_name="${snapshots[index]}"
  [[ "$old_name" =~ $SNAPSHOT_PATTERN ]] || die 'refusing to delete an unsafe filename'
  rm -f -- "$destination_dir/$old_name" "$destination_dir/$old_name.sha256"
done

log "accepted $snapshot_name ($observed_size bytes, SHA-256 $observed_hash)"
