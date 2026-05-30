# AGENTS.md — hermes-agent-workflow (repo-root)

This is a thin pointer file. The substantive guidance lives elsewhere:

- **[`CLAUDE.md`](./CLAUDE.md)** — the install conductor. If a user
  opens Claude Code in this repo and says "install this for me,"
  CLAUDE.md is the script Claude follows. Read it first if you're
  doing install work.

- **[`example.AGENTS.md`](./example.AGENTS.md)** — the starter
  tool-hints file that becomes `~/.hermes/AGENTS.md` after install.
  This is what the *running hermes agent* reads on every session.
  Edit it after install to match your toolset.

- **[`README.md`](./README.md)** — design philosophy, the explicit
  state-enumeration table (what's versioned, what's encrypted, what's
  per-host), the skills_sync mechanism, encrypted-backup model.

- **[`CONTRIBUTING.md`](./CONTRIBUTING.md)** — framework vs. instance
  file ownership rules; useful when sending PRs back to upstream
  `jscholz/hermes-agent-workflow`.

If you're a contributor-Claude (not an installer-Claude), most
useful patterns: keep PRs scoped to single concerns, follow the PII
hygiene in your fork's own pii-scrub skill
(if you're pulling private→public), and don't push without explicit
user consent.
