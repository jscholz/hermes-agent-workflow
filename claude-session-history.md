# claude-session-history.md

You are Claude Code. You just woke up in a `claude-remote` tmux session
on someone's hermes-agent-workflow host. This file is the running
narrative of the project — read it end-to-end before doing anything
else, then acknowledge briefly and tell the user what's on the backlog.

This is **not** a changelog or a tidy doc. It is the warm-start memory
that lets a fresh session pick up where the last one left off.

## What this project is

A claude-code workflow building and maintaining a hermes-agent + parley
deployment, powered by:

- **hermes-agent** — the Python agent runtime (skills, memory, gateway)
  living in `~/.hermes/hermes-agent/`, plus its venv at
  `~/.hermes/hermes-venv/`.
- **parley** — the PWA front end (React + Bun proxy + Python audio
  bridge) at `~/code/parley/`. Public repo:
  `github.com/jscholz/parley`.
- **this template** (`hermes-agent-workflow`) — the deployment shell:
  bootstrap script, systemd units, vendored skills, hermes-agent
  patches, and the framework/instance contract that keeps the rebase
  tax low.

The user owns a fork of this repo; framework files (scripts, systemd
unit templates, vendored skills) come from upstream, and instance files
(config, memories, custom skills, secrets) live in their fork.

## Where to look

When you need to orient on something, start here:

- **`AGENTS.md`** — the operating manual for this repo. Framework /
  instance split, first-run flow, file ownership rules. Read it in
  every session.
- **`README.md`** — the user-facing tour. Quickstart, why-fork, the
  symlink pattern, secrets via git-crypt.
- **`scripts/`** — install + maintenance tools.
  - `bootstrap.sh` — first-run wizard.
  - `apply-patches.sh` — replay hermes-agent patches on top of upstream.
  - `update-workflow.sh` — `git pull` + re-apply patches.
  - `doctor.sh` — health checks.
  - `sync-cc-history.sh` — cron-driven snapshot of Claude Code
    transcripts into the repo.
  - `setup-remote-claude.sh` — install the `claude-remote` shell
    function (this file is what `claude-remote` reads on warm start).
- **`skills/`** — what hermes can do. Vendored upstream skills + the
  user's `user-skills/` (if any).
- **`patches/hermes-agent/`** — the local hermes-agent patches in play.
  See `PATCHES.md` for what each one does.
- **`hosts/<host>/`** — per-machine state (Claude Code transcripts,
  memory snapshots).
- **`~/.hermes/`** — instance home. Config, secrets, runtime state.
  Mostly symlinked back into the repo.

## Maintenance rule (read this before editing)

This file is the **warm-start narrative**. Append to it when something
durable happens — events a future session would benefit from knowing:

- Architecture decisions (and their tradeoffs).
- Non-obvious bug root causes (the "took us 3h to find" kind, not the
  one-liner fix).
- Major features that shipped — include the commit SHA + a one-line
  summary. Don't recap the diff, just enough to recognize the milestone.
- Config changes that would surprise someone reading the codebase cold.

What this file is **not**:

- A changelog. Don't write it for tooling, write it for the next agent.
- A diary. Skip routine work and tactical fixes.
- A duplicate of `AGENTS.md` or `PATCHES.md` — link to those, don't
  restate.

Keep entries terse, chronological, **most recent at the bottom**.
Update the "Last updated" line on every meaningful edit. If you're
unsure whether an event qualifies, ask the user.

## Rehydrate protocol — what to read on resume

When a Claude Code session resumes (after `/compact`, host crash,
claude-remote rebind, or a fresh `claude-remote` invocation), read
these files in order before doing anything else:

1. **This file** (`claude-session-history.md`) — long-form, durable
   project narrative. The "what happened to date" record.
2. **`hosts/<your-host>/claude-code-memory/RESUME.md`** — live cursor
   on the in-flight conversation, refreshed every meaningful turn.
   The "what we were just doing" record. If its timestamp is stale
   (>1h old), tail the latest `.jsonl` it points at for verbatim
   context recovery.
3. **`hosts/<your-host>/claude-code-memory/MEMORY.md`** — auto-loaded
   index of feedback/preferences. Anything indexed there is loaded
   automatically by Claude Code on session start, so reading it tells
   you what context Claude already has.

The discipline that keeps RESUME.md current is documented in
`hosts/<your-host>/claude-code-memory/feedback_resume_protocol.md`
(seeded from `templates/claude-code-memory/` by `bootstrap.sh`).
Refresh RESUME.md after each meaningful exchange — that's how
mid-session crash recovery stays cheap.

## Narrative

(no entries yet — this is a fresh deployment of the workflow template)

## Decision log

A brief table for "why we did it this way" entries. Append rows; do
not edit existing ones unless the underlying decision actually changed.

| Date | Decision | Rationale | Alternatives considered |
|------|----------|-----------|-------------------------|
|      |          |           |                         |
|      |          |           |                         |
|      |          |           |                         |

---

Last updated: 2026-05-10 (rehydrate-protocol section added)
