#!/usr/bin/env bash
# Shared pieces for the nightly backup (scripts/backup-nightly.sh).
#
# Dumps are staged OUTSIDE the repo and stored by restic (content-defined
# dedup + encryption + retention). Nothing under BACKUP_STAGE is ever
# committed to git: git-crypt'd dumps cannot be deltified or compressed,
# so each nightly commit stores the whole dump again — see docs/BACKUPS.md.
#
# Source from a script: `. "$(dirname "$0")/lib/backup-common.sh"`

BACKUP_HOME="${BACKUP_HOME:-$HOME/.backups}"
BACKUP_STAGE="${BACKUP_STAGE:-$BACKUP_HOME/stage}"
BACKUP_LOGS="${BACKUP_LOGS:-${HERMES_HOME:-$HOME/.hermes}/logs}"

# Only a sqlite3 without the WAL-reset bug (https://sqlite.org/wal.html#walresetbug)
# may open the LIVE databases: a vulnerable build can unlink the gateway's
# WAL and take it down. Put a fixed build (3.51.3+) at ~/.local/bin/sqlite3.
bk_sqlite3() {
  local bin="${HOME}/.local/bin/sqlite3"
  [[ -x "$bin" ]] || bin="$(command -v sqlite3 || true)"
  [[ -n "$bin" ]] || { echo "[backup] sqlite3 not found" >&2; return 1; }
  local v; v="$("$bin" --version 2>/dev/null | awk '{print $1}')"
  python3 - "$v" <<'PY' || { echo "[backup] REFUSING $bin ($v): WAL-reset bug; install sqlite 3.51.3+ at ~/.local/bin/sqlite3 (docs/BACKUPS.md)" >&2; return 1; }
import sys
v = tuple(int(x) for x in (sys.argv[1] or "0").split(".")[:3])
while len(v) < 3: v += (0,)
ok = v < (3,7,0) or v >= (3,51,3) or (3,50,7) <= v < (3,51,0) or (3,44,6) <= v < (3,45,0)
sys.exit(0 if ok else 1)
PY
  echo "$bin"
}

# Only the active host dumps live databases. Writes a standby marker so
# the health script can tell "standby" from "cron dead".
bk_active_host_or_exit() {
  local repo="$1" name="$2"
  [[ -f "${repo}/ACTIVE_HOST" ]] || return 0
  local active; active=$(grep -E '^active_host=' "${repo}/ACTIVE_HOST" | head -1 | cut -d= -f2-)
  if [[ "${active}" != "$(hostname)" ]]; then
    mkdir -p "${BACKUP_LOGS}"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) standby (active=${active:-<unset>})" > "${BACKUP_LOGS}/${name}.standby" 2>/dev/null || true
    exit 0
  fi
}

bk_heartbeat() { mkdir -p "${BACKUP_LOGS}"; date -u +%Y-%m-%dT%H:%M:%SZ > "${BACKUP_LOGS}/$1.heartbeat" 2>/dev/null || true; }
bk_log() { echo "[$(date -u +%FT%TZ)] $*"; }
