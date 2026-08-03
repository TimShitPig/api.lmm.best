# SQLite online backup to archczy

This is an inert deployment bundle for legacy SQLite deployments.
The job uses SQLite's online `.backup` API into a private `mktemp` directory,
requires `PRAGMA quick_check` to return `ok`, validates the zstd archive, then
ships an archive/checksum pair through a pinned SSH identity. Remote retention
only counts SHA-256-valid snapshots and retains exactly the newest three.

The remote destination is deliberately fixed to:

```
/var/backups/lmm-api/sqlite/<instance>
```

`<instance>` defaults to `production` and is restricted to one safe path
component. `/`, `/etc`, traversal, and arbitrary remote directories cannot be
configured. The script performs a pinned-SSH preflight before either SCP:
the fixed root and instance directory are created/verified as `root:root 0700`.
The dedicated remote backup account must therefore run the backup command as
root (for example through a narrowly constrained forced command or dedicated
root-only key). Archive files are mode `0600`; the instance directory is mode
`0700`. The checksum is the publication marker: the archive is atomically
renamed first and the checksum is renamed last. A failed transfer or validation
never runs retention and cannot remove the three last known-good snapshots.

The PostgreSQL production deployment uses the separate logical-dump workflow
below. Neither workflow ever restores into the test database automatically.

## Required configuration

Create `/etc/lmm-api/sqlite-backup.env` with mode `0600`:

```sh
SQLITE_BACKUP_SOURCE_DB=/var/lib/private/lmm-api/one-api.db
SQLITE_BACKUP_REMOTE_HOST=archczy
SQLITE_BACKUP_REMOTE_INSTANCE=production
```

The source database must be an explicit absolute path. No discovery or globbing
is performed.

Create dedicated, root-readable credentials (not `/root/.ssh`) with mode
`0600`:

```
/etc/lmm-api/credentials/archczy-backup.identity
/etc/lmm-api/credentials/archczy-backup.known_hosts
```

The identity must be a backup-only key accepted by `archczy`; its known-hosts
file must pin archczy's host key. `LoadCredential=` copies both into systemd's
per-service `CREDENTIALS_DIRECTORY`. The script explicitly supplies `-i`,
`UserKnownHostsFile`, `StrictHostKeyChecking=yes`, `IdentitiesOnly=yes`, and
`BatchMode=yes` to both `ssh` and `scp`, so it never falls back to
`/root/.ssh`.

Bootstrap the target directory once using the same restricted remote identity
before enabling the timer (the scheduled script repeats this check):

```sh
ssh -i /etc/lmm-api/credentials/archczy-backup.identity \
  -o UserKnownHostsFile=/etc/lmm-api/credentials/archczy-backup.known_hosts \
  -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -o BatchMode=yes archczy \
  'install -d -o root -g root -m 0700 /var/backups/lmm-api/sqlite/production'
```

Then verify on archczy: `stat -c '%U:%G:%a' /var/backups/lmm-api/sqlite/production`
must print `root:root:700`.

## Approved installation change

Do this only in an approved maintenance window; this repository task does not
install or enable it:

```sh
install -d -m 0755 /usr/local/lib/lmm-api /etc/lmm-api/credentials
install -m 0750 deploy/backup/backup-sqlite-to-archczy.sh /usr/local/lib/lmm-api/
install -m 0644 deploy/backup/lmm-api-sqlite-backup.service /etc/systemd/system/
install -m 0644 deploy/backup/lmm-api-sqlite-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now lmm-api-sqlite-backup.timer
```

The timer runs daily at **03:30 Asia/Shanghai**. Before enabling, make one
approved manual run and verify that `archczy` has the expected safe instance
directory, pinned key access, and at most three valid archive/checksum pairs.

## Offline verification

```sh
bash deploy/backup/test-backup-sqlite-to-archczy.sh
```

The test uses temporary SQLite WAL databases and fake local `ssh`/`scp`; it
makes no network connection and never touches `/var/backups`.

# PostgreSQL production backup to archczy

`backup-postgresql-to-archczy.sh` runs as the local `postgres` account. It
creates a custom-format logical dump, validates it with `pg_restore --list`,
and streams it over a pinned, dedicated SSH identity. The archczy forced-command
receiver checks the exact command shape, byte count, SHA-256, and PostgreSQL
archive directory before atomically publishing the dump and checksum.

The destination is fixed to:

```
/var/backups/lmm-api/postgresql/production
```

The directory is `root:root 0700`; dumps and checksums are `0600`. The newest
14 checksum-valid and `pg_restore --list`-valid dumps are retained. Partial or
invalid uploads are never published and never trigger retention. These files
are cold backups only: no timer, receiver, or installation command restores a
dump, changes the test PostgreSQL database, or restarts either API service.

## Configure the restricted receiver on archczy

Install the root-owned receiver and its exact sudo rule:

```sh
sudo install -d -o root -g root -m 0755 /usr/local/lib/lmm-api
sudo install -m 0755 deploy/backup/receive-postgresql-backup.sh /usr/local/lib/lmm-api/
sudo install -o root -g root -m 0440 deploy/backup/lmm-api-postgresql-backup.sudoers \
  /etc/sudoers.d/lmm-api-postgresql-backup
sudo visudo -cf /etc/sudoers.d/lmm-api-postgresql-backup
sudo install -d -o root -g root -m 0700 /var/backups/lmm-api/postgresql/production
```

Add the dedicated public key to `/home/arch/.ssh/authorized_keys` as one line:

```
restrict,command="/usr/local/lib/lmm-api/receive-postgresql-backup.sh" ssh-ed25519 AAAA... lmm-api-postgresql-backup
```

The forced command rejects shell commands and every instance name except
`production`. `restrict` disables PTY, forwarding, agent/X11 forwarding, and
user startup files. The receiver elevates only through the root-owned,
validation-only script above.

## Configure the sender on production

Create a dedicated key and pin archczy's already-verified host key in:

```
/etc/lmm-api/credentials/archczy-postgresql-backup.identity
/etc/lmm-api/credentials/archczy-postgresql-backup.known_hosts
```

Both source files must be `root:root 0600`. Create
`/etc/lmm-api/postgresql-backup.env` as `root:root 0600`:

```sh
POSTGRES_BACKUP_DATABASE=lmm_api
POSTGRES_BACKUP_REMOTE_HOST=arch@216.126.239.69
POSTGRES_BACKUP_REMOTE_INSTANCE=production
```

The database name is explicit and the service runs as `postgres`, using local
peer authentication rather than copying the application's database password.
Install the sender and units, then run and verify one manual backup before
enabling the timer:

```sh
install -d -m 0755 /usr/local/lib/lmm-api /etc/lmm-api/credentials
install -m 0755 deploy/backup/backup-postgresql-to-archczy.sh /usr/local/lib/lmm-api/
install -m 0644 deploy/backup/lmm-api-postgresql-backup.service /etc/systemd/system/
install -m 0644 deploy/backup/lmm-api-postgresql-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl start lmm-api-postgresql-backup.service
systemctl enable --now lmm-api-postgresql-backup.timer
```

The timer runs daily at **03:30 Asia/Shanghai**, with up to ten minutes of
randomized delay and catch-up after downtime. Validate a received dump without
restoring it:

```sh
cd /var/backups/lmm-api/postgresql/production
sha256sum -c lmm-api-postgresql-*.dump.sha256
pg_restore --list lmm-api-postgresql-*.dump >/dev/null
```

## PostgreSQL offline verification

```sh
bash deploy/backup/test-backup-postgresql-to-archczy.sh
```

The test uses fake `pg_dump`, `pg_restore`, and SSH endpoints under a temporary
directory. It exercises validation, atomic publication, failure handling, and
14-version retention without a network connection or PostgreSQL server.
