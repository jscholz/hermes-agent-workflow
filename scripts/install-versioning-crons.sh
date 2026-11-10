#!/usr/bin/env bash
# Install the private-repo sync crons for a hermes-agent-workflow clone.
#
# This script is intentionally separate from bootstrap.sh: a public-template
# validation install should not push runtime state anywhere. Run this only
# after the clone has been promoted to a private origin and git-crypt is
# initialized/unlocked.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HOST_NAME="${HOST_NAME:-$(hostname -s)}"
ASSUME_YES=0

usage() {
  cat <<EOF
Usage: scripts/install-versioning-crons.sh [--host <name>] [--yes]

Installs a managed crontab block that snapshots and pushes:
  - Hermes sessions/systemd metadata every 15 min
  - Claude Code memory every 15 min
  - doctor health checks every 10 min
  - Hermes state.db SQL dump daily
  - Hindsight bank SQL dump daily
  - Parley UI DB SQL dump daily

The script refuses to run if origin is the public template remote.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --host) shift; HOST_NAME="${1:-}"; [[ -n "$HOST_NAME" ]] || { echo "--host requires a value" >&2; exit 2; }; shift ;;
    --host=*) HOST_NAME="${1#--host=}"; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

origin="$(git -C "$REPO" remote get-url origin 2>/dev/null || true)"
case "$origin" in
  git@github.com:jscholz/hermes-agent-workflow.git|https://github.com/jscholz/hermes-agent-workflow.git)
    echo "Refusing to install state-sync crons while origin is the public template: $origin" >&2
    echo "Promote to a private repo first with scripts/promote-private-fork.sh." >&2
    exit 1
    ;;
esac

if [[ ! -f "$REPO/.gitattributes" ]] || ! grep -q '^hermes-data/\*\*' "$REPO/.gitattributes"; then
  echo "Encryption rules look incomplete; refusing to install crons." >&2
  exit 1
fi

if (( ! ASSUME_YES )); then
  cat <<EOF
About to install private sync crons for:
  repo:   $REPO
  origin: ${origin:-<none>}
  host:   $HOST_NAME

These crons create commits and push to origin/main. Continue? [type YES]
EOF
  read -r reply
  [[ "$reply" == "YES" ]] || { echo "aborted"; exit 1; }
fi

mkdir -p "$HERMES_HOME/logs"
printf 'active_host=%s\n' "$HOST_NAME" > "$REPO/ACTIVE_HOST"

begin="# BEGIN hermes-agent-workflow versioning: $REPO"
end="# END hermes-agent-workflow versioning: $REPO"
tmp_old="$(mktemp)"
tmp_new="$(mktemp)"
trap 'rm -f "$tmp_old" "$tmp_new"' EXIT

crontab -l 2>/dev/null > "$tmp_old" || true
awk -v begin="$begin" -v end="$end" -v repo="$REPO" '
  $0 == begin { skip=1; next }
  $0 == end { skip=0; next }
  skip != 1 && $0 !~ /^[[:space:]]*#/ && index($0, repo "/scripts/") > 0 &&
    $0 ~ /(doctor|sync-hermes|sync-cc-history|sync-hermes-state|sync-hindsight-bank|sync-parley-db|prune-claude-cc-history)[.]sh/ { next }
  skip != 1 { print }
' "$tmp_old" > "$tmp_new"

cat >> "$tmp_new" <<EOF
$begin
*/10 * * * * REPO="$REPO" HERMES="$HERMES_HOME" HOST_NAME="$HOST_NAME" "$REPO/scripts/doctor.sh" >> "$HERMES_HOME/logs/doctor.log" 2>&1
*/15 * * * * REPO="$REPO" HERMES="$HERMES_HOME" HOST_NAME="$HOST_NAME" "$REPO/scripts/sync-hermes.sh" >> "$HERMES_HOME/logs/sync-hermes.log" 2>&1
*/15 * * * * REPO="$REPO" HOST_NAME="$HOST_NAME" "$REPO/scripts/sync-cc-history.sh" >> "$HERMES_HOME/logs/sync-cc-history.log" 2>&1
33 3 * * * REPO="$REPO" "$REPO/scripts/sync-hermes-state.sh" >> "$HERMES_HOME/logs/sync-hermes-state.log" 2>&1
44 3 * * * REPO="$REPO" "$REPO/scripts/sync-hindsight-bank.sh" >> "$HERMES_HOME/logs/sync-hindsight-bank.log" 2>&1
49 3 * * * REPO="$REPO" "$REPO/scripts/sync-parley-db.sh" >> "$HERMES_HOME/logs/sync-parley-db.log" 2>&1
44 4 * * * "$REPO/scripts/prune-claude-cc-history.sh" >> "$HERMES_HOME/logs/prune-claude-cc-history.log" 2>&1
$end
EOF

crontab "$tmp_new"
echo "Installed private versioning crons for $REPO"
