#!/usr/bin/env bash
# Restore ~/.hermes/parley.db from parley-data/parley.sql.
#
# DESTRUCTIVE: replaces ${HOME}/.hermes/parley.db. Requires Hermes gateway
# and Parley proxy/audio services to be stopped because they read/write this
# DB and its WAL.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
DUMP="${REPO}/parley-data/parley.sql"
LIVE_DB="${HOME}/.hermes/parley.db"
ASSUME_YES=0

export PATH="${HOME}/.local/sqlite-3.50.2/bin:${HOME}/miniconda3/bin:${PATH}"
SQLITE3="$(command -v sqlite3 || true)"
if [[ -z "${SQLITE3}" ]]; then
  echo "[restore-parley-db] sqlite3 not found — install sqlite3 or provide ~/.local/sqlite-3.50.2/bin/sqlite3" >&2
  exit 1
fi

for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'; exit 0 ;;
    *) printf 'unknown flag: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if [[ -t 1 ]]; then c_y=$'\033[33m'; c_g=$'\033[32m'; c_r=$'\033[31m'; c_0=$'\033[0m'
else c_y=''; c_g=''; c_r=''; c_0=''; fi
ok()   { printf '%s✓%s %s\n' "$c_g" "$c_0" "$*"; }
die()  { printf '%s✗%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }
say()  { printf '→ %s\n' "$*"; }

if [[ ! -f "${DUMP}" ]]; then
  die "no dump at ${DUMP}.
     Run scripts/sync-parley-db.sh on the previous active host first
     (or unlock git-crypt: git-crypt unlock <key>)."
fi

for unit in hermes-gateway.service parley.service parley-audio.service; do
  if systemctl --user is-active --quiet "${unit}"; then
    die "${unit} is active. Stop it before restoring:
       systemctl --user stop hermes-gateway.service parley.service parley-audio.service"
  fi
done

if (( ! ASSUME_YES )); then
  cat <<EOF
${c_y}This will REPLACE${c_0} ${LIVE_DB} with the contents of:
  ${DUMP}  ($(du -h "${DUMP}" | cut -f1))

Existing Parley UI state on this host will be wiped. This includes
conversation titles, pins, push subscriptions, unread/activity state,
VAPID keys, and Parley's UI-facing message rows.

Continue? [y/N]
EOF
  read -r reply
  if [[ "${reply}" != "y" && "${reply}" != "Y" ]]; then
    die "aborted"
  fi
fi

mkdir -p "$(dirname "${LIVE_DB}")" "${HOME}/.hermes/backups"
if [[ -f "${LIVE_DB}" ]]; then
  BACKUP="${HOME}/.hermes/backups/parley.db.pre-restore.$(date +%Y%m%d-%H%M%S)"
  cp -a "${LIVE_DB}" "${BACKUP}"
  ok "backed up existing parley.db to ${BACKUP}"
fi

say "wiping existing parley.db..."
rm -f "${LIVE_DB}" "${LIVE_DB}-shm" "${LIVE_DB}-wal"

say "replaying ${DUMP}..."
"${SQLITE3}" "${LIVE_DB}" < "${DUMP}"
"${SQLITE3}" "${LIVE_DB}" "PRAGMA integrity_check;" | grep -qx ok
ok "restore complete"

"${SQLITE3}" "${LIVE_DB}" "SELECT
  (SELECT count(*) FROM msg_links) || ' messages, ' ||
  (SELECT count(*) FROM conversation_titles) || ' titles, ' ||
  (SELECT count(*) FROM pins) || ' pins, ' ||
  (SELECT count(*) FROM push_subscriptions) || ' push subscriptions';"
