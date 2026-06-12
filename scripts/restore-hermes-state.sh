#!/usr/bin/env bash
# Restore ~/.hermes/state.db from the chunked dump under hermes-data/.
#
# Use case: bringing up a host as the new active. Replays sessions +
# messages from the active-host's last sync. FTS indexes are rebuilt
# on restore (cheaper to rebuild than to version).
#
# Layout consumed:
#   hermes-data/schema.sql          — CREATE TABLE/INDEX for the 4 tables
#   hermes-data/sessions.sql        — small full dump
#   hermes-data/state_meta.sql      — small full dump
#   hermes-data/schema_version.sql  — small full dump
#   hermes-data/messages/NNNN.sql   — chunked INSERTs (alpha sort = id order)
#
# Replay order: schema.sql first (tables before indexes), then the data
# files. messages chunks are catted in alpha order (= id-range order).
#
# DESTRUCTIVE: replaces ${HOME}/.hermes/state.db. Requires hermes-gateway
# to be stopped (live writers would race with the replay). Refuses to
# run if gateway is active.
#
# Flags:
#   --yes             Skip the confirmation prompt.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
DUMP_DIR="${REPO}/hermes-data"
LIVE_DB="${HOME}/.hermes/state.db"
ASSUME_YES=0

export PATH="${HOME}/.local/sqlite-3.50.2/bin:${HOME}/miniconda3/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
SQLITE3="$(command -v sqlite3 || true)"
if [[ -z "${SQLITE3}" ]]; then
  echo "[restore-hermes-state] sqlite3 not found — install sqlite3 or add it to PATH" >&2
  exit 1
fi

for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'; exit 0 ;;
    *) printf 'unknown flag: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# UI helpers
if [[ -t 1 ]]; then c_y=$'\033[33m'; c_g=$'\033[32m'; c_r=$'\033[31m'; c_0=$'\033[0m'
else c_y=''; c_g=''; c_r=''; c_0=''; fi
ok()   { printf '%s✓%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s!%s %s\n' "$c_y" "$c_0" "$*"; }
die()  { printf '%s✗%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }
say()  { printf '→ %s\n' "$*"; }

# --- Pre-flight ---------------------------------------------------------
if [[ ! -f "${DUMP_DIR}/schema.sql" ]]; then
  die "no schema dump at ${DUMP_DIR}/schema.sql.
     Run scripts/sync-hermes-state.sh on the previous active host first
     (or unlock git-crypt: git-crypt unlock <key>)."
fi

# Verify the dumps aren't still git-crypt-encrypted (\0GITCRYPT prefix).
if [[ "$(head -c 9 "${DUMP_DIR}/schema.sql" | od -An -c | tr -d ' ')" == *"GITCRYPT"* ]]; then
  die "${DUMP_DIR}/schema.sql is still git-crypt-encrypted. Run: git-crypt unlock <key>"
fi

# Refuse if gateway is running (would race the replay).
if systemctl --user is-active --quiet hermes-gateway.service; then
  die "hermes-gateway.service is active. Stop it before restoring:
       systemctl --user stop hermes-gateway.service"
fi

# --- Confirm ------------------------------------------------------------
if (( ! ASSUME_YES )); then
  cat <<EOF
${c_y}This will REPLACE${c_0} ${LIVE_DB} with the contents of:
  ${DUMP_DIR}/  ($(du -sh "${DUMP_DIR}" | cut -f1))

Existing sessions and messages on this host will be wiped. The dump's
sessions and messages take their place. FTS indexes will be rebuilt
from the new content.

Continue? [y/N]
EOF
  read -r reply
  if [[ "${reply}" != "y" && "${reply}" != "Y" ]]; then
    die "aborted"
  fi
fi

# --- Backup the existing DB before overwriting --------------------------
if [[ -f "${LIVE_DB}" ]]; then
  BACKUP="${LIVE_DB}.pre-restore.$(date +%Y%m%d-%H%M%S)"
  cp -a "${LIVE_DB}" "${BACKUP}"
  ok "backed up existing state.db to ${BACKUP}"
fi

# --- Wipe + replay ------------------------------------------------------
say "wiping existing state.db..."
rm -f "${LIVE_DB}" "${LIVE_DB}-shm" "${LIVE_DB}-wal"

# --- Apply schema, then replay data -------------------------------------
# Schema first (tables before indexes). Then the data files in a single
# transaction: small tables, then messages chunks in alpha (= id-range)
# order. Explicit-column INSERTs tolerate the chunk ordering.
say "applying schema..."
"${SQLITE3}" "${LIVE_DB}" < "${DUMP_DIR}/schema.sql"

say "replaying data..."
{
  echo "BEGIN;"
  for f in sessions state_meta schema_version; do
    [[ -f "${DUMP_DIR}/${f}.sql" ]] && cat "${DUMP_DIR}/${f}.sql"
  done
  if [[ -d "${DUMP_DIR}/messages" ]]; then
    find "${DUMP_DIR}/messages" -maxdepth 1 -name '*.sql' -type f \
      | LC_ALL=C sort | while read -r chunk; do cat "${chunk}"; done
  fi
  echo "COMMIT;"
} | "${SQLITE3}" "${LIVE_DB}"
ok "data tables loaded"

# --- Rebuild FTS indexes ------------------------------------------------
# The dump skipped messages_fts* (derivable). The FTS tables on this
# schema are CONTENTLESS standalone fts5 (no content='messages' link),
# so they don't auto-rebuild from messages — we have to populate them
# manually. rowid is aligned with messages.id so the app's existing FTS
# lookup paths keep working.
#
# CRITICAL: the SYNC TRIGGERS must be recreated too, with the exact
# names/formula from hermes_state.py (FTS_SQL / FTS_TRIGRAM_SQL).
# A restore that rebuilds only the tables leaves the index silently
# FROZEN at restore time — new messages never get indexed (this bit us:
# search was dead 2026-05-26→06-12). hermes_state.py now self-heals a
# trigger-less DB at gateway startup, but the restore should produce a
# correct DB on its own.
say "rebuilding FTS indexes..."
"${SQLITE3}" "${LIVE_DB}" <<'SQL'
-- Drop any FTS leftovers from a prior partial restore (defensive).
DROP TABLE IF EXISTS messages_fts;
DROP TABLE IF EXISTS messages_fts_trigram;
DROP TRIGGER IF EXISTS messages_fts_insert;
DROP TRIGGER IF EXISTS messages_fts_delete;
DROP TRIGGER IF EXISTS messages_fts_update;
DROP TRIGGER IF EXISTS messages_fts_trigram_insert;
DROP TRIGGER IF EXISTS messages_fts_trigram_delete;
DROP TRIGGER IF EXISTS messages_fts_trigram_update;

-- Standard FTS5 (token-based) — column is 'content'
CREATE VIRTUAL TABLE messages_fts USING fts5(content);

-- Trigram FTS5 (substring-search support)
CREATE VIRTUAL TABLE messages_fts_trigram USING fts5(content, tokenize='trigram');

-- Sync triggers (verbatim from hermes_state.py FTS_SQL / FTS_TRIGRAM_SQL).
CREATE TRIGGER messages_fts_insert AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, content) VALUES (
        new.id,
        COALESCE(new.content, '') || ' ' || COALESCE(new.tool_name, '') || ' ' || COALESCE(new.tool_calls, '')
    );
END;
CREATE TRIGGER messages_fts_delete AFTER DELETE ON messages BEGIN
    DELETE FROM messages_fts WHERE rowid = old.id;
END;
CREATE TRIGGER messages_fts_update AFTER UPDATE ON messages BEGIN
    DELETE FROM messages_fts WHERE rowid = old.id;
    INSERT INTO messages_fts(rowid, content) VALUES (
        new.id,
        COALESCE(new.content, '') || ' ' || COALESCE(new.tool_name, '') || ' ' || COALESCE(new.tool_calls, '')
    );
END;
CREATE TRIGGER messages_fts_trigram_insert AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts_trigram(rowid, content) VALUES (
        new.id,
        COALESCE(new.content, '') || ' ' || COALESCE(new.tool_name, '') || ' ' || COALESCE(new.tool_calls, '')
    );
END;
CREATE TRIGGER messages_fts_trigram_delete AFTER DELETE ON messages BEGIN
    DELETE FROM messages_fts_trigram WHERE rowid = old.id;
END;
CREATE TRIGGER messages_fts_trigram_update AFTER UPDATE ON messages BEGIN
    DELETE FROM messages_fts_trigram WHERE rowid = old.id;
    INSERT INTO messages_fts_trigram(rowid, content) VALUES (
        new.id,
        COALESCE(new.content, '') || ' ' || COALESCE(new.tool_name, '') || ' ' || COALESCE(new.tool_calls, '')
    );
END;

-- Backfill with the same formula the triggers use (content + tool_name +
-- tool_calls — tool frames are searchable too, matching hermes_state.py
-- v11 backfill exactly).
INSERT INTO messages_fts(rowid, content)
  SELECT id, COALESCE(content, '') || ' ' || COALESCE(tool_name, '') || ' ' || COALESCE(tool_calls, '')
  FROM messages;
INSERT INTO messages_fts_trigram(rowid, content)
  SELECT id, COALESCE(content, '') || ' ' || COALESCE(tool_name, '') || ' ' || COALESCE(tool_calls, '')
  FROM messages;
SQL

# Verify the triggers actually landed — a restore that produces a
# frozen index should fail loudly, not ship.
trigger_count=$("${SQLITE3}" "${LIVE_DB}" \
  "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'messages_fts%';")
if [[ "${trigger_count}" != "6" ]]; then
  die "FTS rebuild incomplete: expected 6 sync triggers, found ${trigger_count}"
fi

ok "restore complete"
echo
echo "Sanity:"
"${SQLITE3}" "${LIVE_DB}" "SELECT
    (SELECT count(*) FROM sessions) || ' sessions, ' ||
    (SELECT count(*) FROM messages) || ' messages';"
echo
echo "Next: start gateway (systemctl --user start hermes-gateway.service)"
