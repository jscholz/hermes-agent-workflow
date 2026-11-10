# Private Fork Finish-Line

The public template is safe to clone and validate, but it should not be
the long-term origin for a real agent. A real agent needs its own private
repo so runtime state, secrets, memories, session transcripts, and
database snapshots can be restored on a replacement host.

The intended flow is:

```bash
git clone https://github.com/jscholz/hermes-agent-workflow.git ~/code/my-agent-private
cd ~/code/my-agent-private
./scripts/bootstrap.sh
./scripts/promote-private-fork.sh \
  --repo YOUR_GITHUB_USER/my-agent-private \
  --create-github \
  --new-key-out ~/my-agent-private.git-crypt.key \
  --rerun-bootstrap \
  --install-crons
```

For an additional agent administered by the same person, you can reuse an
existing git-crypt key:

```bash
./scripts/promote-private-fork.sh \
  --repo YOUR_GITHUB_USER/second-agent-private \
  --create-github \
  --reuse-key-from ~/code/hermes-agent-private \
  --rerun-bootstrap \
  --install-crons
```

`--reuse-key-from` exports the key to a temporary file, unlocks the new
repo, then shreds the temporary copy. Do not leave exported git-crypt keys
on disk.

## What Promotion Does

`scripts/promote-private-fork.sh`:

- moves the public template remote to `upstream`
- sets `origin` to your private repo
- initializes/unlocks git-crypt
- copies live `~/.hermes/.env` and known OAuth/session files into
  encrypted repo paths, then relinks them back into `~/.hermes`
- copies live `~/.config/gogcli` into encrypted `gogcli/**`, then
  relinks it so Google/Drive/Gmail OAuth survives host replacement
- moves public-template local host memory into encrypted
  `hosts/<host>/claude-code-memory/`
- sets `ACTIVE_HOST`
- optionally re-runs bootstrap in versioned-host-state mode
- optionally installs the private versioning crons
- renormalizes git attributes before commit so newly private files are
  encrypted before the first push
- commits and pushes to `origin/main`

Use `--skip-google-oauth` for bots where the live host has personal
Google/gog state but the new agent should wait for a separate shared
Google account.

## Versioning Crons

`scripts/install-versioning-crons.sh` installs a managed crontab block:

- `doctor.sh` every 10 minutes
- `sync-hermes.sh` every 15 minutes for session exports and systemd unit snapshots
- `sync-cc-history.sh` every 15 minutes for Claude Code memory
- `sync-hermes-state.sh` daily for `~/.hermes/state.db`
- `sync-hindsight-bank.sh` daily for Hindsight Postgres
- `sync-parley-db.sh` daily for Parley UI state
- `prune-claude-cc-history.sh` daily

The script refuses to install these crons while `origin` is the public
template remote.

## Encryption Policy

The public template ships `.gitattributes` rules for private forks.
In a promoted repo, git-crypt encrypts:

- `.env`, `auth.json`, Google OAuth files, `gogcli/**`
- `whatsapp/session/**` and `pairing/**`
- `memories/**`
- `hosts/**` except the public example host
- `sessions/**`
- `cron/jobs.json` and `cron/output/**`
- `hermes-data/**`, `hindsight-data/**`, `parley-data/**`

The placeholder `.gitkeep` and README files that make the public template
legible remain plaintext.

## Restore On A New Host

```bash
git clone git@github.com:YOUR_GITHUB_USER/my-agent-private.git ~/code/my-agent-private
cd ~/code/my-agent-private
git-crypt unlock /path/to/git-crypt.key
./scripts/bootstrap.sh --unattended
systemctl --user stop hermes-gateway parley
./scripts/restore-hermes-state.sh --yes
./scripts/restore-parley-db.sh --yes
./scripts/restore-hindsight-bank.sh --yes
systemctl --user start hindsight-server hermes-gateway hermes-dashboard parley
./scripts/doctor.sh
```
