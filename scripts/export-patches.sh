#!/usr/bin/env bash
# hermes-agent-workflow / scripts / export-patches.sh
#
# Export a contributor's local branch as a series of .patch files into
# patches/<repo-name>/. The intended workflow:
#
#   1. Develop in ~/.hermes/hermes-agent on a `local/<topic>` branch.
#   2. Test live until you're happy.
#   3. From your fork of hermes-agent-workflow, run:
#        scripts/export-patches.sh hermes-agent local/<topic>
#   4. Commit the regenerated patch files + update PATCHES.md, open PR.
#
# Currently only `hermes-agent` is supported as a target repo, but the
# script is structured so a future second target (e.g. parley) can be
# bolted on without changing the calling convention.
#
# Usage:
#   scripts/export-patches.sh <repo-name> <branch>
#
# Env vars:
#   HERMES_AGENT_PATH   path to the hermes-agent git checkout
#                       (default: ~/.hermes/hermes-agent)
set -euo pipefail

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

if (( $# != 2 )); then
  fail "usage: $0 <repo-name> <branch>
       e.g. $0 hermes-agent local/whatsapp-sender-prefix"
fi

REPO_NAME="$1"
BRANCH="$2"
WORKFLOW_REPO="$(cd "$(dirname "$0")/.." && pwd)"

case "${REPO_NAME}" in
  hermes-agent)
    SOURCE_REPO="${HERMES_AGENT_PATH:-${HOME}/.hermes/hermes-agent}"
    ;;
  *)
    fail "unknown repo name: ${REPO_NAME}
       Currently supported: hermes-agent
       To add another, edit ${0##*/} and add a case for the new target."
    ;;
esac

if [[ ! -d "${SOURCE_REPO}/.git" ]]; then
  fail "not a git repo: ${SOURCE_REPO}"
fi

if ! git -C "${SOURCE_REPO}" rev-parse --verify --quiet "${BRANCH}" >/dev/null; then
  fail "branch '${BRANCH}' does not exist in ${SOURCE_REPO}"
fi

# Verify origin/main is fetched so origin/main..<branch> is meaningful.
if ! git -C "${SOURCE_REPO}" rev-parse --verify --quiet origin/main >/dev/null; then
  fail "origin/main not found in ${SOURCE_REPO}.
       Run: git -C ${SOURCE_REPO} fetch origin"
fi

OUT_DIR="${WORKFLOW_REPO}/patches/${REPO_NAME}"
mkdir -p "${OUT_DIR}"

# Wipe stale patches so removed commits don't linger from a previous
# export. Only nukes .patch files; leaves any README/notes alone.
info "wiping ${OUT_DIR}/*.patch"
rm -f "${OUT_DIR}"/*.patch

info "exporting origin/main..${BRANCH} from ${SOURCE_REPO}"
git -C "${SOURCE_REPO}" format-patch "origin/main..${BRANCH}" -o "${OUT_DIR}" >/dev/null

shopt -s nullglob
PATCHES=( "${OUT_DIR}"/*.patch )
shopt -u nullglob
COUNT=${#PATCHES[@]}
if (( COUNT == 0 )); then
  warn "no patches generated — is ${BRANCH} ahead of origin/main?"
  exit 0
fi

ok "exported ${COUNT} patches to ${OUT_DIR}"
for p in "${PATCHES[@]}"; do
  printf '    %s\n' "${p##*/}"
done
echo
warn "remember to update ${WORKFLOW_REPO}/PATCHES.md to reflect the new set"
