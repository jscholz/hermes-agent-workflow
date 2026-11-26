#!/usr/bin/env bash
# Nightly backup of the live databases.
#
#   dumps  → ~/.backups/stage/{hermes-data,hindsight-data,parley-data}
#          (scripts/sync-hermes-state.sh, sync-hindsight-bank.sh, sync-parley-db.sh)
#   restic → local repo  ~/.backups/restic                    (always)
#          → cloud repo  $BACKUP_CLOUD_REPO                    (restic copy, when set:
#                        any restic repo string — rclone:<remote>:<path>,
#                        sftp:<host>:<path>, s3:…, b2:…; see docs/BACKUPS.md)
#   retention: 14 daily / 8 weekly / 12 monthly / 3 yearly, pruned on Sundays
#   integrity: `restic check --read-data-subset` on Sundays
#   status:    ~/.hermes/logs/backup-nightly.status.json (read by doctor.sh)
#
# Why restic, not git: content-defined chunking makes each night cost the
# changed pieces of the dumps (tens of MB), it encrypts at rest, and
# `forget` is the retention policy. git-crypt'd dumps in git history cost
# the whole dump per night, undeltable and uncompressible, forever.
#
# Flags: --no-cloud (skip the cloud copy), --prune / --check (force the
# weekly steps tonight), --dry-run (dumps + status only).
# Env: BACKUP_CLOUD_REPO (also read from ~/.hermes/.env), BACKUP_HOME,
# BACKUP_STAGE, RCLONE_CONFIG (default: <repo>/backups/rclone.conf).
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
. "${REPO}/scripts/lib/backup-common.sh"
bk_active_host_or_exit "${REPO}" backup-nightly
NAME=backup-nightly
LOCK="${BACKUP_HOME}/.${NAME}.lock"
LOCAL_REPO="${BACKUP_HOME}/restic"
if [[ -z "${BACKUP_CLOUD_REPO:-}" && -f "${HERMES_HOME}/.env" ]]; then
  BACKUP_CLOUD_REPO="$(awk -F= '$1=="BACKUP_CLOUD_REPO"{print substr($0,length($1)+2)}' "${HERMES_HOME}/.env" | tail -1)"
fi
CLOUD_REPO="${BACKUP_CLOUD_REPO:-}"
KEEP=(--keep-daily 14 --keep-weekly 8 --keep-monthly 12 --keep-yearly 3)
STATUS="${BACKUP_LOGS}/${NAME}.status.json"
export RESTIC_PASSWORD_FILE="${BACKUP_HOME}/restic.key"
export RESTIC_CACHE_DIR="${BACKUP_HOME}/cache"
export RESTIC_COMPRESSION=auto
export PATH="${HOME}/.local/bin:${BACKUP_HOME}/bin:${PATH}"
export RCLONE_CONFIG="${RCLONE_CONFIG:-${REPO}/backups/rclone.conf}"

DO_CLOUD=1; FORCE_PRUNE=0; FORCE_CHECK=0; DRY=0
for a in "$@"; do case "$a" in
  --no-cloud) DO_CLOUD=0 ;; --prune) FORCE_PRUNE=1 ;; --check) FORCE_CHECK=1 ;; --dry-run) DRY=1 ;;
  *) echo "unknown flag $a" >&2; exit 2 ;; esac; done
sunday=0; [[ "$(date -u +%u)" == 7 ]] && sunday=1

mkdir -p "${BACKUP_HOME}" "${BACKUP_LOGS}" "${RESTIC_CACHE_DIR}"
exec 9>"${LOCK}"; flock -n 9 || { echo "[${NAME}] another run holds ${LOCK}" >&2; exit 1; }
(( DRY )) || [[ -s "${RESTIC_PASSWORD_FILE}" ]] || { echo "[${NAME}] no key at ${RESTIC_PASSWORD_FILE} — run scripts/bootstrap.sh" >&2; exit 1; }

declare -A st; st[ok]=1; st[ts]="$(date -u +%FT%TZ)"
fail() { st[ok]=0; bk_log "FAIL: $*" >&2; }
write_status() {
  local kv=(); local k
  for k in "${!st[@]}"; do kv+=("${k}=${st[$k]}"); done
  python3 - "${STATUS}" "${LOCAL_REPO}" "${kv[@]}" <<'PY'
import json, os, subprocess, sys
out, local_repo, kv = sys.argv[1], sys.argv[2], sys.argv[3:]
BOOL = {"ok", "cloud_configured", "cloud_ok", "check_ok", "dry_run"}
INT = {"stage_bytes", "local_data_added"}
d = {}
for item in kv:
    k, _, v = item.partition("=")
    d[k] = (v == "1") if k in BOOL else int(v or 0) if k in INT else v
try:
    d["local_repo_bytes"] = int(subprocess.run(["du", "-sb", local_repo], capture_output=True, text=True).stdout.split()[0])
except Exception:
    d["local_repo_bytes"] = None
prev = {}
try:
    prev = json.load(open(out))
except Exception:
    pass
# Carry the last check result and the previous repo size forward so a
# health check can judge age and growth from this one file.
for k in ("check_ok", "check_ts"):
    if k not in d and k in prev: d[k] = prev[k]
d["prev_local_repo_bytes"] = prev.get("local_repo_bytes")
d["prev_ts"] = prev.get("ts")
tmp = out + ".tmp"
with open(tmp, "w") as f: json.dump(d, f, indent=2, sort_keys=True)
os.replace(tmp, out)
PY
}
trap 'write_status; bk_heartbeat "${NAME}"' EXIT

# ── 1. dumps ───────────────────────────────────────────────────────────
for s in sync-hermes-state sync-hindsight-bank sync-parley-db; do
  if out=$(REPO="${REPO}" "${REPO}/scripts/${s}.sh" 2>&1); then bk_log "${out##*$'\n'}"; st[dump_${s//-/_}]=ok
  else fail "${s}: ${out##*$'\n'}"; st[dump_${s//-/_}]="fail: ${out##*$'\n'}"; fi
done
st[stage_bytes]=$(du -sb "${BACKUP_STAGE}" 2>/dev/null | cut -f1)
st[dry_run]=${DRY}
(( DRY )) && exit 0

# ── 2. local snapshot ──────────────────────────────────────────────────
if ! restic -r "${LOCAL_REPO}" cat config >/dev/null 2>&1; then
  bk_log "initialising local repo ${LOCAL_REPO}"
  restic -r "${LOCAL_REPO}" init -q || { fail "local init"; exit 1; }
fi
summary=$(restic -r "${LOCAL_REPO}" backup "${BACKUP_STAGE}" --tag nightly --json 2>&1 | grep '"message_type":"summary"' | tail -1)
if [[ -n "${summary}" ]]; then
  st[local_snapshot]=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("snapshot_id","")[:8])' "${summary}")
  st[local_data_added]=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("data_added",0))' "${summary}")
  bk_log "local snapshot ${st[local_snapshot]} added $(( ${st[local_data_added]} / 1048576 )) MiB"
else fail "local backup produced no summary"; fi
restic -r "${LOCAL_REPO}" forget "${KEEP[@]}" --tag nightly -q || fail "local forget"
if (( sunday || FORCE_PRUNE )); then restic -r "${LOCAL_REPO}" prune -q || fail "local prune"; fi
if (( sunday || FORCE_CHECK )); then
  if restic -r "${LOCAL_REPO}" check --read-data-subset=10% -q >/dev/null 2>&1; then st[check_ok]=1; st[check_ts]="$(date -u +%FT%TZ)"
  else st[check_ok]=0; st[check_ts]="$(date -u +%FT%TZ)"; fail "local check"; fi
fi

# ── 3. cloud copy ──────────────────────────────────────────────────────
cloud_ready() {
  [[ -n "${CLOUD_REPO}" ]] || return 1
  if [[ "${CLOUD_REPO}" == rclone:* ]]; then
    # rclone:<remote>:<path> — the remote must exist in RCLONE_CONFIG with a token.
    local remote="${CLOUD_REPO#rclone:}"; remote="${remote%%:*}"
    rclone listremotes 2>/dev/null | grep -qx "${remote}:" || return 1
    grep -A20 "^\[${remote}\]" "${RCLONE_CONFIG}" 2>/dev/null | grep -qE '^(token *= *\{|service_account_file *=)' || return 1
  fi
  return 0
}
st[cloud_repo]="${CLOUD_REPO}"
if (( DO_CLOUD )) && cloud_ready; then
  st[cloud_configured]=1
  if ! restic -r "${CLOUD_REPO}" cat config >/dev/null 2>&1; then
    bk_log "initialising cloud repo ${CLOUD_REPO} (same chunker params as local → dedup across copies)"
    restic -r "${CLOUD_REPO}" init -q --copy-chunker-params --from-repo "${LOCAL_REPO}" --from-password-file "${RESTIC_PASSWORD_FILE}" || fail "cloud init"
  fi
  if restic -r "${CLOUD_REPO}" copy --from-repo "${LOCAL_REPO}" --from-password-file "${RESTIC_PASSWORD_FILE}" -q 2>&1 | tail -3; then
    st[cloud_ok]=1; st[cloud_ts]="$(date -u +%FT%TZ)"
    restic -r "${CLOUD_REPO}" forget "${KEEP[@]}" --tag nightly -q || fail "cloud forget"
    if (( sunday || FORCE_PRUNE )); then restic -r "${CLOUD_REPO}" prune -q || fail "cloud prune"; fi
  else st[cloud_ok]=0; fail "cloud copy"; fi
else
  st[cloud_configured]=0; st[cloud_ok]=0
  if (( DO_CLOUD )); then
    if [[ -z "${CLOUD_REPO}" ]]; then bk_log "cloud copy not configured (BACKUP_CLOUD_REPO unset) — local repo only"
    else bk_log "cloud copy SKIPPED: ${CLOUD_REPO} is not ready (rclone remote missing or has no token — see docs/BACKUPS.md)"; fi
  fi
fi
bk_log "done ok=${st[ok]}"
exit $(( 1 - st[ok] ))
