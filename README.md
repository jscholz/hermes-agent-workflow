# hermes-agent-workflow

A public template for deploying a personal AI assistant stack
(hermes-agent + parley PWA + audio bridge) on your own hardware,
**with your full agent state versioned in your own private fork** —
encrypted, snapshotted, and restorable on a fresh machine.

Early, working, opinionated. Not a polished product.

---

## §1 — What is this?

A turnkey workflow for running [`hermes-agent`](https://github.com/NousResearch/hermes-agent)
+ [`parley`](https://github.com/jscholz/parley) on your own box,
where your fork of *this* repo holds:

- The hermes config + system prompt + AGENTS hint-file
- Your accumulated **memories** (what hermes recalls about you)
- Your **skills** tree (vendored upstream + your edits + agent-authored skills)
- Your **encrypted secrets** (`.env`, OAuth tokens, WhatsApp session)
- Your **encrypted state backups** (sqlite session/message history,
  Parley UI state, hindsight memory bank dump) on a daily cron
- Per-host overrides under `hosts/<your-host>/`

`scripts/bootstrap.sh` lays a symlink tree at `~/.hermes/` that
points back into your fork. From that point on, `git push` from any
machine snapshots the agent's full state; `git clone` + bootstrap on
a new machine restores it. Lose the hardware, get it back.

---

## §2 — What gets versioned in your fork

This is the load-bearing table. Read it carefully — anything not
listed here is **not** in your backup. The columns:

- **Path** — where it lives in your fork.
- **Symlinked to** — where in `~/.hermes/` the live copy is, after
  bootstrap.
- **Encrypted** — yes if covered by a `.gitattributes` rule, no
  otherwise.
- **Scope** — `shared` if used by every host, `per-host` if scoped
  under `hosts/<host>/`.

| Path                                  | Symlinked to                          | Encrypted | Scope    | Notes |
| ------------------------------------- | ------------------------------------- | --------- | -------- | ----- |
| `config.yaml` (from `example.config.yaml`) | `~/.hermes/config.yaml`           | no        | shared   | Hermes runtime config: model, platform_toolsets, gateway, voice. |
| `AGENTS.md` (from `example.AGENTS.md`)| `~/.hermes/AGENTS.md`                 | no        | shared   | Tool-routing hints the running agent reads each session. Edit freely. |
| `SOUL.md`   | `~/.hermes/SOUL.md`                   | no        | shared   | Your agent's persona / system-prompt prefix. |
| `hindsight/config.json` (from `example.hindsight.config.json`) | `~/.hermes/hindsight/config.json` | no | shared | Local hindsight client config. |
| `memories/`                           | `~/.hermes/memories/`                 | **yes**   | shared   | Append-only memory store the agent grows. Encrypted in private forks; public repo keeps only placeholders plaintext. |
| `skills/`                             | `~/.hermes/skills/`                   | no        | shared   | Skills tree. Vendored upstream snapshot + your edits + agent-authored skills. See §4. |
| `cron/`                               | `~/.hermes/cron/`                     | mixed     | shared   | Hermes's own cron entries. `cron/jobs.json` and `cron/output/**` are encrypted; examples/placeholders are plaintext. |
| `hooks/`                              | `~/.hermes/hooks/`                    | no        | shared   | Pre/post-turn hooks. |
| `plugins/`                            | `~/.hermes/plugins/`                  | no        | shared   | Hermes plugins. |
| `hermes-runtime-scripts/`             | `~/.hermes/scripts/`                  | no        | shared   | Agent-runtime callables — cron-driven Python scripts, skill helpers. See [its README](hermes-runtime-scripts/README.md). Distinct from `scripts/` at the repo root (install/sync helpers). |
| `workspace/`                          | (referenced from skills, not symlinked into `~/.hermes/`) | optional | shared | Personal documents the agent reads/writes. Add to `.gitattributes` if you want it encrypted. |
| `.env`                                | `~/.hermes/.env`                      | **yes**   | shared   | API keys (OpenRouter, Deepgram, Tavily, Anthropic). |
| `auth.json`                           | `~/.hermes/auth.json`                 | **yes**   | shared   | Parley / hermes auth state. |
| `google_client_secret.json`           | `~/.hermes/google_client_secret.json` | **yes**   | shared   | Google OAuth client (if you wire up Gmail / Calendar). |
| `google_token.json`                   | `~/.hermes/google_token.json`         | **yes**   | shared   | Google OAuth refresh tokens. |
| `gogcli/**`                           | `~/.config/gogcli/`                   | **yes**   | shared   | gog CLI account config, OAuth credentials, keyring tokens, and keyring password. |
| `whatsapp/session/**`                 | `~/.hermes/whatsapp/session/`         | **yes**   | shared   | Baileys session credentials. Losing these means QR-rescan from the phone. |
| `pairing/**`                          | `~/.hermes/pairing/`                  | **yes**   | shared   | Parley PWA pairing tokens. |
| `sessions/**`                         | (export target from Hermes CLI)       | **yes**   | shared   | Exported Hermes session transcripts from `scripts/sync-hermes.sh`. |
| `hindsight-data/<table>.sql` + `hindsight-data/<bulk-table>/NNNN.sql` | (restore target: hindsight Postgres)  | **yes**   | shared   | Daily per-table `pg_dump` of the hindsight memory bank. Bulk tables (memory_units, memory_links) are byte-rotated into NNNN.sql chunks ≤ 80 MB each so the dump fits under GitHub's 100 MB per-blob cap; small tables stay single files. See §5. |
| `hermes-data/schema.sql` + `hermes-data/<table>.sql` + `hermes-data/messages/NNNN.sql` | (restore target: `~/.hermes/state.db`) | **yes**  | shared   | Daily sqlite dump of `state.db` (sessions, messages, schema_version, state_meta). `messages` is byte-rotated into NNNN.sql chunks (see scripts/lib/chunked-sqlite-dump.py); small tables stay single files. See §5. |
| `parley-data/parley.sql`          | (restore target: `~/.hermes/parley.db`) | **yes** | shared | Daily sqlite dump of Parley supplemental UI state: custom titles, pins, push subscriptions/preferences, unread/activity state, VAPID keys, and UI-facing message rows. See §5. |
| `hosts/<host>/claude-code-memory/`    | `~/.claude/projects/<proj>/memory/`   | **yes**   | per-host | Per-host Claude Code memory dir, including `RESUME.md`. |
| `hosts/<host>/claude-code-history/`   | (snapshotted from `~/.claude/projects/<proj>/*.jsonl`) | **yes** | per-host | Compressed Claude Code session transcripts. Pruned on a cron. |
| `ACTIVE_HOST`                         | (sentinel — not symlinked)            | no        | shared   | Which host is the current writer (see §7). |

**Two design choices baked into this table:**

1. **Runtime-private state is encrypted in real forks.**
   Memories, host state, transcripts, secrets, OAuth tokens, and DB
   dumps are all git-crypt-protected once the clone is promoted to a
   private repo. Public placeholders stay plaintext so this template is
   readable.
2. **The symlink layout is one-tier.** `~/.hermes/skills/` IS your
   fork's `skills/` directory — not a writable user copy that
   shadows a read-only catalog. This means edits the agent makes at
   runtime land directly in your fork's working tree. See §3.

---

## §3 — The symlink pattern

`hermes-agent` is a Python package. Installed normally, mutable user
state — your skills, memories, config, OAuth tokens — accumulates in
`~/.hermes/` alongside the package's installed files. That makes
"version my agent state" awkward: you don't want to version the
whole install, just your data within it. And you don't want
`pip install -U` quietly overwriting a memory you've curated.

This template solves it with a symlink tree. After `scripts/bootstrap.sh`
runs:

```
~/.hermes/
├── config.yaml          → <repo>/config.yaml
├── AGENTS.md            → <repo>/AGENTS.md
├── SOUL.md              → <repo>/SOUL.md
├── memories/            → <repo>/memories/         (real dir)
├── skills/              → <repo>/skills/           (real dir)
├── cron/                → <repo>/cron/             (real dir)
├── hooks/               → <repo>/hooks/            (real dir)
├── plugins/             → <repo>/plugins/          (real dir)
├── whatsapp/            → <repo>/whatsapp/         (real dir, encrypted)
├── pairing/             → <repo>/pairing/          (real dir, encrypted)
├── .env                 → <repo>/.env              (encrypted)
├── auth.json            → <repo>/auth.json         (encrypted)
├── hindsight/config.json → <repo>/hindsight/config.json
├── state.db             ← live sqlite, NOT symlinked (see §5 + §6)
└── parley.db          ← live sqlite, NOT symlinked (see §5 + §6)
```

Three helpers in `bootstrap.sh` build this:

- `link_template <src.example> <dst>` — for files where the repo
  ships a `*.example` template and the live file becomes a symlink
  pointing back to the example after first install. Edits flow back
  into your fork.
- `link_dir <src> <dst>` — for whole directories. The repo dir is
  the live dir.
- `link_secret <src> <dst>` — for git-crypt-protected files. Same
  semantics as `link_template` but no-op until the file exists, so
  bootstrap doesn't fail before you've added secrets.

If you re-run bootstrap after upstream changes, existing symlinks
are left in place; new ones from new entries get added. Idempotent.

---

## §4 — Skills_sync: how upstream skill upgrades land safely

Because `skills/` is your own directory (you edit it; the agent
edits it), upstream skill upgrades can't just blast in. They go
through `tools/skills_sync.py`, which ships with hermes-agent and
runs as part of `hermes update`.

The mechanism, briefly:

1. Every install records a `.bundled_manifest` at `~/.hermes/skills/.bundled_manifest`
   — a per-skill MD5 of what was bundled with hermes-agent at last sync.
2. When upstream ships new skill content (a `pip install -U
   hermes-agent` brings in a new bundled snapshot under the package
   dir), `skills_sync.py` walks each skill and asks:
   - **New skill** (not in your tree at all)? Copy it in.
   - **Existing skill, hash matches the bundled manifest?** You haven't
     touched it. Refresh from the new bundled version.
   - **Existing skill, hash differs?** You've customized it. **Skip.**
     Your version stays. Upstream's is logged but not applied.
3. Skill-authored content (skills the agent itself wrote at runtime)
   is invisible to upstream — it's just in your tree, not in any
   manifest, never overwritten.

There is **no line-level merge**. The granularity is whole-skill.
Conservative-by-design — if you've edited a skill, you keep it
verbatim until you decide to reconcile manually.

The flip side: if you want upstream's *new* version of a skill you
previously customized, you have to merge it in by hand (or revert
your customizations and let `skills_sync` re-pull it on the next
upgrade). The script's job is to never *destroy* your work, not to
auto-resolve every case.

---

## §5 — Encrypted backup model

Three things in your install are too big to live in your repo as
ordinary files but too important to lose: the **hindsight memory
bank** (Postgres), the **hermes state.db** (sqlite — sessions,
messages, FTS indexes), the **Parley parley.db** (sqlite — UI
metadata and notification state), and **agent secrets** (`.env`,
OAuth tokens, WhatsApp session). The model:

| Asset                    | How it's captured           | Where it lands           | Cron                              | Restore script |
| ------------------------ | --------------------------- | ------------------------ | --------------------------------- | -------------- |
| Hindsight Postgres DB    | per-table `pg_dump` + byte-rotated chunks for the bulk tables (see scripts/lib/chunked-table-dump.py) | `hindsight-data/<table>.sql` + `hindsight-data/<bulk>/NNNN.sql` (encrypted) | `cron/sync-hindsight-bank.cron.example` | `scripts/restore-hindsight-bank.sh` |
| `~/.hermes/state.db`     | `.backup` (atomic) → schema dump + per-table data dumps, with `messages` byte-rotated into chunks (see scripts/lib/chunked-sqlite-dump.py) | `hermes-data/schema.sql` + `hermes-data/<table>.sql` + `hermes-data/messages/NNNN.sql` (encrypted) | `cron/sync-hermes-state.cron.example` | `scripts/restore-hermes-state.sh` |
| `~/.hermes/parley.db`  | `.backup` (atomic) → `.dump` | `parley-data/parley.sql` (encrypted) | `cron/sync-parley-db.cron.example` | `scripts/restore-parley-db.sh` |
| Live secrets             | symlinked into repo         | `.env`, `auth.json`, etc. (encrypted) | (instant — every git push) | git pull |

Daily-dump crons are **off by default**. Opt in by:

1. Confirming you've initialized git-crypt (you can't push
   meaningful encrypted backups without it).
2. Confirming `git push` from cron actually works (SSH agent
   forwarding or a deploy key — cron is non-interactive).
3. Editing `cron/*.cron.example`, replacing `REPO_PATH` with your
   absolute clone path, and adding the line via `crontab -e`.

The chunked dump layout keeps the encrypted history small on its
own: frozen chunks stay byte-identical across runs, so git's
pack-delta collapses each daily snapshot to roughly the size of the
rows that actually changed. No history rewriting is needed.

**Restore on a fresh machine** is a single sequence:

```bash
git clone <your-fork>
cd <your-fork>
echo '<base64-key>' | base64 -d | git-crypt unlock -
./scripts/bootstrap.sh        # rebuilds the symlink tree
./scripts/restore-hermes-state.sh --yes   # applies schema + replays data chunks
./scripts/restore-parley-db.sh --yes    # replays parley.sql
./scripts/restore-hindsight-bank.sh       # cats per-table + chunked .sql into psql
```

`bootstrap.sh` writes a sentinel at `~/.hermes/.bootstrap.complete`
so re-runs and Claude-driven installs can detect prior state.

---

## §6 — What does NOT get versioned

By design, several things are excluded from your fork:

- **Live `~/.hermes/state.db`** — too big, written every turn,
  derivable from the `hermes-data/` dumps plus replay. The dump
  captures the conversation tables; FTS5 indexes are rebuilt by
  `restore-hermes-state.sh`.
- **Live `~/.hermes/parley.db`** — written by the Parley/Hermes
  UI adapter. It is restored from `parley-data/parley.sql`; do not
  symlink the live DB because SQLite WAL writers need a local file.
- **`~/.hermes/cache/` and `~/.hermes/logs/`** — derivable.
- **`~/.hermes/kanban.db`, `~/.hermes/response_store.db`** —
  per-host scratch state. Restore would be wrong, not just
  unnecessary.
- **Live hindsight Postgres data dir** — restored from the dump,
  not the data files.
- **`~/.hermes/hermes-agent/` (the installed package)** — `pip
  install -U hermes-agent` is the source of truth.
- **Parley `node_modules/` / `bun.lockb` / `dist/`** — built on
  install.
- **Claude Code `.jsonl` transcripts older than the prune horizon**
  — kept compressed in `hosts/<host>/claude-code-history/` for
  ~30 days, pruned after.

If you find a host file you want versioned that's not on the list,
add a `.gitattributes` rule (encryption optional) and a
`link_template` / `link_dir` call in `bootstrap.sh`.

---

## §7 — Multi-host parity (v1 = single ACTIVE_HOST)

The repo includes an `ACTIVE_HOST` sentinel at the repo root with a
single line:

```
active_host=<hostname>
```

Sync scripts (`sync-hermes-state.sh`, `sync-hindsight-bank.sh`)
and `sync-parley-db.sh` **refuse to run on any host where `$(hostname)` doesn't match**.
This prevents two machines from racing on the same backup branch
and producing merge conflicts in encrypted blobs (which are
miserable to resolve).

The intended pattern in v1: one machine is "live," others are cold
spares. To switch active hosts, run `scripts/handoff-out.sh` on the
current active host, then `scripts/handoff-in.sh` on the new host.
Those scripts final-sync Hermes state, Parley UI state, and the
Hindsight bank; stop/start services; update `ACTIVE_HOST`; and run a
small smoke test. Concurrent multi-host (sync deltas, hindsight
sharded by host, etc.) is a v2 problem.

---

## §8 — Installation

**Recommended path: ask your local Claude Code to install for you.**

```bash
# from a machine with `claude` (Claude Code) on $PATH
mkdir -p ~/code && cd ~/code
git clone https://github.com/jscholz/hermes-agent-workflow.git
cd hermes-agent-workflow
claude
> install this for me
```

Claude reads [`CLAUDE.md`](./CLAUDE.md) — the install conductor — and
walks you through everything: prerequisites check, fork creation,
git-crypt init/unlock, secrets prompts, `scripts/bootstrap.sh`
invocation, doctor verification, optional parley + claude-remote +
daily-dump cron. Each step probes state first, asks before doing
anything destructive, and is safe to interrupt and resume.

**Manual path** (no Claude in the loop), public-template validation:

```bash
git clone https://github.com/jscholz/hermes-agent-workflow.git
cd hermes-agent-workflow
./scripts/bootstrap.sh
```

To turn that validation install into a real restorable agent, promote it
to a private repo and install the versioning crons:

```bash
./scripts/promote-private-fork.sh \
  --repo YOUR_GITHUB_USER/my-agent-private \
  --create-github \
  --new-key-out ~/my-agent-private.git-crypt.key \
  --rerun-bootstrap \
  --install-crons
```

See [PRIVATE_FORK.md](PRIVATE_FORK.md) for the full finish-line flow,
including reusing an existing git-crypt key across multiple private
agents.

`bootstrap.sh` is the workhorse either way — Claude just gathers
inputs and invokes it with `--env-file`. Read the script first;
it's commented.

Direct installs from `github.com/jscholz/hermes-agent-workflow` are
treated as public-template validation installs: host-local Claude Code
memory is kept under `~/.hermes/host-state/<host>/` so the public
checkout stays clean. In a fork, bootstrap uses the versioned
`hosts/<host>/` path by default. Override with
`HERMES_WORKFLOW_HOST_STATE_MODE=local` or `versioned` if needed.

The default fresh-install path uses `OPENAI_API_KEY` for Hermes model
access and for the local Hindsight memory server. Parley is served on
local HTTP behind Tailscale Serve when Tailscale is available, giving a
browser-trusted `https://<host>.<tailnet>.ts.net:3001/` URL without a
self-signed certificate warning. Access control for that URL is your
tailnet ACL; restrict `<host>:3001` there if the agent should be
user-only on a wider tailnet. Bootstrap installs, enables, and starts
the user-level systemd services so the stack comes back after reboot
when user lingering is enabled for the account. Those units also set
`HERMES_BUNDLED_SKILLS` to the workflow-managed skills tree so normal
service startup does not rewrite the checkout when upstream Hermes
bundled skills drift.

---

## §9 — Updating

To pick up upstream changes to this template:

```bash
cd ~/code/hermes-agent-workflow
git fetch upstream
git merge upstream/main
./scripts/bootstrap.sh        # idempotent — adds new symlinks, leaves existing
```

To pick up a new hermes-agent version (and bring in new bundled
skills via `skills_sync`):

```bash
hermes update       # or whatever your package manager calls it
# this triggers tools/skills_sync.py against ~/.hermes/skills/
git status          # see what changed
```

Review the diff. Skills you'd customized are preserved (§4); new
upstream skills appear; refreshes to skills you never touched are
auto-adopted. Commit + push to your fork.

See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for the framework /
instance file ownership rules and the upstream-PR workflow.

---

## §10 — Troubleshooting

**`git-crypt unlock` says "this repo is not encrypted"** — you're
on a fresh fork that nobody's ever run `git-crypt init` on. That's
fine; secrets just aren't encrypted yet. Run `git-crypt init`
yourself, export + back up the key, then add secrets.

**`bootstrap.sh` complains about a missing template** — likely
your fork is behind upstream. `git fetch upstream && git merge
upstream/main` and re-run.

**`doctor.sh` reports a broken symlink under `~/.hermes/`** —
either bootstrap didn't finish, or the target file got deleted.
`rm ~/.hermes/<broken-link>` and re-run bootstrap; it'll re-link.

**State backup cron isn't pushing** — cron has no SSH agent. Either
configure a deploy key for your fork, or arrange `ssh-agent` such
that the cron user can `git push` non-interactively. Test with
`bash -lc 'cd <repo> && git push'` from a non-login shell first.

**Hermes gateway won't start** — `journalctl --user -u
hermes-gateway -n 100 --no-pager`. Most common: missing API key in
`~/.hermes/.env`, or git-crypt not unlocked so `.env` is still
ciphertext.

**Restored state.db has empty FTS results** — `restore-hermes-state.sh`
rebuilds the FTS5 indexes; if you imported the dumps by hand,
re-run that script with `--yes` (idempotent).

For anything else: open an issue with `doctor.sh` output and a
sanitized snippet of the failing logs.

---

## Architecture

```
   browser / iOS PWA
         |
         v
  [ parley ]            <- PWA + Bun proxy + Python audio bridge
   github.com/jscholz/parley
         |
         |  HTTP + WebRTC
         v
  [ hermes-agent ]         <- Python agent runtime
   gateway, skills, plugins, cron
         |
         v
  [ hindsight ]            <- memory backend (Postgres + FastAPI)
```

- **parley** is the user-facing surface: PWA, Node-served proxy at
  `/api/hermes/*`, and an optional audio bridge for low-latency voice
  in/out via Deepgram. The Hermes integration is the Parley plugin
  shipped in the parley repo under `backends/hermes/plugin`.
- **hermes-agent** runs the actual agent loop, skills, and tool
  calls. It exposes the OpenAI-compatible `/v1/responses` interface
  that parley speaks to.
- **hindsight** stores recallable memory; hermes calls it as a skill.
- **This repo** is the glue: config, systemd units, the bootstrap
  wizard, encrypted backup scripts, and per-host overrides under
  `hosts/<host>/`.

---

## Requirements

- **OS**: Linux (Pi 5 / Ubuntu / Debian validated). macOS support is
  pending.
- **Python**: 3.11 or newer.
- **Node**: 20 or newer (parley proxy, claude-code).
- **`uv`**, **`git`**, **`git-crypt`**, **`gh`**, **`ffmpeg`**,
  **`tmux`** on `$PATH`. The bootstrap script checks each and tells
  you what's missing.
- **API keys**: OpenAI (LLM + Hindsight memory defaults), Deepgram
  (audio, optional), OpenRouter (optional alternate LLM provider),
  Tavily (web search, optional).
- **Audio bridge**: installed by default when the Parley checkout
  includes `audio-bridge/`. On ARM/Pi hosts, bootstrap skips the
  optional `silero-vad` Torch dependency by default so Deepgram STT/TTS
  works without pulling multi-GB ML packages. Set
  `INSTALL_PARLEY_AUDIO_BARGE_VAD=1` only when you explicitly want
  bridge-side barge VAD on that host.

---

## Status

**v0.1, early.** Built and validated on Pi 5 + x86 Ubuntu
deployments, opening to a small group of contributors. Expect:

- Sharp edges in the bootstrap wizard, especially on macOS.
- Framework / instance boundaries that are still being tightened.
- WebRTC audio behavior that's been validated on ARM Linux + x86
  but not yet on Mac.

Issues, PRs, and "this didn't work for me" reports are all welcome.

---

## License

[Apache License 2.0](./LICENSE) — matching the parley repo.

## Acknowledgments

- [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) — upstream agent runtime.
- [jscholz/parley](https://github.com/jscholz/parley) — PWA + proxy + audio bridge.
- [jscholz/hermes-agent](https://github.com/jscholz/hermes-agent) — fork where local patches land before they're proposed upstream.
