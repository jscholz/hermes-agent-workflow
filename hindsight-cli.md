# Hindsight CLI cheatsheet

Quick-reference commands for poking at the long-term memory system from
the terminal. Useful when you want to see what the agent knows, what it
just learned, how big the memory bank has grown, etc — without going
through the agent itself.

The slim hindsight server runs as `hindsight-server.service` (systemd
user unit) on port 8765. Bank name is `default`. All commands below
assume those defaults; adjust if you spin up a second bank later.

---

## Where the data lives

| What | Where |
|---|---|
| Live API server | `http://127.0.0.1:8765` (loopback only) |
| Bank ID | `default` |
| Postgres data dir (pg0, embedded) | `~/.hermes/hindsight/pg0/` |
| Bank dump backups | `~/.hermes/hindsight/bank-dumps/` (daily cron at 03:33) |
| Hindsight config | `~/.hermes/hindsight/config.json` (mode=local_external, reranker=rrf) |
| Server log | `~/.hermes/logs/hindsight-embed.log` |
| systemd | `systemctl --user status hindsight-server` |

---

## Health & version

```bash
curl -fsS http://127.0.0.1:8765/health
# {"status":"healthy","database":"connected"}

curl -fsS http://127.0.0.1:8765/version | jq
# {"version":"0.5.4", ...}
```

If `/health` fails, the gateway's hindsight calls will time out (you
saw this exact symptom in the agent.log earlier). Doctor.sh checks it.

---

## List banks

```bash
curl -s http://127.0.0.1:8765/v1/default/banks | jq
```

You should see one bank — `default`. If you ever want a sandbox bank
for friends or experiments, this is where they'd appear.

---

## List recent memories

```bash
# Most recent 20 memories in the default bank
curl -s 'http://127.0.0.1:8765/v1/default/banks/default/memories/list?limit=20' | jq

# Just the text + date (compact view)
curl -s 'http://127.0.0.1:8765/v1/default/banks/default/memories/list?limit=20' \
  | jq '.items[] | {date, text}'

# Filter: only memories from today
curl -s 'http://127.0.0.1:8765/v1/default/banks/default/memories/list?limit=200' \
  | jq --arg today "$(date -u +%Y-%m-%d)" \
       '.items[] | select(.date | startswith($today)) | {date, text}'
```

This is the simplest "what does the agent know about me?" probe. Each
item has:
- `text` — the canonical memory line
- `date` — when it was retained (UTC)
- `fact_type` — `world` (general fact) vs `observation` (situational)
- `proof_count` — how many distinct turns reinforced this fact
- `entities`, `tags` — auto-extracted
- `consolidated_at` — null until the consolidation pass folds related
  facts together (that's why some show null and some show a timestamp)

---

## Read a single memory + its provenance

```bash
# Full record
curl -s 'http://127.0.0.1:8765/v1/default/banks/default/memories/<MEMORY_ID>' | jq

# History — every turn that touched this memory (retain, consolidate, etc)
curl -s 'http://127.0.0.1:8765/v1/default/banks/default/memories/<MEMORY_ID>/history' | jq
```

The `history` endpoint is the audit trail: which conversation introduced
this fact, when consolidation merged it with another, etc.

---

## Recall (semantic search)

This is the same query path the agent uses internally on every turn
(prefetch_method=recall in the config). Useful for testing: "would
the agent surface X if I asked Y?"

```bash
# Search for memories about a topic
curl -s -X POST 'http://127.0.0.1:8765/v1/default/banks/default/memories/recall' \
  -H 'content-type: application/json' \
  -d '{"query":"interaction video","limit":5}' | jq

# Just the hits, compact
curl -s -X POST 'http://127.0.0.1:8765/v1/default/banks/default/memories/recall' \
  -H 'content-type: application/json' \
  -d '{"query":"who is helping me","limit":10}' \
  | jq '.items[] | {score, text}'
```

The slim server uses RRF (reciprocal rank fusion) over BM25 + a small
keyword model — no torch, no GPU. Fast on a Pi.

---

## Bank size / coarse stats

```bash
# Total memory count (asks for a big page, counts what comes back)
curl -s 'http://127.0.0.1:8765/v1/default/banks/default/memories/list?limit=10000' \
  | jq '.items | length'

# Prometheus-style metrics — request counts, durations, error rates
curl -s http://127.0.0.1:8765/metrics | grep -E '^hindsight_' | head -30

# Disk size of the embedded postgres data dir
du -sh ~/.hermes/hindsight/pg0/

# Latest bank dump (daily snapshot)
ls -lh ~/.hermes/hindsight/bank-dumps/ | tail -3
```

---

## Direct postgres (if you ever need it)

The slim server ships an embedded `pg0` on a unix socket — no TCP
port. To query directly, exec into the embedded psql:

```bash
# Find the socket dir (varies; usually under the data dir)
ls -d ~/.hermes/hindsight/pg0/.s.PGSQL.* 2>/dev/null | head -1

# psql via the daemon's python (uses the same socket)
~/.hermes/hermes-agent/venv/bin/python -c "
import psycopg
conn = psycopg.connect(host=os.path.expanduser('~/.hermes/hindsight/pg0'), dbname='hindsight')
cur = conn.cursor()
cur.execute('SELECT count(*) FROM memories')
print(cur.fetchone())
"
```

You almost never need this — the HTTP API covers everything. Reach
for it only if a memory looks corrupted or you want to bulk-export.

---

## Tagging conventions seen so far

The auto-extractor uses kebab-case tags. Examples already in the bank:

- `r2`, `reimagine-robotics` — work / company context
- `interaction-video`, `content-push` — specific projects
- `mosaic-tile-storyboard`, `owner-scoped` — finer-grained scope
- `sidekick`, `hermes` — toolchain context

Tags are searchable via the recall endpoint (just include the tag in
the query string).

---

## When to suspect a problem

| Symptom | Likely cause |
|---|---|
| Agent answers "I don't have that in memory" but you know it should | Hindsight `/health` failing → `local_external` → check `systemctl --user status hindsight-server` |
| Agent's recall hits feel stale | Consolidation pass hasn't run; check `consolidated_at` field on recent items |
| Memory bank disk grows unexpectedly | Run `du -sh ~/.hermes/hindsight/pg0/` weekly; if spiking, consider a bank dump + truncate cycle |
| Retain timeouts in agent.log | Usually a symptom of the gateway killing the agent task mid-call (see SSE-cancel notes), not a hindsight bug |

---

## See also

- `~/.hermes/hindsight/config.json` — mode, reranker, budget, prefetch_method
- `scripts/sync-hindsight-bank.sh` — daily pg_dump (in this repo)
- Hindsight upstream: https://github.com/zeroclaw-labs/hindsight (public)
- The slim variant we run: hindsight-api-slim (torchless, RRF reranker)
