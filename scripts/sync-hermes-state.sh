#!/usr/bin/env bash
# Dump ~/.hermes/state.db (hermes sessions + messages = the agent
# transcript) to the backup stage: ~/.backups/stage/hermes-data/
#   schema.sql, sessions.sql, state_meta.sql, schema_version.sql,
#   messages/NNNN.sql   (id-range chunks, rows ORDER BY id → append-mostly)
# Taken from a `.backup` snapshot with the WAL-safe sqlite3 only.
# Stored by scripts/backup-nightly.sh (restic). Never committed to git.
# Restore: scripts/restore-hermes-state.sh (DUMP_DIR=... to override).
set -euo pipefail
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
. "${REPO}/scripts/lib/backup-common.sh"
bk_active_host_or_exit "${REPO}" sync-hermes-state
SQLITE3="$(bk_sqlite3)"
LIVE_DB="${HOME}/.hermes/state.db"
SNAPSHOT="/tmp/state.db.snapshot.$$"
OUT_DIR="${OUT_DIR:-${BACKUP_STAGE}/hermes-data}"
if [[ ! -f "${LIVE_DB}" ]]; then
  echo "[sync-hermes-state] ${LIVE_DB} doesn't exist — skipping" >&2
  exit 0
fi
trap 'rm -f "${SNAPSHOT}"' EXIT
"${SQLITE3}" "${LIVE_DB}" ".backup ${SNAPSHOT}"
mkdir -p "${OUT_DIR}"
"${SQLITE3}" "${SNAPSHOT}" <<'SQL' > "${OUT_DIR}/schema.sql"
.mode list
SELECT sql || ';'
FROM sqlite_master
WHERE sql IS NOT NULL
  AND name NOT LIKE 'sqlite_%'
  AND name NOT LIKE 'messages_fts%'
  AND tbl_name IN ('sessions','messages','schema_version','state_meta')
ORDER BY (type = 'index'), name;
SQL
python3 "${REPO}/scripts/lib/chunked-sqlite-dump.py" \
    --db "${SNAPSHOT}" --table messages --pk-column id \
    --out-dir "${OUT_DIR}/messages"
for tbl in sessions state_meta schema_version; do
  python3 "${REPO}/scripts/lib/chunked-sqlite-dump.py" \
      --db "${SNAPSHOT}" --table "${tbl}" \
      --out-file "${OUT_DIR}/${tbl}.sql"
done
rm -f "${OUT_DIR}/state.sql"
bk_heartbeat sync-hermes-state
echo "[sync-hermes-state] $(date -u +%FT%TZ) staged $(du -sh "${OUT_DIR}" | cut -f1) at ${OUT_DIR}"
