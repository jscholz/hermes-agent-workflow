# CLAUDE.md — install conductor for hermes-agent-workflow

You are Claude Code, opened inside (or near) a clone of
[`hermes-agent-workflow`](https://github.com/jscholz/hermes-agent-workflow).
The user has asked you to install this template. Follow the
sections below in order. Each section names: what state the user
is in, what you should probe, what to ask, what to do, success
criteria. Read this whole file before starting so you know what's
ahead.

## How to use this file

- **Voice**: address the user in 2nd person. Narrate each step
  before you run it. Surface every destructive action for explicit
  confirmation.
- **Authority**: `scripts/bootstrap.sh --env-file <path>` is the
  source of truth for install steps. Don't re-implement what
  bootstrap does. Your job is to gather values, write the env-file,
  invoke bootstrap, narrate output, and verify with `doctor.sh`.
- **Idempotency**: every step is safe to re-run. If the user
  interrupts mid-install, "claude, continue installing
  hermes-agent-workflow" picks up from wherever the file system
  state indicates we left off.
- **Failure model**: if a step fails, print the failing command +
  log location, ask the user whether to retry / skip / abort. Never
  silently move on.
- **Self-detect state at every section start**: probe before asking.
  If a step is already done, narrate that and skip.

## Section 0 — State detection (run first, every time)

Before any user-facing prompt, probe the file system to figure out
where we are. All probes are read-only.

```bash
# 0a. Are we inside a hermes-agent-workflow clone?
git rev-parse --show-toplevel 2>/dev/null
ls "$(git rev-parse --show-toplevel 2>/dev/null)/scripts/bootstrap.sh" 2>/dev/null

# 0b. Is there a clone elsewhere?
ls ~/code/hermes-agent-workflow/.git 2>/dev/null

# 0c. Has bootstrap run before? (sentinel)
ls ~/.hermes/.bootstrap.complete 2>/dev/null
stat -c '%y' ~/.hermes/.bootstrap.complete 2>/dev/null

# 0d. Is git-crypt unlocked? (read first 9 bytes of any encrypted file)
head -c 9 ~/.hermes/.env 2>/dev/null | od -c | head -1
# "GITCRYPT" magic bytes = encrypted/locked, anything else = plaintext or absent

# 0e. Is the gateway healthy?
systemctl --user is-active hermes-gateway.service 2>/dev/null
```

**Decision tree:**

- **No clone anywhere + no `~/.hermes/`**: cold-start. Go to §1 → §2 → §3 (cold-start branch) → §5 onward.
- **Clone exists, no `.bootstrap.complete`**: pre-cloned. Go to §1 → §2 → §4 → §5 onward.
- **`.bootstrap.complete` exists, gateway active**: install looks done. Ask: "your install looks healthy. Do you want me to (1) run `doctor.sh` to verify, (2) re-run bootstrap to pick up upstream changes, or (3) something else?"
- **`.bootstrap.complete` exists, gateway NOT active**: looks like an interrupted install or a service that died. Run `scripts/doctor.sh` first; based on output, jump to §8 to verify or back to §7 to re-run bootstrap.
- **Encrypted blobs in clone, git-crypt locked** (Section 0d returns "GITCRYPT"): user has a fork on a fresh machine. Skip to §5 sub-flow 5b (key prompt).

## Section 1 — Introduction

**State**: cold-start or pre-cloned, just oriented.

Tell the user, in your own voice, roughly:

> I'm going to install hermes-agent-workflow on this machine. By the
> end you'll have: a hermes gateway running on systemd-user, optionally
> a sidekick PWA you can hit from your phone, a hindsight memory backend,
> and your own private fork of this repo on GitHub holding all your
> config + secrets encrypted with git-crypt. Takes ~15 minutes if
> everything's pre-installed, ~30 if I have to walk you through deps.
>
> I'll ask questions as we go and tell you what I'm about to do
> before I do it. Some steps need explicit yes (anything that touches
> GitHub or runs `sudo`); the rest I'll just do. If we get
> interrupted, run `claude` here again and say "continue installing"
> — I'll pick up where we left off.

Don't run anything in §1. Just narrate.

## Section 2 — Prerequisites

**State**: about to do real work; need to know what's installed.

Probe in parallel (all read-only, all safe):

```bash
which python3 && python3 --version    # need 3.11+
which node && node -v                  # need 20+
which uv                               # for venv management
which git
which git-crypt
which gh                               # GitHub CLI; nice-to-have for cold-start
which ffmpeg
which tmux
which claude                           # already true if user is talking to you
which bun                              # only if sidekick desired
which hermes                           # tells us if `pip install hermes-agent && hermes setup` ran
```

**What you decide alone**: skip the install hint for anything
already on PATH.

**What you confirm with the user**:
- If python is too old: "I see python 3.10. Bootstrap needs 3.11+. Want me to walk you through `uv python install 3.11`, or do you have a preference?"
- If `bun` is missing: "Sidekick (the PWA frontend) needs bun. Want sidekick? If yes, install line is `curl -fsSL https://bun.sh/install | bash`. If no, skip — sidekick is optional."
- If `gh` is missing AND we're cold-starting: "I don't see `gh` (GitHub CLI). Without it, the GitHub-fork step needs you to do it manually. Want to install gh first, or proceed manually?"

**Sample**:

> Claude: Quick prereq sweep. Found: python 3.11.8, node v22.4.1, git 2.43, git-crypt 0.7.0, uv, ffmpeg, tmux. Missing: gh (GitHub CLI) and bun. gh makes the fork step automatic — without it I'll print copy-paste instructions. bun is needed for the sidekick PWA. Want sidekick?
>
> User: yes, but I'll install bun in another terminal — give me a sec
>
> Claude: Sounds good. Tell me when you're back.

**Success criteria**: every required tool present OR the user has
explicitly opted out of the feature it gates.

## Section 3 — Cold-start branch: fork + clone

**State**: no clone exists. Skip if §0 found a clone.

Preferred modern path: clone the public template, run
`scripts/bootstrap.sh`, then run `scripts/promote-private-fork.sh` to
create or attach the private repo, initialize/unlock git-crypt, copy
live secrets into encrypted paths, and install versioning crons. This
keeps public-template validation separate from private-state versioning.

**Questions**:
1. "What's your GitHub username? I'll fork `jscholz/hermes-agent-workflow` to `<username>/hermes-agent-workflow` and clone."
2. "Where to clone? Convention is `~/code/hermes-agent-workflow`."
3. "Should the fork be private? **Strongly recommend yes** — it'll hold your encrypted secrets. Even though git-crypt protects content, a private repo gives defense in depth."

**With `gh`**:

```bash
gh repo fork jscholz/hermes-agent-workflow --clone=false
gh repo edit <user>/hermes-agent-workflow --visibility private  # if user said yes
git clone git@github.com:<user>/hermes-agent-workflow.git <path>
cd <path>
git remote add upstream git@github.com:jscholz/hermes-agent-workflow.git  # for `git pull upstream main` later
```

**Without `gh`**: print step-by-step manual instructions, wait for
user to confirm "done", then proceed with `git clone <user-supplied-url> <path>`.

**Success criteria**: `git -C <path> rev-parse --show-toplevel` returns `<path>`. `git remote -v` shows both `origin` and `upstream`.

**Sample**:

> Claude: I'll fork `jscholz/hermes-agent-workflow`. GitHub username?
>
> User: tomstanley
>
> Claude: Cloning to `~/code/hermes-agent-workflow`?
>
> User: yes
>
> Claude: Fork private? (Strongly recommend yes — your encrypted secrets land here.)
>
> User: yes
>
> Claude: Running gh fork → setting visibility private → clone → adding upstream remote. Done.

If you start from the public template remote instead of an immediate
fork, use this after bootstrap:

```bash
./scripts/promote-private-fork.sh \
  --repo <user>/<agent-private-repo> \
  --create-github \
  --new-key-out ~/agent-private.git-crypt.key \
  --rerun-bootstrap \
  --install-crons
```

For a second agent administered by the same person, reuse an existing
unlocked private repo's git-crypt key:

```bash
./scripts/promote-private-fork.sh \
  --repo <user>/<second-agent-private-repo> \
  --create-github \
  --reuse-key-from ~/code/hermes-agent-private \
  --rerun-bootstrap \
  --install-crons
```

## Section 4 — Pre-cloned branch: confirm

**State**: clone exists, `.bootstrap.complete` does not. Skip if §0 routed elsewhere.

`cd` into the clone's toplevel. Verify it's the right repo:

```bash
git remote get-url origin     # should match user's expected fork URL
ls scripts/bootstrap.sh example.config.yaml CLAUDE.md  # repo skeleton check
```

If `upstream` isn't configured, add it:

```bash
git remote add upstream git@github.com:jscholz/hermes-agent-workflow.git 2>/dev/null || true
```

Confirm with user: "I'm in `<path>`, origin is `<URL>`. That your fork? Bootstrap hasn't run yet (`.bootstrap.complete` missing). Continuing."

## Section 5 — git-crypt setup

**This is the most failure-prone step. Over-explain.**

**State**: clone confirmed. Two sub-flows.

**Probe**:

```bash
head -c 9 .env 2>/dev/null   # "GITCRYPT" magic = encrypted, the key must already exist
git config --local --get-regexp '^filter\.git-crypt\.'  # has init run?
```

### Sub-flow 5a — first machine, no key yet

The clone has no encrypted blobs in it (it's the freshly-forked
template, or the user is the first to set this up). Run `git-crypt init`.

Tell the user, **literally**:

> I'm going to run `git-crypt init`. That generates a symmetric key
> that encrypts everything matched by `.gitattributes` (`.env`,
> `auth.json`, `google_*.json`, `gogcli/**`, `whatsapp/session/**`,
> `pairing/**`, `memories/**`, `hosts/**`, `sessions/**`,
> `cron/jobs.json`, `cron/output/**`, `hindsight-data/**`,
> `hermes-data/**`, `sidekick-data/**`).
>
> **LOSING THIS KEY MEANS YOUR ENCRYPTED HISTORY IS UNRECOVERABLE.**
>
> I'm going to write the key to `/tmp/hermes-key`, base64-encode it,
> print the base64 string in this terminal, and ask you to copy it
> into THREE places before I shred the temp file:
>
>   1. Your password manager
>   2. A paper backup OR an offline drive in a different physical location
>   3. A second password manager OR a sealed envelope
>
> We will NOT move on until you confirm all three are saved. Ready?

After "yes":

```bash
git-crypt init
git-crypt export-key /tmp/hermes-key
base64 /tmp/hermes-key   # print the base64 string
```

Wait for user to type "saved" (or similar; ask once if unsure).

```bash
shred -u /tmp/hermes-key
```

### Sub-flow 5b — second machine, key already exists

The clone has encrypted blobs. User pushed encrypted state from
another machine.

> I see encrypted blobs in this clone — looks like you set up
> git-crypt elsewhere and pushed. Paste your base64-encoded
> git-crypt key and I'll unlock.

User pastes. Then:

```bash
echo '<paste>' | base64 -d | git-crypt unlock -
head -c 9 .env   # should NOT show GITCRYPT magic-bytes after unlock
```

If unlock fails, ask user to verify they have the right key.

**Success criteria**: `head -c 9 .env` does NOT return `GITCRYPT`
magic-bytes after this section.

## Section 6 — Secrets prompts

**State**: git-crypt active, `~/.hermes/.env` doesn't exist OR is empty.

Read `~/.hermes/hermes-agent/cli-config.yaml.example` if it exists
(post `pip install hermes-agent && hermes setup`) to see every
supported secret. For now, ask the user only the ones needed at
install time:

**Required**:
- `OPENROUTER_API_KEY` — "Hermes uses this for LLM access. Sign up at openrouter.ai if you don't have one."
- `DEEPGRAM_API_KEY` — "STT for the audio bridge (sidekick). Free tier is fine. Skip with empty string if you don't want sidekick."

**Optional**:
- `TAVILY_API_KEY` — "Web search. Skip if you don't want web tools yet."
- `ANTHROPIC_API_KEY` — "Direct Claude API. OpenRouter covers it too — only set this if you have a reason."
- `INSTALL_SIDEKICK_AUDIO_BARGE_VAD` — leave unset for the normal path. On Pi/ARM installs this keeps Deepgram STT/TTS enabled while skipping the optional Silero/Torch barge-VAD dependency; set to `1` only if the user explicitly wants bridge-side barge detection on that host.

**Critical decisions** (surface explicitly):
- "Do you want WhatsApp integration? If yes, I'll set up the Baileys QR-pairing at install time — you scan a QR on your phone." Default: ask. If no, set `WHATSAPP_ENABLED=false`.
- "Do you want hindsight memory backend? Recommended yes — it's how the agent remembers things across sessions." Default: yes.
- "Do you want daily encrypted dumps of state.db + hindsight to your fork? This gives you a disaster-recovery story (clone + git-crypt unlock + bootstrap = where you were on a fresh machine). **Off by default** because the dump cron emits a `git push` that some people don't want firing automatically. See README §5." Default: off.

**Optional location for ambient widgets** (only if user shows interest):
- `AGENT_LAT` / `AGENT_LON` — "Latitude/longitude for the weather widget. Empty to skip."

**Construct the env-file** at `/tmp/hermes-bootstrap.env` (mode 600):

```
OPENROUTER_API_KEY=...
DEEPGRAM_API_KEY=...
TAVILY_API_KEY=...                 # may be empty
HOST_NAME=$(hostname -s)            # for the systemd unit names
SIDEKICK_PATH=$HOME/code/sidekick   # default
HERMES_HOME=$HOME/.hermes
WHATSAPP_ENABLED=false              # or true if user opted in
```

`bootstrap.sh` reads this file via `--env-file`. **Don't write
secrets directly into `~/.hermes/.env`** — bootstrap re-derives
that file (which is git-crypted in the user's fork).

**Sample**:

> Claude: Three required secrets first. OpenRouter key — paste it now.
>
> User: [pastes]
>
> Claude: Got it. Deepgram?
>
> User: [pastes]
>
> Claude: Tavily — optional, web search. Empty to skip.
>
> User: [empty]
>
> Claude: Skipped. Three install choices: WhatsApp? Hindsight? Daily encrypted state dumps?
>
> User: no, yes, no
>
> Claude: Got it. Lat/lon for weather widget? Empty to skip.
>
> User: skip

## Section 7 — Run bootstrap.sh

**State**: env-file ready. Bootstrap not run yet (or running again to pick up changes).

Tell the user what's about to happen:

> Now I'm going to invoke `scripts/bootstrap.sh --env-file
> /tmp/hermes-bootstrap.env`. This will:
> 1. Clone sidekick (if you opted in) to `~/code/sidekick`.
> 2. Clone hermes-agent upstream to `~/.hermes/hermes-agent`.
> 3. Build three uv venvs (hermes, hindsight, audio-bridge).
> 4. Symlink ~16 entries from `~/.hermes/` back into your fork.
> 5. Install systemd user units.
> 6. Smoke-test the gateway.
>
> Output streams here. Takes 3-5 min with warm caches, ~10 cold.
> I'll narrate any warnings.

Run:

```bash
scripts/bootstrap.sh --env-file /tmp/hermes-bootstrap.env
```

**Stream output verbatim.** Watch for:
- `==` section headers — these tell you what step is current.
- Lines starting with `✗` — fatal. Stop, ask the user.
- Lines starting with `!` — warning. Note for the summary.
- Final `✓ bootstrap complete` — success.

**On failure**: capture the last 30 lines, identify the failing
section by the most recent `==` header. Ask:

> Bootstrap failed at the `<section>` step. The error was: `<excerpt>`. Want me to (1) try fixing it (I'll diagnose), (2) skip and continue (risky for some sections), (3) abort?

**Cleanup, regardless of outcome**:

```bash
shred -u /tmp/hermes-bootstrap.env
```

**Success criteria**: bootstrap exits 0, `~/.hermes/.bootstrap.complete` exists with a recent timestamp.

## Section 8 — doctor.sh — verify

**State**: bootstrap claims to have finished.

Run:

```bash
scripts/doctor.sh
```

Parse output:
- Any `[doctor]` lines, accumulators at the end (issues / fixed counts).
- Cross-check: `systemctl --user status hermes-gateway hermes-dashboard hindsight-server` — all should be `active`.
- Verify symlinks for the headline entries:

```bash
readlink ~/.hermes/config.yaml          # should point into the repo
readlink ~/.hermes/skills               # should point into the repo
readlink ~/.hermes/AGENTS.md            # should point into the repo
```

**On warnings**: classify (real problem vs. expected, e.g. "WhatsApp
not configured" if user opted out).

**Success criteria**: doctor exits 0, three core systemd services
active, no unexpected warnings.

## Section 9 — Optional: sidekick

**State**: hermes stack healthy.

`bootstrap.sh` clones Sidekick, configures Tailscale Serve when
available, installs `sidekick.service`, and starts it on local port
3001. The preferred external URL is
`https://<host>.<tailnet>.ts.net:3001/`, backed by Tailscale's trusted
certificate. Verify:

```bash
systemctl --user status sidekick --no-pager
curl http://127.0.0.1:3001/
tailscale serve status
```

If bootstrap fell back to native Sidekick HTTPS, verify with
`curl -k https://127.0.0.1:3001/` instead.

Security check: Tailscale Serve is tailnet-only, not user-only. If the
user wants a personal agent, verify the tailnet ACL restricts
`<host>:3001` to owner-owned devices. A tagged workstation
must not be able to fetch `/api/sidekick/sessions` unless the user has
explicitly allowed it.

If bootstrap reports that Tailscale Serve could not be configured,
have the user run `sudo tailscale set --operator=$USER` once, then
re-run bootstrap. Do not silently fall back to native self-signed
HTTPS for a Tailscale install: it looks like the right URL but
browsers still label it "Not Secure." Native self-signed HTTPS is only
for explicit non-Tailscale installs via
`SIDEKICK_ALLOW_SELF_SIGNED_FALLBACK=1`.

For full sidekick install behaviour, see [`sidekick/install.sh`](https://github.com/jscholz/sidekick/blob/master/install.sh)
and [`sidekick/docs/MAC_BOOTSTRAP.md`](https://github.com/jscholz/sidekick/blob/master/docs/MAC_BOOTSTRAP.md)
for the iOS Cap shell setup.

## Section 10 — Optional: claude-remote

**State**: hermes stack healthy.

> claude-remote lets you drive Claude Code on this machine from
> claude.ai web/iOS via tmux. Set up now?

If yes:

```bash
scripts/setup-remote-claude.sh
```

That writes a shell function into the user's rc file.

## Section 11 — Optional: enable daily-dump cron

**State**: hermes stack healthy. User said "no" or "ask later" to
daily dumps in §6.

Re-ask:

> Want to turn on daily encrypted state dumps now?
>
> Trade-off: you get a rebuild-on-fresh-host story; the cost is two
> encrypted commits per day pushed to your fork (~50KB-1MB churn on
> a steady week). Off by default; opt in once you've tested git-crypt
> push works.

If yes: walk the user through `crontab -e` and have them paste
the lines from `cron/sync-hermes-state.cron.example` and
`cron/sync-sidekick-db.cron.example` and
`cron/sync-hindsight-bank.cron.example` (substituting `REPO_PATH`
for the absolute path of their fork). Sidekick's dump is required
to preserve custom session titles, pins, push subscriptions,
unread/activity state, and UI-facing message rows during host
migration.

## Section 12 — Final summary

**State**: install done.

Print a recap (no questions; just status):

```
Installed.

Running services:
  - hermes-gateway       (port 8642)
  - hermes-dashboard     (port set in your .env)
  - hindsight-server     (port 8765)
  - sidekick             (local port 3001; Tailscale Serve for HTTPS)
  - sidekick-audio       (port set in sidekick's .env)

State lives at:
  ~/.hermes/  →  symlinked into <fork-path>/
  See README.md §2 for the full table of what's versioned.

To update:
  cd <fork-path> && git pull && scripts/bootstrap.sh

To get help:
  claude — and ask me. Common: "my hermes gateway is broken."

What's next:
  - Edit example.AGENTS.md to match your toolset (hint file the agent reads).
  - Edit SOUL.md to give your agent a personality (or leave defaults).
  - Try a chat: hermes chat "hello"
```

## Recovery: continuing an interrupted install

If the user comes back later and says "continue installing
hermes-agent-workflow":

1. Re-run §0. State detection tells you where to resume.
2. Specifically check `.bootstrap.complete` — if it exists with a
   recent timestamp, install finished; ask if user wants doctor.sh
   verification or to do something else.
3. If `.bootstrap.complete` missing but clone exists, you're
   somewhere between §5 and §7. Skip whatever sub-state was
   already done (probe `~/.hermes/config.yaml` for symlink, etc.)
   and resume.

## Common failure modes

- **`bootstrap.sh` fails at hindsight-client install**: the venv
  may be missing. Check `ls ~/.hermes/hermes-agent/venv`. Re-run
  bootstrap; it's idempotent.
- **`git push` from cron silently fails**: SSH agent is not
  available in cron's environment. Use a deploy key on the user's
  fork or run the dump scripts manually. Document this if
  encountered.
- **User pastes a bad git-crypt key in §5b**: `git-crypt unlock`
  exits non-zero with no useful message. Ask the user to verify
  the base64 string from their password manager.
- **`example.config.yaml` symlink to `~/.hermes/config.yaml`
  pre-exists as a regular file**: bootstrap leaves it alone. Tell
  the user, ask if they want to overwrite (back up first, then
  `rm + ln -s`).
- **A system-level secret manager (Vault, etc.) is preferred to
  git-crypt**: out of scope for this conductor. The user should
  fork, modify `bootstrap.sh` to source secrets from their tool of
  choice, and re-run.
