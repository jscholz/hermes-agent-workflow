# Backups: restic, not git

The live databases are backed up by **restic**, never committed to this
repo. The repo holds config, memory, cron state and the two backup secrets
(`backups/`, git-crypt'd). Data lives in restic repos.

## What is backed up

| Source | Dump (staged under `~/.backups/stage/`) | By |
|---|---|---|
| `~/.hermes/state.db` — hermes sessions + messages, the agent transcript | `hermes-data/` (schema, sessions, state_meta, schema_version, `messages/NNNN.sql` id-range chunks) | `scripts/sync-hermes-state.sh` |
| hindsight memory bank (pg0 Postgres) | `hindsight-data/<table>.sql`, one COPY file per public table, rows ordered by insertion time | `scripts/sync-hindsight-bank.sh` |
| `~/.hermes/parley.db` — pins, read pointers, activity, push subs | `parley-data/parley.sql` | `scripts/sync-parley-db.sh` |

All three are taken from `.backup` snapshots with a WAL-safe sqlite3
(`~/.local/bin/sqlite3`, 3.51.3+; a build with the WAL-reset bug can
unlink the gateway's live WAL) or `COPY (… ORDER BY …)`.
`memory_units.embedding` is excluded (derived; hindsight rebuilds it).

## Where it goes

`scripts/backup-nightly.sh` (cron 03:33 on the `ACTIVE_HOST`; a standby
exits at once):

1. runs the three dumps into the stage;
2. `restic backup` of the stage into the **local repo** `~/.backups/restic`;
3. `restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --keep-yearly 3`,
   `prune` and `check --read-data-subset=10%` on Sundays;
4. `restic copy` of new snapshots to the **cloud repo** `BACKUP_CLOUD_REPO`
   (from `~/.hermes/.env`), same retention there. Any restic repo string
   works: `rclone:gdrive:hermes-backups/restic` (Google Drive through
   rclone, see `backups/rclone.conf.example`), `sftp:user@host:/path`,
   `s3:…`, `b2:…`. Unset = local repo only; the nightly log says so.

Secrets: `backups/restic.key` (repo password, also at `~/.backups/restic.key`)
and `backups/rclone.conf` (cloud token, only for rclone backends). Both
git-crypt'd. **Lose the key = lose every backup**; it lives in this repo
precisely so a fresh clone + `git-crypt unlock` is enough to restore.

Status: `~/.hermes/logs/backup-nightly.status.json`, read by
`scripts/doctor.sh` (last run > 30 h, failed run, failed cloud copy,
failed integrity check, > 2 GB growth in one run).

Tools: `bootstrap.sh` installs pinned restic + rclone static binaries into
`~/.backups/bin` (checksums verified against the release `SHA256SUMS`),
symlinked from `~/.local/bin`.

## Why restic

Content-defined chunking: a night costs the changed pieces of the dumps,
tens of MB, because the dumps are ordered so new rows land at the end.
Encrypted at rest. Retention is a policy. Same repo format on a disk, over
SSH, or behind rclone, so copies are interchangeable.

The earlier git-based version chunked each dump to stay under GitHub's
100 MB blob cap, then git-crypt'd it. Encrypted blobs cannot be deltified
or compressed, a chunk sorted on a non-unique key reorders on every run,
and git never expires anything: the whole dump is stored again every
night, forever. See `docs/MIGRATE-BACKUPS.md` if your fork carries that
history.

## Restore

```
export RESTIC_PASSWORD_FILE=~/.backups/restic.key RCLONE_CONFIG=<repo>/backups/rclone.conf
restic -r ~/.backups/restic snapshots                      # or -r "$BACKUP_CLOUD_REPO"
restic -r ~/.backups/restic restore latest --tag nightly --target / --path ~/.backups/stage
scripts/restore-hermes-state.sh      # gateway stopped; DUMP_DIR=… to override
scripts/restore-hindsight-bank.sh
scripts/restore-parley-db.sh
```

`scripts/handoff-in.sh` does exactly this (local repo first, cloud if the
host has none); `scripts/bootstrap.sh` likewise on a fresh machine. A
standby host needs the binaries and the unlocked repo for the two secrets.

Acceptance test, after any change here and periodically:
`scripts/restore-test.sh [repo]` restores `latest` into a scratch dir,
loads the sqlite dumps into scratch files (`PRAGMA integrity_check`),
loads the hindsight dump into a scratch Postgres database and compares row
counts with the live bank.
