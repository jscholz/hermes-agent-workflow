#!/usr/bin/env bash
# hermes-agent-workflow / scripts / apply-patches.sh
#
# Apply the workflow's hermes-agent patches on top of a clean checkout
# of upstream NousResearch/hermes-agent. Idempotent — re-runs detect a
# matching applied state via a hash of the patch set and exit early.
#
# WHY a separate apply step rather than baking patches into a fork:
#   The public workflow repo is the synchronization medium between
#   contributors. Patches live as .patch files (human-reviewable in PR
#   diffs) and are replayed against upstream at install/update time.
#   This keeps the patch ledger transparent and rebase-friendly.
#
# Usage:
#   scripts/apply-patches.sh
#
# Env vars:
#   HERMES_AGENT_PATH   path to the hermes-agent git checkout
#                       (default: ~/.hermes/hermes-agent)
set -euo pipefail

# ── 0. UI helpers ────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YELLOW=$'\033[0;33m'
  C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_BOLD=""; C_RESET=""
fi
ok()    { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn()  { printf '%s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"; }
fail()  { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; exit 1; }
info()  { printf '%s→%s %s\n' "${C_BOLD}" "${C_RESET}" "$*"; }

# ── 1. Resolve paths ─────────────────────────────────────────────────
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_DIR="${REPO}/patches/hermes-agent"
HERMES_AGENT_PATH="${HERMES_AGENT_PATH:-${HOME}/.hermes/hermes-agent}"

if [[ ! -d "${PATCH_DIR}" ]]; then
  fail "patch directory missing: ${PATCH_DIR}"
fi

# Collect patches in stable lexical order (0001-, 0002-, ...).
shopt -s nullglob
PATCHES=( "${PATCH_DIR}"/*.patch )
shopt -u nullglob
if (( ${#PATCHES[@]} == 0 )); then
  warn "no .patch files in ${PATCH_DIR} — nothing to apply"
  exit 0
fi

# ── 2. Verify hermes-agent checkout ──────────────────────────────────
if [[ ! -d "${HERMES_AGENT_PATH}/.git" ]]; then
  fail "not a git repo: ${HERMES_AGENT_PATH}
       Set HERMES_AGENT_PATH or clone:
         git clone https://github.com/NousResearch/hermes-agent.git ${HERMES_AGENT_PATH}"
fi

# `venv` is bootstrap's symlink to ~/.hermes/hermes-venv; upstream's
# .gitignore pattern `/venv/` only matches a directory, so the link shows
# as untracked on a fresh machine (field report 2026-11-10, A1). Not dirt.
DIRTY="$(git -C "${HERMES_AGENT_PATH}" status --porcelain | grep -vE '^\?\? venv/?$' || true)"
if [[ -n "${DIRTY}" ]]; then
  fail "${HERMES_AGENT_PATH} has uncommitted changes:
$(printf '%s\n' "${DIRTY}" | sed 's/^/         /')
       Commit, stash, or discard your work before re-running. We will
       NOT auto-stash — that has burned people."
fi

# ── 3. Verify upstream remote ────────────────────────────────────────
ORIGIN_URL="$(git -C "${HERMES_AGENT_PATH}" remote get-url origin 2>/dev/null || true)"
case "${ORIGIN_URL}" in
  *NousResearch/hermes-agent*|*NousResearch/hermes-agent.git) ;;
  *)
    fail "origin remote is '${ORIGIN_URL:-<unset>}', expected NousResearch/hermes-agent.
       Add it with:
         git -C ${HERMES_AGENT_PATH} remote add origin git@github.com:NousResearch/hermes-agent.git
       (or rename your existing remote and re-run)"
    ;;
esac

info "fetching origin in ${HERMES_AGENT_PATH}"
git -C "${HERMES_AGENT_PATH}" fetch origin --quiet

# ── 4. Check for already-applied state ───────────────────────────────
# Hash the patch set so we can short-circuit when nothing has changed.
# Stored at .git/applied-patches.hash inside the hermes-agent repo so
# the cache is per-checkout, not per-workflow-clone.
HASH_FILE="${HERMES_AGENT_PATH}/.git/applied-patches.hash"
CURRENT_HASH="$(cat "${PATCHES[@]}" | sha256sum | awk '{print $1}')"
APPLIED_BRANCH="local/applied-patches"

if [[ -f "${HASH_FILE}" ]]; then
  STORED_HASH="$(cat "${HASH_FILE}")"
  if [[ "${STORED_HASH}" == "${CURRENT_HASH}" ]]; then
    # Also confirm the branch still exists and is checked out, otherwise
    # the cache is stale (someone moved HEAD elsewhere manually).
    HEAD_BRANCH="$(git -C "${HERMES_AGENT_PATH}" rev-parse --abbrev-ref HEAD)"
    if [[ "${HEAD_BRANCH}" == "${APPLIED_BRANCH}" ]]; then
      ok "patches already applied (hash ${CURRENT_HASH:0:12})"
      exit 0
    fi
  fi
fi

# ── 5. Apply patches ─────────────────────────────────────────────────
info "checking out ${APPLIED_BRANCH} from origin/main"
git -C "${HERMES_AGENT_PATH}" checkout -B "${APPLIED_BRANCH}" origin/main --quiet

info "applying ${#PATCHES[@]} patches"
# A fresh machine has no git identity and `git am` refuses to commit
# without one (field report 2026-11-10, A3). Supply a local one for this
# command only when the user has none configured.
AM_IDENT=()
if [[ -z "$(git -C "${HERMES_AGENT_PATH}" config user.email 2>/dev/null)" ]]; then
  AM_IDENT=(-c user.name=hermes-bootstrap -c user.email=bootstrap@localhost)
fi
if ! git -C "${HERMES_AGENT_PATH}" "${AM_IDENT[@]}" am "${PATCHES[@]}"; then
  CONFLICT_PATH="$(git -C "${HERMES_AGENT_PATH}" status --porcelain | awk '/^UU /{print $2; exit}')"
  warn "git am failed; aborting partial application"
  git -C "${HERMES_AGENT_PATH}" am --abort || true
  fail "patch application failed${CONFLICT_PATH:+ on path: ${CONFLICT_PATH}}.
       Likely cause: upstream renamed or removed code a patch depends on.
       Fix: refresh the patch from a rebased branch and re-export via
            scripts/export-patches.sh, then commit + PR the new patches."
fi

# ── 6. Stamp the hash so the next run short-circuits ─────────────────
printf '%s\n' "${CURRENT_HASH}" > "${HASH_FILE}"
ok "applied ${#PATCHES[@]} patches (hash ${CURRENT_HASH:0:12})"

# ── 7. Restart hermes-gateway if running ─────────────────────────────
# Skip silently if the unit isn't loaded yet — bootstrap may be running
# us before any services are up, and that's fine.
if systemctl --user is-active --quiet hermes-gateway.service 2>/dev/null; then
  info "restarting hermes-gateway.service"
  systemctl --user restart hermes-gateway.service
  ok "hermes-gateway restarted"
fi

ok "done"
