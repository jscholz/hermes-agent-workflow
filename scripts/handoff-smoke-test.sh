#!/usr/bin/env bash
# Quick post-handoff sanity checks. This is intentionally read-only: it
# verifies restored state and service health without writing sentinel memories
# that would dirty the just-migrated host.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
HERMES="${HOME}/.hermes"

warns=0
say() { printf '→ %s\n' "$*"; }
ok() { printf '✓ %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; warns=$((warns + 1)); }

export PATH="${HOME}/.local/sqlite-3.50.2/bin:${HOME}/miniconda3/bin:${PATH}"

health() {
  local name="$1" port="$2"
  if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
    ok "${name} health on :${port}"
  else
    warn "${name} health failed on :${port}"
  fi
}

say "checking service health..."
health "hindsight" 8765
health "parley adapter" 8645
health "hermes gateway" 8642

say "checking Hermes SQLite restore..."
if [[ -f "${HERMES}/state.db" ]] && command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "${HERMES}/state.db" "SELECT 'sessions=' || (SELECT count(*) FROM sessions) || ' messages=' || (SELECT count(*) FROM messages);" \
    || warn "failed to query ${HERMES}/state.db"
else
  warn "missing sqlite3 or ${HERMES}/state.db"
fi

say "checking Parley supplemental DB restore..."
if [[ -f "${HERMES}/parley.db" ]] && command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "${HERMES}/parley.db" "SELECT 'parley_messages=' || (SELECT count(*) FROM msg_links) || ' titles=' || (SELECT count(*) FROM conversation_titles) || ' pins=' || (SELECT count(*) FROM pins) || ' push_subscriptions=' || (SELECT count(*) FROM push_subscriptions);" \
    || warn "failed to query ${HERMES}/parley.db"
else
  warn "missing sqlite3 or ${HERMES}/parley.db"
fi

say "checking Hermes cron state..."
if [[ -L "${HERMES}/cron" && -f "${HERMES}/cron/jobs.json" ]]; then
  ok "cron jobs file linked at ${HERMES}/cron/jobs.json"
else
  warn "missing linked ${HERMES}/cron/jobs.json"
fi
if [[ -L "${HERMES}/scripts" ]]; then
  ok "runtime scripts linked at ${HERMES}/scripts"
else
  warn "missing linked ${HERMES}/scripts"
fi
for pattern in doctor.sh sync-hermes.sh sync-cc-history.sh sync-hermes-state.sh sync-parley-db.sh sync-hindsight-bank.sh prune-claude-cc-history.sh; do
  if crontab -l 2>/dev/null | grep -qF "${pattern}"; then
    ok "OS cron installed: ${pattern}"
  else
    warn "OS cron missing: ${pattern}"
  fi
done

say "checking Hindsight table counts..."
PGBIN="${HOME}/.pg0/installation/18.1.0/bin"
if [[ -x "${PGBIN}/psql" ]]; then
  export PGPASSWORD="hindsight"
  "${PGBIN}/psql" \
      --host=127.0.0.1 --port=5432 \
      --username=hindsight --dbname=hindsight \
      --tuples-only --no-align \
      -c "SELECT relname || '=' || n_live_tup FROM pg_stat_user_tables WHERE n_live_tup > 0 ORDER BY n_live_tup DESC LIMIT 12;" \
    || warn "failed to query Hindsight pg0 counts"
else
  warn "missing ${PGBIN}/psql"
fi

say "checking active-host sentinel..."
if [[ -f "${REPO}/ACTIVE_HOST" ]]; then
  grep -E '^(active_host|active_since|last_transition)=' "${REPO}/ACTIVE_HOST" || true
else
  warn "missing ${REPO}/ACTIVE_HOST"
fi

if (( warns > 0 )); then
  warn "smoke test finished with ${warns} warning(s)"
  exit 1
fi

ok "smoke test clean"
