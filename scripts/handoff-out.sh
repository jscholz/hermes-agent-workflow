#!/usr/bin/env bash
# Hand off "active host" status FROM this host. Stops services, runs a
# final sync to capture any drift, clears ACTIVE_HOST, commits + pushes.
#
# After this completes, the repo says "no host is active right now."
# Run handoff-in.sh on the host you're activating next.
#
# Refuses to run unless this host is currently the active one. Use
# handoff-in.sh --force on the OTHER host if the active host has died
# and can't be reached.
#
# Workflow:
#   1. Verify ACTIVE_HOST names this host.
#   2. Stop hermes services (gateway, dashboard, hindsight-server) and
#      any parley units that exist (parley, parley-audio,
#      whatsapp-bridge).
#   3. Run backup-nightly.sh for the final restic snapshot (BEFORE
#      hindsight-server stops so pg0 is still alive — wait, hindsight
#      is already stopped, so we'd want to start, dump, stop. Tricky.
#      Approach: stop OTHER services first, dump while hindsight is
#      still up, then stop hindsight).
#      (one run also dumps the SQLite sessions/messages and Parley UI DB).
#   6. Run sync-hermes.sh to commit any repo-backed drift.
#   7. Update ACTIVE_HOST to "no host active" with a transition note.
#   8. git add ACTIVE_HOST; git commit; git push.
#
# Pre-emptive sanity: refuses if working tree is dirty (other than
# ACTIVE_HOST itself), to avoid commingling unrelated changes with the
# handoff commit.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
SENTINEL="${REPO}/ACTIVE_HOST"
HOSTNAME="$(hostname)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Color helpers
if [[ -t 1 ]]; then
  c_g=$'\033[32m'; c_r=$'\033[31m'; c_y=$'\033[33m'; c_0=$'\033[0m'
else c_g='' c_r='' c_y='' c_0=''; fi
ok()   { printf '%s✓%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s!%s %s\n' "$c_y" "$c_0" "$*"; }
die()  { printf '%s✗%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }
say()  { printf '→ %s\n' "$*"; }

# --- 1. Verify we're the active host -----------------------------------
if [[ ! -f "${SENTINEL}" ]]; then
  die "no ${SENTINEL} — initialize it first or run handoff-in.sh"
fi
active_host="$(grep -E '^active_host=' "${SENTINEL}" | head -1 | cut -d= -f2-)"
if [[ "${active_host}" != "${HOSTNAME}" ]]; then
  die "I am ${HOSTNAME}, but ACTIVE_HOST says active_host='${active_host:-<empty>}'.
     Only the active host can run handoff-out. If the previous active host
     has died, run 'handoff-in.sh --force' on the host you want to activate."
fi

# --- 2. Refuse on dirty tree (besides ACTIVE_HOST) ---------------------
dirty="$(git -C "${REPO}" status --porcelain | grep -v ' ACTIVE_HOST$' | grep -v '?? ACTIVE_HOST$' || true)"
if [[ -n "${dirty}" ]]; then
  die "${REPO} working tree is dirty:
$(printf '%s\n' "${dirty}" | sed 's/^/         /')
     Commit, stash, or discard before handing off."
fi

# --- 3. Stop + disable services in dependency-friendly order -----------
# `disable` removes the wants/ link so the unit won't auto-start on
# next reboot. For unit files installed via SYMLINK (parley-audio
# from the parley repo), disable ALSO removes the unit symlink
# itself, leaving the unit `not-found` until handoff-in re-links it.
# That's fine — handoff-in always re-installs symlinked units.
say "stopping + disabling services on ${HOSTNAME}..."

# Top-level services first (they hold connections to hindsight).
for unit in whatsapp-bridge.service parley-audio.service parley.service \
            hermes-gateway.service hermes-dashboard.service; do
  if systemctl --user list-unit-files --no-legend "${unit}" 2>/dev/null | grep -q "${unit}"; then
    if systemctl --user is-active --quiet "${unit}"; then
      systemctl --user stop "${unit}"
      ok "stopped ${unit}"
    fi
    systemctl --user disable "${unit}" 2>/dev/null && ok "disabled ${unit}" || true
  fi
done

# Capture final SQLite state after user-facing writers are stopped. The
# online-backup path is safe while live, but doing it after gateway/Parley
# stop gives the handoff a crisp "no more messages after this point" boundary.
# One backup run: dumps all three (hindsight-server is still up at this
# point; the dump script exits cleanly if it is not), snapshots them into
# the local restic repo and copies to BACKUP_CLOUD_REPO — which is what the
# incoming host restores from (handoff-in.sh). See docs/BACKUPS.md.
say "taking the final backup (restic local + cloud)..."
"${REPO}/scripts/backup-nightly.sh" || warn "backup-nightly.sh non-zero — the incoming host may restore a stale snapshot"

# Now stop + disable hindsight (last because pg0 is embedded).
if systemctl --user is-active --quiet hindsight-server.service; then
  systemctl --user stop hindsight-server.service
  ok "stopped hindsight-server.service"
fi
systemctl --user disable hindsight-server.service 2>/dev/null && ok "disabled hindsight-server.service" || true

# --- 4. Final sync-hermes to commit repo-backed drift -------------------
say "running sync-hermes.sh for final state capture..."
"${REPO}/scripts/sync-hermes.sh" || warn "sync-hermes.sh non-zero — proceeding anyway"

# --- 5. Clear ACTIVE_HOST with a transition note -----------------------
say "clearing active_host in ${SENTINEL}..."
prev_since="$(grep -E '^active_since=' "${SENTINEL}" | head -1 | cut -d= -f2- || echo unknown)"
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

active_host=
active_since=
last_transition=handoff-out by ${HOSTNAME} at ${NOW} (was active since ${prev_since})
HEAD
} > "${SENTINEL}"

# --- 6. Commit + push --------------------------------------------------
git -C "${REPO}" add ACTIVE_HOST
# sync-hermes.sh may have staged other files (systemd units, sessions);
# those are fine to bundle into the same commit.
git -C "${REPO}" commit -m "handoff-out: ${HOSTNAME} → standby (${NOW})" || warn "nothing to commit"
git -C "${REPO}" push || die "git push failed — RESOLVE BEFORE SWITCHING HOSTS"

ok "handoff-out complete on ${HOSTNAME}"
echo
echo "Next step: on the host you're activating, run:"
echo "    cd ${REPO} && scripts/handoff-in.sh"
