#!/usr/bin/env python3
"""Append-only byte-rotation chunked dump for a SQL table.

The single-file pg_dump model breaks once any table exceeds GitHub's
100 MB per-blob cap. This helper carves a big table's data dump into
fixed-PK-range chunks that:

  1. Stay under the cap (target: 80 MB per chunk, 20 MB safety margin).
  2. Preserve git's pack-delta compression — past chunks are usually
     byte-identical across daily runs unless rows in their range
     actually changed. Only the "current" chunk grows day-to-day.
  3. Rotate gracefully: when any chunk exceeds the target, repair the
     rotation by deriving fresh PK boundaries from the current dump.
     This deliberately trades one larger diff for never committing a
     blob that GitHub will reject.

Layout for table `T` in directory `out_dir/T/`:

    .rotation.json     # {"chunks": [{"num": 1, "max_pk": "<uuid>"}, ...]}
    0001.sql           # COPY block for rows with PKs ≤ max_pk_1
    0002.sql           # COPY block for rows with PKs ∈ (max_pk_1, max_pk_2]
    ...
    NNNN.sql           # CURRENT chunk — PKs > last frozen max_pk

On dump:
  - Read .rotation.json (or initialize empty for first run).
  - For each frozen chunk (1..N-1):
      Query rows in that chunk's PK range. Emit COPY data to <NNNN>.sql.
      Past chunk file becomes byte-identical UNLESS a row's content
      changed upstream — in which case git picks up the small diff.
  - For the current chunk N:
      Query rows with PK > last_frozen_max_pk. Emit COPY data to <NNNN>.sql.
  - If any chunk exceeds target_bytes, recompute all boundaries from
    the current sorted rows, then write that repaired layout.
  - If any emitted chunk still exceeds max_bytes, fail before commit.

On restore: `cat T/*.sql | psql` — each file is a complete COPY block
so arbitrary text payload stays inside COPY data mode instead of being
parsed as psql metacommands.

Idempotent + deterministic: row order within a chunk is
`ORDER BY <pk>` so two runs against an unchanged DB produce
byte-identical chunk files.

Usage from a bash sync script:
    python3 scripts/lib/chunked-table-dump.py \\
        --psql-host 127.0.0.1 --psql-port 5432 \\
        --psql-user hindsight --psql-database hindsight \\
        --table public.memory_units \\
        --pk-column id \\
        --out-dir hindsight-data/memory_units \\
        --target-bytes 83886080   # 80 MiB

Env vars:
    PGPASSWORD — postgres password (standard libpq)

Exits non-zero on any error (set -e safe).
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


def _psql_cmd(args: argparse.Namespace, sql: str) -> list[str]:
    return [
        _psql_path(args),
        "--host", args.psql_host,
        "--port", str(args.psql_port),
        "--username", args.psql_user,
        "--dbname", args.psql_database,
        "--no-align",
        "--tuples-only",
        "--quiet",
        "--no-psqlrc",
        "--field-separator-zero",
        "--record-separator-zero",
        "-c", sql,
    ]


def _psql_path(args: argparse.Namespace) -> str:
    pg_dump_path = Path(args.pg_dump_path)
    if pg_dump_path.is_absolute():
        return str(pg_dump_path.with_name("psql"))
    return "psql"


def _psql_query(args: argparse.Namespace, sql: str) -> bytes:
    """Run psql -c sql, return stdout. Uses zero-byte separators so we
    can split safely on any payload (UUIDs are ASCII so it doesn't
    matter for pk columns, but keeps the helper generic).
    """
    result = subprocess.run(
        _psql_cmd(args, sql),
        check=True,
        capture_output=True,
    )
    return result.stdout


def _quote_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _qualified_table_expr(table_pg: str) -> str:
    return ".".join(_quote_ident(part) for part in table_pg.split("."))


def _table_regclass_literal(table_pg: str) -> str:
    return "'" + table_pg.replace("'", "''") + "'::regclass"


def _columns_list(args: argparse.Namespace) -> list[str]:
    sql = (
        "SELECT attname FROM pg_attribute "
        f"WHERE attrelid = {_table_regclass_literal(args.table)} "
        "AND attnum > 0 AND NOT attisdropped "
        "AND attgenerated = '' "
        "ORDER BY attnum"
    )
    raw = _psql_query(args, sql)
    cols = [line.decode() for line in raw.split(b"\0") if line]
    # --exclude-columns strips derived/bulky columns (e.g. pgvector
    # `embedding`) from the dump. They're reconstituted on restore, so
    # backups carry only the source-of-truth columns. The pk column is
    # never excludable — chunking + restore both key off it.
    exclude = set(getattr(args, "exclude_columns", None) or [])
    if exclude:
        if args.pk_column in exclude:
            raise ValueError(
                f"--exclude-columns may not contain the pk column "
                f"{args.pk_column!r}"
            )
        cols = [c for c in cols if c not in exclude]
    return cols


def _copy_header(args: argparse.Namespace, columns: list[str]) -> bytes:
    cols = ", ".join(_quote_ident(c) for c in columns)
    return f"COPY {_qualified_table_expr(args.table)} ({cols}) FROM stdin;\n".encode()


def _copy_footer() -> bytes:
    return b"\\.\n"


def _dump_full_table(args: argparse.Namespace, columns: list[str],
                     order_cols: list[str] | None = None) -> list[bytes]:
    """Dump table rows as COPY text data, ordered by the chunking key.

    COPY text escapes tabs, newlines, and backslashes in field data, so
    rows can be replayed through psql without psql seeing payload text
    like `\"` as a client metacommand.
    """
    table_expr = _qualified_table_expr(args.table)
    select_cols = ", ".join(_quote_ident(c) for c in columns)
    order_expr = ", ".join(_quote_ident(c) for c in (order_cols or [args.pk_column]))
    sql = f"COPY (SELECT {select_cols} FROM {table_expr} ORDER BY {order_expr}) TO STDOUT"
    cmd = [
        _psql_path(args),
        "--host", args.psql_host,
        "--port", str(args.psql_port),
        "--username", args.psql_user,
        "--dbname", args.psql_database,
        "--no-psqlrc",
        "--quiet",
        "-c", sql,
    ]
    result = subprocess.run(cmd, check=True, capture_output=True)
    return result.stdout.splitlines()


def _pk_from_copy_row(line: bytes, pk_col_idx: int) -> bytes:
    fields = line.split(b"\t")
    if pk_col_idx >= len(fields):
        raise ValueError(f"could not extract pk col {pk_col_idx} from: {line[:120]!r}")
    return fields[pk_col_idx]


def _load_rotation(out_dir: Path) -> dict[str, Any]:
    rot_path = out_dir / ".rotation.json"
    if rot_path.exists():
        return json.loads(rot_path.read_text())
    return {"chunks": []}


def _save_rotation(out_dir: Path, rotation: dict[str, Any]) -> None:
    rot_path = out_dir / ".rotation.json"
    rot_path.write_text(json.dumps(rotation, indent=2, sort_keys=True) + "\n")


def _write_chunk_atomic(
    path: Path,
    body_lines: list[bytes],
    header: bytes,
    footer: bytes,
) -> int:
    """Write a chunk file atomically. Returns bytes written."""
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "wb") as f:
        f.write(header)
        for line in body_lines:
            f.write(line)
            f.write(b"\n")
        f.write(footer)
    size = tmp.stat().st_size
    tmp.replace(path)
    return size


def _chunk_body_size(body_lines: list[bytes], header: bytes, footer: bytes) -> int:
    return len(header) + sum(len(line) + 1 for line in body_lines) + len(footer)


def _bucket_into_chunks(
    rows: list[bytes],
    pk_col_idx: int,
    rotation: dict[str, Any],
) -> dict[int, list[bytes]]:
    """Assign each INSERT line to a chunk number based on the frozen
    rotation boundaries. Lines with PK ≤ chunks[0].max_pk go in 1;
    lines with PK > chunks[N-1].max_pk go in N+1 (the current chunk).
    """
    buckets: dict[int, list[bytes]] = {}
    chunks = rotation["chunks"]
    frozen_max_pks = [c["max_pk"].encode() for c in chunks]
    next_chunk_after_frozen = len(chunks) + 1

    for line in rows:
        pk_unquoted = _pk_from_copy_row(line, pk_col_idx)
        chunk_num = next_chunk_after_frozen
        for i, max_pk in enumerate(frozen_max_pks):
            if pk_unquoted <= max_pk:
                chunk_num = i + 1
                break
        buckets.setdefault(chunk_num, []).append(line)
    return buckets


def _initial_chunking(
    rows: list[bytes],
    pk_col_idx: int,
    target_bytes: int,
    header: bytes,
    footer: bytes,
) -> dict[str, Any]:
    """First-run helper: walk inserts in PK order, accumulating bytes,
    cut a chunk boundary every time we cross target_bytes. Returns
    a rotation dict describing the frozen chunks (the final partial
    bucket is the "current" chunk and is NOT recorded as frozen).
    """
    rotation: dict[str, Any] = {"chunks": []}
    current_bytes = len(header) + len(footer)
    last_pk: bytes | None = None
    for line in rows:
        line_bytes = len(line) + 1  # +1 for the trailing \n we'll write
        if current_bytes + line_bytes > target_bytes and last_pk is not None:
            # Close this chunk at the previous PK.
            pk_str = last_pk.decode() if isinstance(last_pk, bytes) else last_pk
            rotation["chunks"].append(
                {"num": len(rotation["chunks"]) + 1, "max_pk": pk_str}
            )
            current_bytes = len(header) + len(footer)
        current_bytes += line_bytes
        last_pk = _pk_from_copy_row(line, pk_col_idx)
    # The trailing partial bucket stays open (current chunk).
    return rotation


def _has_oversized_bucket(
    buckets: dict[int, list[bytes]],
    target_bytes: int,
    header: bytes,
    footer: bytes,
) -> tuple[int, int] | None:
    for num, lines in sorted(buckets.items()):
        size = _chunk_body_size(lines, header, footer)
        if size > target_bytes:
            return num, size
    return None


def _remove_stale_chunks(out_dir: Path, live_nums: set[int]) -> None:
    for path in out_dir.glob("*.sql"):
        try:
            num = int(path.stem)
        except ValueError:
            continue
        if num not in live_nums:
            path.unlink()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--psql-host", default="127.0.0.1")
    ap.add_argument("--psql-port", default="5432")
    ap.add_argument("--psql-user", required=True)
    ap.add_argument("--psql-database", required=True)
    ap.add_argument("--table", required=True, help="e.g. public.memory_units")
    ap.add_argument("--pk-column", default="", help="primary-key column name (chunked mode)")
    ap.add_argument(
        "--exclude-columns",
        default="",
        help="comma-separated columns to omit from the dump (e.g. "
        "'embedding'). Reconstituted on restore. May not include the "
        "pk column.",
    )
    ap.add_argument("--out-dir", type=Path, help="chunked layout output dir (pk-range chunks)")
    ap.add_argument(
        "--flat-file",
        type=Path,
        help="write ONE COPY file ordered by --order-by instead of the chunked "
        "layout. For a content-addressed store (restic) chunking "
        "buys nothing; what matters is that rows ARRIVE at the end, so order by "
        "insertion time first.",
    )
    ap.add_argument(
        "--order-by",
        default="",
        help="comma-separated ORDER BY columns for --flat-file (default: every "
        "dumped column, so the file is deterministic even without a key). Put "
        "the insertion-time column first so new rows append.",
    )
    ap.add_argument(
        "--target-bytes",
        type=int,
        default=80 * 1024 * 1024,
        help="rotate when current chunk exceeds this (default: 80 MiB)",
    )
    ap.add_argument(
        "--max-bytes",
        type=int,
        default=95 * 1024 * 1024,
        help="hard safety cap for emitted chunks (default: 95 MiB)",
    )
    ap.add_argument(
        "--pg-dump-path",
        default="pg_dump",
        help="path to pg_dump (default: PATH lookup). Set to e.g. "
        "/home/x/.pg0/installation/18.1.0/bin/pg_dump for pg0 embedded.",
    )
    args = ap.parse_args()
    args.exclude_columns = [
        c.strip() for c in args.exclude_columns.split(",") if c.strip()
    ]

    if args.flat_file is None and args.out_dir is None:
        print("[chunked-dump] ERROR: one of --out-dir / --flat-file is required", file=sys.stderr)
        return 2
    cols = _columns_list(args)
    if args.flat_file is not None:
        order_cols = [c.strip() for c in args.order_by.split(",") if c.strip()] or list(cols)
        missing = [c for c in order_cols if c not in cols]
        if missing:
            print(f"[chunked-dump] ERROR: --order-by columns {missing} not in {cols}", file=sys.stderr)
            return 2
        rows = _dump_full_table(args, cols, order_cols)
        args.flat_file.parent.mkdir(parents=True, exist_ok=True)
        size = _write_chunk_atomic(args.flat_file, rows, _copy_header(args, cols), _copy_footer())
        print(f"[chunked-dump] {args.table}: {len(rows)} rows -> {args.flat_file} ({size} bytes, order {','.join(order_cols)})")
        return 0
    out_dir: Path = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    # 1. Dump the table to a flat sorted COPY-data row list.
    try:
        pk_col_idx = cols.index(args.pk_column)
    except ValueError:
        print(
            f"[chunked-dump] ERROR: pk column {args.pk_column!r} not in {cols}",
            file=sys.stderr,
        )
        return 2
    header = _copy_header(args, cols)
    footer = _copy_footer()

    rows = _dump_full_table(args, cols)
    if not rows:
        # Empty table — write a placeholder file so restore concat
        # doesn't fail, clear rotation.
        (out_dir / "0001.sql").write_bytes(header + footer)
        _save_rotation(out_dir, {"chunks": []})
        print(f"[chunked-dump] {args.table}: empty table; wrote 0001.sql empty")
        return 0

    if args.target_bytes >= args.max_bytes:
        print(
            f"[chunked-dump] ERROR: target-bytes ({args.target_bytes}) must be "
            f"less than max-bytes ({args.max_bytes})",
            file=sys.stderr,
        )
        return 2

    biggest_line = max(len(line) + 1 + len(header) + len(footer) for line in rows)
    if biggest_line > args.max_bytes:
        print(
            f"[chunked-dump] ERROR: one row is {biggest_line} bytes, above "
            f"max-bytes {args.max_bytes}; cannot create a pushable chunk",
            file=sys.stderr,
        )
        return 3

    # 3. Load (or initialize) rotation.
    rotation = _load_rotation(out_dir)
    if not rotation["chunks"]:
        # First run: derive initial chunk boundaries from current data.
        rotation = _initial_chunking(rows, pk_col_idx, args.target_bytes, header, footer)

    # 4. Bucket lines into chunks per the rotation.
    buckets = _bucket_into_chunks(rows, pk_col_idx, rotation)
    oversized = _has_oversized_bucket(buckets, args.target_bytes, header, footer)
    if oversized:
        num, size = oversized
        print(
            f"[chunked-dump] {args.table}: chunk {num:04d} is {size} bytes, "
            f"above {args.target_bytes} target; repairing rotation."
        )
        rotation = _initial_chunking(rows, pk_col_idx, args.target_bytes, header, footer)
        buckets = _bucket_into_chunks(rows, pk_col_idx, rotation)

    # 5. Write every chunk that has content. Also blank out any
    # leftover files for chunk numbers not in `buckets` (defensive:
    # a table-wide delete could empty an entire chunk, or a repair
    # pass could produce fewer chunks than the old layout).
    chunks_to_write = sorted(buckets.keys())
    for num in chunks_to_write:
        path = out_dir / f"{num:04d}.sql"
        size = _write_chunk_atomic(path, buckets[num], header, footer)
        if size > args.max_bytes:
            print(
                f"[chunked-dump] ERROR: {path} is {size} bytes, above "
                f"max-bytes {args.max_bytes}",
                file=sys.stderr,
            )
            return 3
    _remove_stale_chunks(out_dir, set(chunks_to_write))

    # 7. Persist rotation state.
    _save_rotation(out_dir, rotation)

    # 8. Summary print for cron log.
    total_rows = len(rows)
    sizes = []
    for num in chunks_to_write:
        path = out_dir / f"{num:04d}.sql"
        sizes.append((num, path.stat().st_size))
    summary = ", ".join(f"{n:04d}={s}b" for n, s in sizes)
    print(f"[chunked-dump] {args.table}: {total_rows} rows, chunks: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
