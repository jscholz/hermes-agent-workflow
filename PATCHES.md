# Patches

This template ships **virgin hermes-agent** — no patches applied to
the upstream package by default. The agent you get after running
`scripts/bootstrap.sh` is whatever
[`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent)
publishes at the time of install (pinned to a recent tag in the
bootstrap script for stability).

The patch *infrastructure* is still in place — empty
`patches/hermes-agent/` directory, `scripts/apply-patches.sh` and
`scripts/export-patches.sh` ready to use — so you can layer your own
local changes on top without setting anything up.

## Why no patches?

This template's job is to give a new user a working hermes-agent +
sidekick install with the resume protocol, prune cron, and other
workflow conveniences. The personal customizations the original
author iterates on (group-mute toggles, react tools, identity prefix
for shared groups) are deliberately kept out: they're personal
opinions, they drift against upstream, and they shouldn't be
inherited by every new user.

If you eventually need a patch, add it the same way you would in any
git project — see the workflow below.

## Adding your own patches

1. Make changes in your `~/.hermes/hermes-agent/` checkout on a
   feature branch. Commit cleanly (one logical change per commit;
   easier to upstream later).

2. Export to this repo:

   ```bash
   ./scripts/export-patches.sh hermes-agent <your-feature-branch>
   ```

   This writes one `.patch` file per commit into
   `patches/hermes-agent/`, named by `git format-patch` convention
   (`0001-<subject>.patch`, etc.).

3. Commit the `.patch` files to this repo and push. Document each
   patch in the table below.

4. On the next `bootstrap.sh` run (or directly via
   `scripts/apply-patches.sh`), the patches will be replayed onto
   a clean upstream checkout in dependency order.

## How patches stay current

When upstream `hermes-agent` moves, a patch may stop applying cleanly.
Refresh by:

```bash
cd ~/.hermes/hermes-agent
git fetch origin
git rebase origin/main local/<your-feature-branch>
# resolve any conflicts
~/<this-repo>/scripts/export-patches.sh hermes-agent local/<your-feature-branch>
# commit the regenerated .patch files
```

`apply-patches.sh` fails loudly via `git am` if a patch can't apply,
so stale assumptions never silently land.

## Active patches

| File | What it does | Why not yet upstream | Upstream candidate? |
|------|--------------|----------------------|---------------------|
| `0001-fix-state-FTS-self-heal-verifies-sync-triggers-not-j.patch` | Startup FTS self-heal verifies the sync *triggers*, not just the table. A restored `state.db` can carry FTS tables without their insert/delete/update triggers (older restore tooling rebuilt tables only), silently freezing the search index. If any piece is missing, the table is rebuilt and backfilled from `messages`. | PR to NousResearch/hermes-agent not yet opened. | Yes — data-integrity fix, no deployment-specific behavior. |

## Notes

- Patches that touched the WebRTC subsystem are intentionally NOT
  included anywhere in this template — the WebRTC stack moved out of
  hermes-agent into the sidekick repo (`audio-bridge/`).
- Sidekick ↔ Hermes integration is through the first-class Sidekick
  Hermes plugin at `sidekick/backends/hermes/plugin`. `bootstrap.sh`
  symlinks that plugin into `~/.hermes/plugins/sidekick` and enables it
  in config. No core hermes patch is expected for a fresh install.
