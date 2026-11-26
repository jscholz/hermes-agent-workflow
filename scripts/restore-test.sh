#!/usr/bin/env bash
# Acceptance test (docs/BACKUPS.md). Usage: scripts/restore-test.sh [restic-repo]
# Restores `latest` nightly into a scratch
# dir, load the sqlite dumps into scratch DBs (integrity_check), load the
# hindsight dump into a scratch Postgres database, compare row counts.
set -uo pipefail
BACKUP_HOME="${BACKUP_HOME:-$HOME/.backups}"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$BACKUP_HOME/restic.key}" RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-$BACKUP_HOME/cache}"
R="$(command -v restic || echo "$HOME/.backups/bin/restic")"; REPO=${1:-$HOME/.backups/restic}
STAGE="${BACKUP_STAGE:-$HOME/.backups/stage}"   # the path the snapshots were taken from
T="${BACKUP_HOME:-$HOME/.backups}/restore-test"; rm -rf "$T"; mkdir -p "$T"
SQ="${HOME}/.local/bin/sqlite3"; [[ -x "$SQ" ]] || SQ="$(command -v sqlite3)"; PG="${PGBIN:-$(ls -d "$HOME"/.pg0/installation/*/bin 2>/dev/null | sort -V | tail -1)}"; export PGPASSWORD="${PGPASSWORD:-hindsight}"
pg() { "$PG/psql" -h 127.0.0.1 -U hindsight -Atq "$@"; }
ok=1; say() { echo "[$(date -u +%FT%TZ)] $*"; }
say "restore latest nightly from $REPO"
$R -r "$REPO" restore latest --tag nightly --target "$T" --path "$STAGE" -q || { say "RESTORE FAILED"; exit 1; }
S="$T$STAGE"; ls "$S"
# hermes state
say "hermes-data → scratch sqlite"
"$SQ" "$T/state.db" < "$S/hermes-data/schema.sql"
{ echo "BEGIN;"; cat "$S"/hermes-data/sessions.sql "$S"/hermes-data/state_meta.sql "$S"/hermes-data/schema_version.sql; for f in $(ls "$S"/hermes-data/messages/*.sql | LC_ALL=C sort); do cat "$f"; done; echo "COMMIT;"; } | "$SQ" "$T/state.db" || ok=0
echo "  integrity: $("$SQ" "$T/state.db" 'pragma integrity_check')"
for t in sessions messages; do
  r=$("$SQ" "$T/state.db" "select count(*) from $t"); l=$("$SQ" "file:$HOME/.hermes/state.db?mode=ro" "select count(*) from $t")
  echo "  $t restored=$r live=$l"; (( r > l - l/100 )) || ok=0   # within 1% (live keeps growing)
done
# parley
say "parley-data → scratch sqlite"
"$SQ" "$T/parley.db" < "$S/parley-data/parley.sql" || ok=0
echo "  integrity: $("$SQ" "$T/parley.db" 'pragma integrity_check')"
for t in msg_links activity_items pins unread_state; do
  r=$("$SQ" "$T/parley.db" "select count(*) from $t"); l=$("$SQ" "file:$HOME/.hermes/parley.db?mode=ro" "select count(*) from $t"); echo "  $t restored=$r live=$l"
done
# hindsight → scratch database with the same schema (schema-only dump of the live DB)
say "hindsight-data → scratch postgres db hindsight_restore_test"
pg -d postgres -c "DROP DATABASE IF EXISTS hindsight_restore_test" >/dev/null; pg -d postgres -c "CREATE DATABASE hindsight_restore_test" >/dev/null || { say "cannot create scratch db"; exit 1; }
"$PG/pg_dump" -h 127.0.0.1 -U hindsight -d hindsight --schema-only | pg -d hindsight_restore_test -v ON_ERROR_STOP=0 >/dev/null 2>"$T/schema.err"
( echo "SET session_replication_role = replica;"; for f in $(ls "$S"/hindsight-data/*.sql | LC_ALL=C sort); do cat "$f"; done; echo "SET session_replication_role = origin;" ) \
  | pg -d hindsight_restore_test --single-transaction -v ON_ERROR_STOP=1 >/dev/null 2>"$T/load.err" || { ok=0; say "hindsight load FAILED: $(tail -2 "$T/load.err")"; }
for t in memory_units memory_links documents entities chunks; do
  r=$(pg -d hindsight_restore_test -c "select count(*) from $t"); l=$(pg -d hindsight -c "select count(*) from $t"); echo "  $t restored=$r live=$l"
  (( r > l - l/100 )) || ok=0
done
pg -d postgres -c "DROP DATABASE hindsight_restore_test" >/dev/null
say "RESULT: $([[ $ok == 1 ]] && echo PASS || echo FAIL)"; rm -rf "$T"; exit $(( 1 - ok ))
