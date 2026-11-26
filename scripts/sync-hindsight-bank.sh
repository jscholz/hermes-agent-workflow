#!/usr/bin/env bash
# Dump the hindsight memory bank (pg0 Postgres) to the backup stage.
#
# One COPY file per table under ~/.backups/stage/hindsight-data/<table>.sql,
# every table in the public schema (new tables are picked up automatically),
# rows ordered by insertion time first so a night's new rows land at the END
# of the file and restic's content-defined chunking stores only the tail.
# (The earlier git-based layout chunked by pk range; memory_links has no
# pk and its chunk key was not unique, so ties reordered on every run and
# every chunk was a new blob. restic makes the chunking unnecessary.)
#
# memory_units.embedding (pgvector) is excluded: derived, bulky, rebuilt
# by hindsight after restore (restore-hindsight-bank.sh).
#
# Restore: scripts/restore-hindsight-bank.sh (DUMP_DIR=... to override).
set -euo pipefail
: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
export XDG_RUNTIME_DIR
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
. "${REPO}/scripts/lib/backup-common.sh"
bk_active_host_or_exit "${REPO}" sync-hindsight-bank

PGBIN="${PGBIN:-$HOME/.pg0/installation/18.1.0/bin}"
PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-hindsight}"
PGDATABASE="${PGDATABASE:-hindsight}"
export PGPASSWORD="${PGPASSWORD:-hindsight}"
OUT_DIR="${OUT_DIR:-${BACKUP_STAGE}/hindsight-data}"

if ! systemctl --user is-active hindsight-server.service >/dev/null 2>&1; then
  echo "[sync-hindsight] hindsight-server.service not active — skipping" >&2
  exit 0
fi

# Per-table ORDER BY (insertion time first, then enough columns to be
# deterministic). Tables not listed are ordered by every column.
declare -A order_by=(
  [memory_units]="created_at,id"
  [memory_links]="created_at,from_unit_id,to_unit_id,link_type,entity_id"
  [documents]="created_at,id"
  [chunks]="created_at,chunk_id"
  [entities]="first_seen,id"
  [async_operations]="created_at,operation_id"
)
declare -A exclude_cols=(
  [memory_units]="embedding"
)

mkdir -p "${OUT_DIR}"
tables=$("${PGBIN}/psql" --host="${PGHOST}" --port="${PGPORT}" --username="${PGUSER}" --dbname="${PGDATABASE}" \
  -Atc "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY table_name")
[[ -n "${tables}" ]] || { echo "[sync-hindsight] no tables found" >&2; exit 1; }

for tbl in ${tables}; do
  args=(--table "public.${tbl}" --flat-file "${OUT_DIR}/${tbl}.sql")
  [[ -n "${order_by[$tbl]:-}" ]] && args+=(--order-by "${order_by[$tbl]}")
  [[ -n "${exclude_cols[$tbl]:-}" ]] && args+=(--exclude-columns "${exclude_cols[$tbl]}")
  python3 "${REPO}/scripts/lib/chunked-table-dump.py" \
      --psql-host "${PGHOST}" --psql-port "${PGPORT}" \
      --psql-user "${PGUSER}" --psql-database "${PGDATABASE}" \
      --pg-dump-path "${PGBIN}/pg_dump" "${args[@]}" >/dev/null
done
# Tables dropped upstream must not be replayed from a stale file.
for f in "${OUT_DIR}"/*.sql; do
  t=$(basename "${f}" .sql)
  grep -qx "${t}" <<<"${tables}" || rm -f "${f}"
done
rm -rf "${OUT_DIR}"/*/   # chunk dirs from the git-based layout
bk_heartbeat sync-hindsight-bank
echo "[sync-hindsight] $(date -u +%FT%TZ) staged $(echo "${tables}" | wc -l) tables, $(du -sh "${OUT_DIR}" | cut -f1) at ${OUT_DIR}"
