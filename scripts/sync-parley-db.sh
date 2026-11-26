#!/usr/bin/env bash
# Dump ~/.hermes/parley.db (pins, unread pointers, activity, push subs,
# msg_links …) to the backup stage: ~/.backups/stage/parley-data/parley.sql
# — one plain `.dump` from a `.backup` snapshot, WAL-safe sqlite3 only.
# Stored by scripts/backup-nightly.sh (restic). Never committed to git.
# Restore: scripts/restore-parley-db.sh (DUMP_DIR=... to override).
set -euo pipefail
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
. "${REPO}/scripts/lib/backup-common.sh"
bk_active_host_or_exit "${REPO}" sync-parley-db
SQLITE3="$(bk_sqlite3)"
LIVE_DB="${HOME}/.hermes/parley.db"
SNAPSHOT="/tmp/parley.db.snapshot.$$"
OUT_DIR="${OUT_DIR:-${BACKUP_STAGE}/parley-data}"
if [[ ! -f "${LIVE_DB}" ]]; then
  echo "[sync-parley-db] ${LIVE_DB} doesn't exist — skipping" >&2
  exit 0
fi
trap 'rm -f "${SNAPSHOT}"' EXIT
"${SQLITE3}" "${LIVE_DB}" ".backup ${SNAPSHOT}"
mkdir -p "${OUT_DIR}"
"${SQLITE3}" "${SNAPSHOT}" ".dump" > "${OUT_DIR}/.parley.sql.tmp"
mv "${OUT_DIR}/.parley.sql.tmp" "${OUT_DIR}/parley.sql"
rm -rf "${OUT_DIR}/parley.sql.parts"   # 80 MB split layout from the git-based version
bk_heartbeat sync-parley-db
echo "[sync-parley-db] $(date -u +%FT%TZ) staged $(du -h "${OUT_DIR}/parley.sql" | cut -f1) at ${OUT_DIR}"
