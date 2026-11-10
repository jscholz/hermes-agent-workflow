#!/usr/bin/env bash
# Snapshot ~/.hermes/parley.db to parley-data/parley.sql.
#
# This is the Parley supplemental UI store: conversation_titles, pins,
# push subscriptions/preferences, unread/activity state, VAPID keys, and the
# UI-facing message rows. It is required for a host migration to reproduce the
# Parley drawer and notification state exactly.
#
# Strategy: sqlite3 online .backup of the live WAL-backed DB, then .dump the
# snapshot to plaintext SQL. parley-data/** is git-crypt encrypted.
set -euo pipefail

export PATH="${HOME}/.local/sqlite-3.50.2/bin:${HOME}/miniconda3/bin:${PATH}"
SQLITE3="$(command -v sqlite3 || true)"
if [[ -z "${SQLITE3}" ]]; then
  echo "[sync-parley-db] sqlite3 not found — install sqlite3 or provide ~/.local/sqlite-3.50.2/bin/sqlite3" >&2
  exit 1
fi

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
LIVE_DB="${HOME}/.hermes/parley.db"
SNAPSHOT="/tmp/parley.db.snapshot.$$"
OUT_DIR="${REPO}/parley-data"
OUT_FILE="${OUT_DIR}/parley.sql"

# Only the active host writes this dump. Both hosts dumping creates merge
# conflicts and can resurrect stale Parley UI state.
if [[ -f "${REPO}/ACTIVE_HOST" ]]; then
  active_host=$(grep -E '^active_host=' "${REPO}/ACTIVE_HOST" | head -1 | cut -d= -f2-)
  if [[ "${active_host}" != "$(hostname)" ]]; then
    mkdir -p "${HOME}/.hermes/logs"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) standby (active=${active_host:-<unset>})" \
      > "${HOME}/.hermes/logs/sync-parley-db.standby" 2>/dev/null || true
    exit 0
  fi
fi

if [[ ! -f "${LIVE_DB}" ]]; then
  echo "[sync-parley-db] ${LIVE_DB} doesn't exist — skipping" >&2
  exit 0
fi

trap 'rm -f "${SNAPSHOT}" "${SNAPSHOT}.dump"' EXIT

"${SQLITE3}" "${LIVE_DB}" ".backup ${SNAPSHOT}"
mkdir -p "${OUT_DIR}"
"${SQLITE3}" "${SNAPSHOT}" ".dump" > "${OUT_FILE}"

mkdir -p "${HOME}/.hermes/logs"
date -u +%Y-%m-%dT%H:%M:%SZ > "${HOME}/.hermes/logs/sync-parley-db.heartbeat" 2>/dev/null || true

cd "${REPO}"
git add "${OUT_FILE}"

if git diff --cached --quiet; then
  exit 0
fi

bytes=$(stat -c %s "${OUT_FILE}")
git commit -m "parley-db: snapshot $(date -u +%Y-%m-%dT%H:%MZ) (${bytes}b)" >/dev/null

if ! git push origin main 2>/dev/null; then
  echo "[sync-parley-db] push failed; will retry next cycle" >&2
  exit 0
fi
