#!/usr/bin/env bash
# Activate this host as the "active" host. Pulls the latest repo state,
# optionally restores Hermes state, Parley UI state, and the hindsight bank,
# starts services, claims ACTIVE_HOST, commits + pushes.
#
# Normal use: the previous active host has run handoff-out.sh, ACTIVE_HOST
# now says active_host= (empty), and you're activating this host.
#
# Forced takeover: if the previous active host died and can't run
# handoff-out, use --force. Acknowledges that any data the dead host
# wrote since its last sync-hermes / sync-hindsight cron is lost.
#
# Workflow:
#   1. git pull --ff-only (ensures we have the latest state).
#   2. Verify ACTIVE_HOST status — empty (normal handoff) or matches
#      this host (idempotent re-run). Refuse otherwise unless --force.
#   3. Stop local services so destructive restores cannot race writers.
#   4. (Default yes) restore-hermes-state.sh --yes to replay sessions/messages.
#   5. (Default yes) restore-parley-db.sh --yes to replay Parley titles,
#      pins, push subscriptions, unread/activity state, and UI message rows.
#   6. (Default yes) restore-hindsight-bank.sh --yes to replay the latest
#      per-table memory snapshot into local pg0. Skipped with --no-restore.
#   7. Start services in dependency order.
#   8. Wait for /health on the core trio (gateway / hindsight / parley
#      adapter).
#   9. Update ACTIVE_HOST to claim active.
#   10. git add / commit / push.
#
# Flags:
#   --force           Skip the active-host check (forced takeover).
#   --no-restore      Skip both Hermes and Hindsight restore steps.
#   --no-hermes-restore
#                     Skip the Hermes SQLite restore.
#   --no-parley-restore
#                     Skip the Parley supplemental SQLite restore.
#   --no-hindsight-restore
#                     Skip the Hindsight bank restore.
#   --yes             Skip the prompt before destructive steps.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
SENTINEL="${REPO}/ACTIVE_HOST"
HOSTNAME="$(hostname)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

FORCE=0
RESTORE_HERMES=1
RESTORE_PARLEY=1
RESTORE_HINDSIGHT=1
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --no-restore) RESTORE_HERMES=0; RESTORE_PARLEY=0; RESTORE_HINDSIGHT=0 ;;
    --no-hermes-restore) RESTORE_HERMES=0 ;;
    --no-parley-restore) RESTORE_PARLEY=0 ;;
    --no-hindsight-restore) RESTORE_HINDSIGHT=0 ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'; exit 0 ;;
    *) printf 'unknown flag: %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

# Color helpers
if [[ -t 1 ]]; then
  c_g=$'\033[32m'; c_r=$'\033[31m'; c_y=$'\033[33m'; c_0=$'\033[0m'
else c_g='' c_r='' c_y='' c_0=''; fi
ok()   { printf '%s✓%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s!%s %s\n' "$c_y" "$c_0" "$*"; }
die()  { printf '%s✗%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }
say()  { printf '→ %s\n' "$*"; }

# --- 1. Pull --------------------------------------------------------
say "git pull --ff-only..."
git -C "${REPO}" fetch origin
if ! git -C "${REPO}" merge --ff-only "@{u}"; then
  die "fast-forward merge failed. Resolve diverging history before activating."
fi

# --- 2. Sanity-check ACTIVE_HOST -----------------------------------
if [[ ! -f "${SENTINEL}" ]]; then
  warn "no ${SENTINEL} — treating as fresh init"
  active_host=""
else
  active_host="$(grep -E '^active_host=' "${SENTINEL}" | head -1 | cut -d= -f2-)"
fi

if [[ -n "${active_host}" && "${active_host}" != "${HOSTNAME}" ]]; then
  if (( FORCE == 0 )); then
    die "ACTIVE_HOST says active_host='${active_host}', not me (${HOSTNAME}).
     If '${active_host}' is dead, re-run with --force to take over.
     Forced takeover loses any writes the dead host made since its last
     sync-hermes / sync-hindsight cron (max ~15 min for the former, ~24h
     for the latter)."
  fi
  warn "FORCED takeover from '${active_host}' — last cron-synced state is the most we have"
fi

# --- 3. Stop local services before destructive restores -----------------
say "stopping local services before restore..."
for unit in whatsapp-bridge.service parley-audio.service parley.service \
            hermes-gateway.service hermes-dashboard.service; do
  if systemctl --user list-unit-files --no-legend "${unit}" 2>/dev/null | grep -q "${unit}"; then
    systemctl --user stop "${unit}" 2>/dev/null || true
  fi
done

# Hindsight restore works through the live embedded pg0 server, so don't stop
# hindsight-server here. restore-hindsight-bank.sh will start it if needed.

# --- 4. Restore Hermes state (default yes) ------------------------------
if (( RESTORE_HERMES )); then
  if [[ -f "${REPO}/hermes-data/schema.sql" ]]; then
    say "restoring Hermes sessions/messages from hermes-data/..."
    if (( ASSUME_YES )); then
      "${REPO}/scripts/restore-hermes-state.sh" --yes
    else
      "${REPO}/scripts/restore-hermes-state.sh"
    fi
  else
    warn "no hermes-data/schema.sql — skipping Hermes state restore (fresh install or git-crypt locked?)"
  fi
else
  say "skipping Hermes state restore"
fi

# --- 5. Restore Parley supplemental DB (default yes) ------------------
if (( RESTORE_PARLEY )); then
  if [[ -f "${REPO}/parley-data/parley.sql" ]]; then
    say "restoring Parley supplemental DB from parley-data/parley.sql..."
    if (( ASSUME_YES )); then
      "${REPO}/scripts/restore-parley-db.sh" --yes
    else
      "${REPO}/scripts/restore-parley-db.sh"
    fi
  else
    warn "no parley-data/parley.sql — skipping Parley DB restore (fresh install or git-crypt locked?)"
  fi
else
  say "skipping Parley supplemental DB restore"
fi

# --- 6. Restore hindsight bank (default yes) ----------------------------
if (( RESTORE_HINDSIGHT )); then
  if [[ -d "${REPO}/hindsight-data" ]] && find "${REPO}/hindsight-data" -mindepth 1 -name '*.sql' -print -quit | grep -q .; then
    say "restoring Hindsight bank from hindsight-data snapshot..."
    if (( ASSUME_YES )); then
      "${REPO}/scripts/restore-hindsight-bank.sh" --yes
    else
      "${REPO}/scripts/restore-hindsight-bank.sh"
    fi
  else
    warn "no hindsight-data/*.sql — skipping Hindsight restore (fresh install or git-crypt locked?)"
  fi
else
  say "skipping Hindsight bank restore"
fi

# --- 7. (Re)install symlinked units, enable, + start --------------------
# Some units are installed via symlink from the parley repo. If a
# previous handoff-out disabled those, the symlink may have been
# removed. Re-link before enable so the unit is loadable.
say "(re)installing symlinked units..."
SYSTEMD_USER="${HOME}/.config/systemd/user"
mkdir -p "${SYSTEMD_USER}"
ln -sfn "${HOME}/code/parley/audio-bridge/parley-audio.service" \
        "${SYSTEMD_USER}/parley-audio.service" 2>/dev/null || true
systemctl --user daemon-reload

say "ensuring repo-backed Hermes cron state is linked..."
mkdir -p "${HOME}/.hermes"
for entry in \
    "${HOME}/.hermes/cron:${REPO}/cron" \
    "${HOME}/.hermes/scripts:${REPO}/hermes-runtime-scripts"; do
  live="${entry%%:*}"
  target="${entry##*:}"
  if [[ -L "${live}" ]]; then
    :
  elif [[ -e "${live}" ]]; then
    backup="${live}.pre-handoff.$(date -u +%Y%m%dT%H%M%SZ)"
    mv "${live}" "${backup}"
    warn "moved existing ${live} to ${backup}"
    ln -s "${target}" "${live}"
  elif [[ -e "${target}" ]]; then
    ln -s "${target}" "${live}"
  fi
done

say "ensuring OS crontab entries exist..."
add_cron() {
  local pattern="$1" line="$2"
  if crontab -l 2>/dev/null | grep -qF "${pattern}"; then
    return
  fi
  (crontab -l 2>/dev/null || true; echo "${line}") | crontab -
  ok "added cron: ${pattern}"
}
mkdir -p "${HOME}/.hermes/logs"
add_cron "doctor.sh"                  "*/10 * * * * ${REPO}/scripts/doctor.sh >> ${HOME}/.hermes/logs/doctor.log 2>&1"
add_cron "sync-hermes.sh"             "*/15 * * * * ${REPO}/scripts/sync-hermes.sh >> ${HOME}/.hermes/logs/sync-hermes.log 2>&1"
add_cron "sync-cc-history.sh"         "*/15 * * * * ${REPO}/scripts/sync-cc-history.sh >> ${HOME}/.hermes/logs/sync-cc-history.log 2>&1"
add_cron "sync-hermes-state.sh"       "44 3 * * * ${REPO}/scripts/sync-hermes-state.sh >> ${HOME}/.hermes/logs/sync-hermes-state.log 2>&1"
add_cron "sync-parley-db.sh"        "49 3 * * * ${REPO}/scripts/sync-parley-db.sh >> ${HOME}/.hermes/logs/sync-parley-db.log 2>&1"
add_cron "sync-hindsight-bank.sh"     "33 3 * * * ${REPO}/scripts/sync-hindsight-bank.sh >> ${HOME}/.hermes/logs/sync-hindsight-bank.log 2>&1"
add_cron "prune-claude-cc-history.sh" "44 4 * * * ${REPO}/scripts/prune-claude-cc-history.sh >> ${HOME}/.hermes/logs/prune-claude-cc-history.log 2>&1"

say "enabling + starting services on ${HOSTNAME}..."

# Hindsight first (others depend on it for memory tools).
if systemctl --user list-unit-files --no-legend hindsight-server.service 2>/dev/null | grep -q hindsight-server; then
  systemctl --user enable hindsight-server.service 2>/dev/null || true
  systemctl --user start hindsight-server.service
  ok "started hindsight-server.service"
fi

for unit in hermes-gateway.service hermes-dashboard.service \
            parley.service parley-audio.service whatsapp-bridge.service; do
  if systemctl --user list-unit-files --no-legend "${unit}" 2>/dev/null | grep -q "${unit}"; then
    systemctl --user enable "${unit}" 2>/dev/null || true
    systemctl --user start "${unit}" 2>/dev/null && ok "started ${unit}" || warn "failed to start ${unit} — check journalctl"
  fi
done

# --- 8. Wait for /health on the core trio -------------------------------
say "waiting for /health endpoints..."
for endpoint in \
    "hindsight 8765" \
    "gateway   8642" \
    "parley  8645"; do
  read -r name port <<< "${endpoint}"
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      ok "${name} healthy on :${port}"
      break
    fi
    sleep 1
  done
done

# --- 9. Quick state sanity ----------------------------------------------
if [[ -f "${HOME}/.hermes/state.db" ]] && command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "${HOME}/.hermes/state.db" "SELECT '[state] ' || (SELECT count(*) FROM sessions) || ' sessions, ' || (SELECT count(*) FROM messages) || ' messages';" || true
fi

if command -v "${REPO}/scripts/handoff-smoke-test.sh" >/dev/null 2>&1; then
  "${REPO}/scripts/handoff-smoke-test.sh" || warn "handoff smoke test reported warnings"
elif [[ -x "${REPO}/scripts/handoff-smoke-test.sh" ]]; then
  "${REPO}/scripts/handoff-smoke-test.sh" || warn "handoff smoke test reported warnings"
fi

# --- 10. Update ACTIVE_HOST to claim active -----------------------------
say "claiming active_host=${HOSTNAME} in ${SENTINEL}..."
{
  cat <<HEAD
# Multi-host coordination sentinel — DO NOT EDIT BY HAND.
# Managed by scripts/handoff-out.sh and scripts/handoff-in.sh.
# See HANDOFF.md for the procedure.
#
# active_host: hostname of the host currently running services and
#   mutating crons. Empty string means "no host is active right now"
#   (i.e. we're between a handoff-out and a handoff-in).
# active_since: ISO-8601 UTC timestamp of when the current active host
#   claimed activity.
# last_transition: human-readable note about the last handoff event.

active_host=${HOSTNAME}
active_since=${NOW}
HEAD
  if (( FORCE )); then
    echo "last_transition=handoff-in (--force) by ${HOSTNAME} at ${NOW} (took over from '${active_host}')"
  else
    echo "last_transition=handoff-in by ${HOSTNAME} at ${NOW}"
  fi
} > "${SENTINEL}"

# --- 11. Commit + push --------------------------------------------------
git -C "${REPO}" add ACTIVE_HOST
git -C "${REPO}" commit -m "handoff-in: ${HOSTNAME} → active (${NOW})" || warn "nothing to commit"
git -C "${REPO}" push || die "git push failed — handoff is ONLY committed locally"

ok "handoff-in complete on ${HOSTNAME}"
echo
echo "Sanity checks you may want to run:"
echo "    curl http://127.0.0.1:8642/health    # hermes gateway"
echo "    curl http://127.0.0.1:8645/health    # parley adapter"
echo "    curl http://127.0.0.1:8765/health    # hindsight"
echo "    journalctl --user -u hermes-gateway.service -n 30"
