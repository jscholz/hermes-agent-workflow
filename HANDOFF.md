# Host Handoff

This workflow assumes one active writer at a time. The active host runs
Hermes services, Parley, and sync crons; standby hosts can be installed
but should not mutate encrypted state dumps.

`ACTIVE_HOST` is the coordination sentinel. The sync scripts check it and
exit quietly on standby hosts.

## Normal Switch

On the current active host:

```bash
cd ~/code/hermes-agent-workflow
scripts/handoff-out.sh
```

That stops user-facing services, captures final dumps for:

- `~/.hermes/state.db` to `hermes-data/state.sql`
- `~/.hermes/parley.db` to `parley-data/parley.sql`
- Hindsight Postgres to `hindsight-data/**`

It then clears `ACTIVE_HOST`, commits, and pushes.

On the new host:

```bash
cd ~/code/hermes-agent-workflow
git pull --ff-only
scripts/handoff-in.sh
```

That restores Hermes state, Parley UI state, and Hindsight memory;
relinks runtime directories; installs expected crons; starts services; and
runs `scripts/handoff-smoke-test.sh`.

## Forced Takeover

If the old active host is dead or unreachable:

```bash
scripts/handoff-in.sh --force
```

This restores the latest committed dumps. Any writes made on the dead host
after its last successful sync are lost.

## HTTPS

Parley should be served over HTTPS for any browser that is not on
`localhost`; microphone, PWA, push, and WebRTC features require a browser
secure context. `scripts/bootstrap.sh` prefers Tailscale Serve and maps:

```text
https://<host>.<tailnet>.ts.net:3001/ -> http://127.0.0.1:3001
```

That gives a trusted certificate with no browser warning. If Tailscale
Serve cannot be configured, run this once and re-run bootstrap:

```bash
sudo tailscale set --operator=$USER
```

Do not treat native self-signed HTTPS as equivalent to the Tailscale
setup: it encrypts traffic but browsers will label it "Not Secure."
Self-signed fallback is only for explicit non-Tailscale installs via
`PARLEY_ALLOW_SELF_SIGNED_FALLBACK=1`.

## Access Control

Tailscale Serve is **tailnet-only**, not **user-only**. If your tailnet
policy lets a machine reach `<agent-host>:3001`, that machine can load the
Parley app and call its API. Do not assume that a user-owned node is
private merely because it is not tagged as a robot or workstation.

For a personal-only agent, add a tailnet ACL/grant that allows only owner-owned
devices to reach the active host's Parley port and removes broader
`*:*` / tag-wide access for that destination. Example shape:

```json
{
  "hosts": {
    "agent-host": "100.64.0.10"
  },
  "acls": [
    {
      "action": "accept",
      "src": ["owner@example.com"],
      "dst": ["agent-host:3001"]
    }
  ]
}
```

Validate from a machine that should not have access after changing policy:

```bash
curl -I https://agent-host.<tailnet>.ts.net:3001/
```

It should fail from machines that are not meant to use the agent.
