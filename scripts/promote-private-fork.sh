#!/usr/bin/env bash
# Promote a public-template clone into a private, git-crypt-backed agent repo.
#
# The public template supports clean validation installs. This script performs
# the second step: make this clone the user's private source of truth, copy
# live secrets into encrypted paths, switch origin to the private repo, enable
# versioned host memory, optionally install sync crons, and push.
set -euo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO" && -f "$REPO/scripts/bootstrap.sh" ]] || {
  echo "Run this from a hermes-agent-workflow clone." >&2
  exit 1
}

PRIVATE_REPO=""
HOST_NAME="${HOST_NAME:-$(hostname -s)}"
ENV_FILE_ARG=""
KEY_FILE=""
REUSE_KEY_FROM=""
NEW_KEY_OUT=""
CREATE_GITHUB=0
INSTALL_CRONS=0
RUN_INITIAL_SYNC=0
RERUN_BOOTSTRAP=0
SKIP_GOOGLE_OAUTH=0
ASSUME_YES=0
FORCE_ORIGIN=0

usage() {
  cat <<EOF
Usage: scripts/promote-private-fork.sh --repo OWNER/NAME [options]

Options:
  --repo OWNER/NAME            Private GitHub repo to push this agent to.
  --host NAME                  Host name for ACTIVE_HOST and hosts/<host>/.
  --create-github              Create OWNER/NAME as a private GitHub repo via gh.
  --reuse-key-from PATH        Export git-crypt key from an existing unlocked repo.
  --key-file PATH              Unlock this repo with an existing git-crypt key file.
  --new-key-out PATH           First private repo: git-crypt init and export key here.
  --env-file PATH              Copy this env file into encrypted .env.
  --skip-google-oauth          Do not copy google_*.json or ~/.config/gogcli.
  --rerun-bootstrap            Re-run bootstrap with versioned host state after promotion.
  --install-crons              Install private versioning crons.
  --run-initial-sync           Run sync scripts once now after committing promotion.
  --force-origin               Replace a non-public existing origin.
  --yes                        Skip confirmations.

Exactly one of --reuse-key-from, --key-file, or --new-key-out is recommended.
If none is provided and git-crypt is not initialized, a new key is created but
not exported, which is unsafe for real use.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --repo) shift; PRIVATE_REPO="${1:-}"; shift ;;
    --repo=*) PRIVATE_REPO="${1#--repo=}"; shift ;;
    --host) shift; HOST_NAME="${1:-}"; shift ;;
    --host=*) HOST_NAME="${1#--host=}"; shift ;;
    --create-github) CREATE_GITHUB=1; shift ;;
    --reuse-key-from) shift; REUSE_KEY_FROM="${1:-}"; shift ;;
    --reuse-key-from=*) REUSE_KEY_FROM="${1#--reuse-key-from=}"; shift ;;
    --key-file) shift; KEY_FILE="${1:-}"; shift ;;
    --key-file=*) KEY_FILE="${1#--key-file=}"; shift ;;
    --new-key-out) shift; NEW_KEY_OUT="${1:-}"; shift ;;
    --new-key-out=*) NEW_KEY_OUT="${1#--new-key-out=}"; shift ;;
    --env-file) shift; ENV_FILE_ARG="${1:-}"; shift ;;
    --env-file=*) ENV_FILE_ARG="${1#--env-file=}"; shift ;;
    --skip-google-oauth) SKIP_GOOGLE_OAUTH=1; shift ;;
    --rerun-bootstrap) RERUN_BOOTSTRAP=1; shift ;;
    --install-crons) INSTALL_CRONS=1; shift ;;
    --run-initial-sync) RUN_INITIAL_SYNC=1; shift ;;
    --force-origin) FORCE_ORIGIN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$PRIVATE_REPO" ]] || { usage >&2; exit 2; }
[[ "$PRIVATE_REPO" == */* ]] || { echo "--repo must be OWNER/NAME" >&2; exit 2; }

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "$1 is required" >&2; exit 1; }
}
need git
need git-crypt
if (( CREATE_GITHUB )); then need gh; fi

cd "$REPO"

if (( ! ASSUME_YES )); then
  cat <<EOF
This will promote this clone into a private agent repo:
  clone:        $REPO
  private repo: $PRIVATE_REPO
  host:         $HOST_NAME

It may copy live ~/.hermes secrets into encrypted repo paths and push to
origin/main. Continue? [type YES]
EOF
  read -r reply
  [[ "$reply" == "YES" ]] || { echo "aborted"; exit 1; }
fi

private_url="git@github.com:${PRIVATE_REPO}.git"
origin="$(git remote get-url origin 2>/dev/null || true)"
public_https="https://github.com/jscholz/hermes-agent-workflow.git"
public_ssh="git@github.com:jscholz/hermes-agent-workflow.git"

if (( CREATE_GITHUB )); then
  if gh repo view "$PRIVATE_REPO" >/dev/null 2>&1; then
    echo "GitHub repo exists: $PRIVATE_REPO"
  else
    gh repo create "$PRIVATE_REPO" --private
  fi
fi

if [[ "$origin" == "$public_https" || "$origin" == "$public_ssh" ]]; then
  git remote remove upstream 2>/dev/null || true
  git remote rename origin upstream
  git remote add origin "$private_url"
elif [[ "$origin" == "$private_url" ]]; then
  :
elif [[ -z "$origin" ]]; then
  git remote add origin "$private_url"
else
  if (( FORCE_ORIGIN )); then
    git remote set-url origin "$private_url"
  else
    echo "origin is $origin, not $private_url. Use --force-origin to replace it." >&2
    exit 1
  fi
fi

if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream "$public_ssh" 2>/dev/null || git remote add upstream "$public_https"
fi

tmp_key=""
cleanup() {
  if [[ -n "$tmp_key" && -f "$tmp_key" ]]; then
    shred -u "$tmp_key" 2>/dev/null || rm -f "$tmp_key"
  fi
}
trap cleanup EXIT

if [[ -n "$KEY_FILE" ]]; then
  [[ -r "$KEY_FILE" ]] || { echo "key file not readable: $KEY_FILE" >&2; exit 1; }
  git-crypt unlock "$KEY_FILE"
elif [[ -n "$REUSE_KEY_FROM" ]]; then
  [[ -d "$REUSE_KEY_FROM/.git" ]] || { echo "--reuse-key-from must be a git repo: $REUSE_KEY_FROM" >&2; exit 1; }
  tmp_key="$(mktemp)"
  (cd "$REUSE_KEY_FROM" && git-crypt export-key "$tmp_key")
  chmod 600 "$tmp_key"
  git-crypt unlock "$tmp_key"
elif [[ -n "$NEW_KEY_OUT" ]]; then
  git-crypt init
  git-crypt export-key "$NEW_KEY_OUT"
  chmod 600 "$NEW_KEY_OUT"
  echo "Exported new git-crypt key to $NEW_KEY_OUT. Back it up before deleting this machine."
else
  if ! git config --local --get-regexp '^filter\.git-crypt\.' >/dev/null 2>&1; then
    echo "WARNING: initializing git-crypt without exporting a key. Use --new-key-out for a recoverable setup." >&2
    git-crypt init
  fi
fi

copy_file_from_live() {
  local live="$1" repo_rel="$2" label="$3"
  local dest="$REPO/$repo_rel"
  [[ -e "$live" ]] || return 0
  if [[ -L "$live" && "$(readlink "$live")" == "$dest" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$live" ]]; then
    cp -p "$live" "$dest"
    chmod 600 "$dest" 2>/dev/null || true
    mkdir -p "$(dirname "$live")"
    mv "$live" "$live.pre-private-promote.$(date +%Y%m%d-%H%M%S)"
    ln -s "$dest" "$live"
    echo "versioned encrypted $label -> $repo_rel"
  fi
}

copy_dir_from_live() {
  local live="$1" repo_rel="$2" label="$3"
  local dest="$REPO/$repo_rel"
  [[ -d "$live" ]] || return 0
  if [[ -L "$live" && "$(readlink "$live")" == "$dest" ]]; then
    return 0
  fi
  mkdir -p "$dest"
  rsync -a "$live"/ "$dest"/
  if [[ -L "$live" ]]; then
    rm "$live"
    ln -s "$dest" "$live"
  else
    mv "$live" "$live.pre-private-promote.$(date +%Y%m%d-%H%M%S)"
    ln -s "$dest" "$live"
  fi
  echo "versioned encrypted $label -> $repo_rel"
}

if [[ -n "$ENV_FILE_ARG" ]]; then
  [[ -r "$ENV_FILE_ARG" ]] || { echo "env file not readable: $ENV_FILE_ARG" >&2; exit 1; }
  cp -p "$ENV_FILE_ARG" "$REPO/.env"
  chmod 600 "$REPO/.env"
  if [[ -e "$HOME/.hermes/.env" && ! -L "$HOME/.hermes/.env" ]]; then
    mv "$HOME/.hermes/.env" "$HOME/.hermes/.env.pre-private-promote.$(date +%Y%m%d-%H%M%S)"
  fi
  mkdir -p "$HOME/.hermes"
  ln -sfn "$REPO/.env" "$HOME/.hermes/.env"
else
  copy_file_from_live "$HOME/.hermes/.env" ".env" ".env"
fi

for secret in auth.json; do
  copy_file_from_live "$HOME/.hermes/$secret" "$secret" "$secret"
done
if (( ! SKIP_GOOGLE_OAUTH )); then
  for secret in google_client_secret.json google_token.json; do
    copy_file_from_live "$HOME/.hermes/$secret" "$secret" "$secret"
  done
fi
copy_dir_from_live "$HOME/.hermes/whatsapp/session" "whatsapp/session" "WhatsApp session"
copy_dir_from_live "$HOME/.hermes/pairing" "pairing" "Parley pairing"
if (( ! SKIP_GOOGLE_OAUTH )); then
  copy_dir_from_live "$HOME/.config/gogcli" "gogcli" "gogcli config/keyring"
fi
copy_dir_from_live "$HOME/.hermes/host-state/$HOST_NAME/claude-code-memory" "hosts/$HOST_NAME/claude-code-memory" "Claude Code host memory"

printf 'active_host=%s\n' "$HOST_NAME" > "$REPO/ACTIVE_HOST"
mkdir -p "$REPO/sessions" "$REPO/hermes-data" "$REPO/hindsight-data" "$REPO/parley-data"
touch "$REPO/sessions/.gitkeep" "$REPO/hermes-data/.gitkeep" "$REPO/hindsight-data/.gitkeep" "$REPO/parley-data/.gitkeep"

if (( RERUN_BOOTSTRAP )); then
  HERMES_WORKFLOW_HOST_STATE_MODE=versioned HOST_NAME="$HOST_NAME" "$REPO/scripts/bootstrap.sh" --unattended
fi

if (( INSTALL_CRONS )); then
  "$REPO/scripts/install-versioning-crons.sh" --host "$HOST_NAME" --yes
fi

# Re-apply filters to any already-tracked files that now match private
# encryption rules in this fork. This is the critical step that prevents
# first-push plaintext leakage after broadening .gitattributes.
git add --renormalize .
git add -A

if git diff --cached --quiet; then
  echo "No promotion changes to commit."
else
  git commit -m "private bootstrap: $HOST_NAME"
fi

git push -u origin main

if (( RUN_INITIAL_SYNC )); then
  "$REPO/scripts/sync-hermes.sh" || true
  "$REPO/scripts/sync-cc-history.sh" || true
  "$REPO/scripts/sync-hermes-state.sh" || true
  "$REPO/scripts/sync-parley-db.sh" || true
  "$REPO/scripts/sync-hindsight-bank.sh" || true
fi

echo "Private fork promotion complete: $PRIVATE_REPO"
