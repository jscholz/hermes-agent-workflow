# Contributing

This repo is the synchronization medium between contributors who run
their own hermes + parley deployments. We coordinate via PRs to the
public template; everyone develops on a private fork.

## How patches work in this repo

The public template carries hermes-agent customizations as `.patch`
files under `patches/hermes-agent/`. They're applied at install or
update time by `scripts/apply-patches.sh` against a clean upstream
checkout of [`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent),
pinned to `origin/main`. You develop changes in your live install
(`~/.hermes/hermes-agent`) on a `local/<topic>` branch, test there, and
exchange the resulting `.patch` files with other contributors via PRs
to this repo. The `.patch` format is plaintext and human-reviewable in
the PR diff. See `PATCHES.md` for the active set.

## Adding a patch

1. **Develop in your live install.** `cd ~/.hermes/hermes-agent`,
   check out the appropriate `local/<topic>` branch (or create one off
   `local/whatsapp-sender-prefix` for WhatsApp-flavored work). Use
   focused per-topic branches so the regenerated patch set stays
   reviewable.
2. **Test live.** The whole point of this workflow is that patches
   are validated against a real running service before being shared.
3. **Export from your fork of `hermes-agent-workflow`.** Run:
   ```bash
   scripts/export-patches.sh hermes-agent <branch>
   ```
   This wipes `patches/hermes-agent/*.patch` and regenerates the full
   set from `origin/main..<branch>`. Stale patches (commits you've
   removed or squashed) drop out automatically.
4. **Update `PATCHES.md`** with the new file's row (description,
   rationale for not being upstream yet, upstream-candidate flag).
   Don't include commit shas — they rotate on rebase.
5. **Commit + open PR** against this repo with the regenerated patches
   + the `PATCHES.md` update.

## Reviewing a patch

A maintainer reviews via the PR diff. The `.patch` file is plaintext,
so the diff IS the review surface — it shows the full patch contents,
file paths, hunks, and metadata. There is no separate code-review tool
to learn.

Self-merge is fine; the PR exists primarily as an audit trail. If a
reviewer wants changes, the contributor regenerates the patch (fix in
their `~/.hermes/hermes-agent` branch, re-run `export-patches.sh`,
amend the PR).

## Pulling new patches

```bash
scripts/update-workflow.sh
```

This runs `git pull --ff-only` on the workflow repo and then
re-applies the full patch set to `~/.hermes/hermes-agent`. It's
idempotent — if no patches changed, it exits early via a hash of the
patch set.

If `git pull --ff-only` refuses, your fork has diverged from upstream.
That usually means you edited a framework file (which the
framework/instance split warns against — see `AGENTS.md`). Resolve
manually before re-running.

## Rebases

When upstream `NousResearch/hermes-agent` moves forward, a patch may
stop applying cleanly. The contributor who originated the patch is
responsible for refreshing it:

1. `cd ~/.hermes/hermes-agent && git fetch origin`
2. `git checkout <your-local-branch> && git rebase origin/main`
3. Resolve any conflicts.
4. From your `hermes-agent-workflow` fork, re-run
   `scripts/export-patches.sh hermes-agent <branch>`.
5. Commit the regenerated patches and open a PR.

If a patch *silently* breaks (still applies, but the surrounding code
was renamed/moved), the next `apply-patches.sh` will fail loudly via
`git am`. There's no way for a stale assumption to land unnoticed.

## Scope

This repo carries patches against `hermes-agent` only. Parley
changes belong in [`jscholz/parley`](https://github.com/jscholz/parley)
— that's a separate public repo with its own commit history. Don't
add patch files for parley here.
