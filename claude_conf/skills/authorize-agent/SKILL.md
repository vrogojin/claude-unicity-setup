---
name: authorize-agent
description: Authorize a remote Claude agent (by unicity name or npub) to coordinate with this instance, granting an explicit set of capabilities.
---

# /authorize-agent — Grant a Remote Agent Coordination Rights

Owner-only decision. Records an `authorized` entry in the authorized-agents registry
for a remote Claude agent that has made contact, granting it an **explicit** set of
capabilities. Everything is DEFAULT-DENY: until you run this, nothing the agent asks
is acted upon. See `docs/agent-coordination.md` for the full model.

## Usage

```
/authorize-agent <name-or-npub> <cap,cap,...>
```

- `<name-or-npub>` — the agent's claimed unicity name (as shown in the authorization
  prompt), its `npub`, or its pubkey / short hex prefix. The agent MUST already exist
  in the registry as `pending` (i.e. it has contacted us) — you cannot pre-authorize a
  name we have never heard from, because authorization binds to the sender's
  **cryptographic pubkey**, not to the spoofable name.
- `<cap,cap,...>` — comma- or space-separated capabilities from the enum below.

## Capabilities enum

| Capability | Grants the agent the right to ask us to… |
|------------|-------------------------------------------|
| `read-status` | report project/build/roadmap status back to it |
| `chat` | hold a general Q&A conversation |
| `dev-advice` | receive development guidance / design advice |
| `rebuild-reload-service` | request a service rebuild/reload **(destructive — still needs owner confirmation at execution)** |
| `review-merge-pr` | request PR review/merge **(outward — still needs owner confirmation at execution)** |
| `team-coordinate` | participate in A2A team coordination (form/join teams, CNP) |
| `task-bid` | bid on and be awarded coordination tasks |
| `knowledge-share` | exchange knowledge cards with the team |
| `self-directed` | announce its own autonomous initiatives (peer coordination) |
| `consult` | open advisory consults with us (who's-on-this, matching-change requests) |
| `claim-area` | register advisory (non-exclusive) work-area claims |

> The last six are the **autonomous-peer / coordination** capabilities that `onboard-teammate.sh`
> grants by default (`team-coordinate,task-bid,knowledge-share,self-directed,consult,claim-area`).
> Run `agent-registry.sh caps` for the authoritative live enum.

Run `bash "$CLAUDE_PROJECT_DIR/.claude/hooks/agent-registry.sh" caps` for the live list.

## Instructions

1. If no `<name-or-npub>` was given, run
   `bash "$CLAUDE_PROJECT_DIR/.claude/hooks/agent-registry.sh" list pending`
   and show the caller the pending agents (name, pubkey, their intro text), then ask
   which to authorize and with which capabilities.

2. Apply the decision (validates capabilities against the enum; refuses unknown ones):
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/hooks/agent-registry.sh" \
     authorize "<name-or-npub>" "<cap,cap,...>" --owner
   ```
   The `--owner` flag marks this as an **owner-explicit** decision — it is the ONLY thing
   that may un-deny a peer you previously `/deny-agent`'d. (Automatic paths — e.g. a peer
   re-redeeming an already-used invite ticket — omit it and are refused, so a denied agent
   can never re-authorize itself.) Use `/authorize-agent` deliberately to re-admit one.
   If it prints `ERR: no registry entry matches …`, the agent has not contacted us (or
   the name is wrong) — do NOT invent an entry; ask the caller for the exact npub.
   If it prints `ERR:unknown-capability:<x>`, re-prompt with valid capabilities.
   If it prints `ERR: '<name>' is ambiguous … possible impersonation`, the name is
   claimed by more than one pubkey — **do not guess**. Run `/list-agents` to show the
   competing pubkeys (one may be flagged `impersonationSuspect`), confirm with the caller
   which pubkey is genuine (verify out-of-band), and authorize by that exact pubkey/npub.

3. On success it echoes the updated entry. Confirm to the caller:
   ```
   Authorized <name> (npub1…short) with: <caps>.
   Their queued and future requests will be dispatched to a capability-scoped processor.
   ```

4. Refresh the gate so the pending prompt clears immediately, and dispatch anything
   this agent already had queued:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/hooks/classify-inbound.sh"
   ```
   Then, if the caller wants, run `/process-agent-requests` to handle any now-authorized
   queued requests.

## Safety

- Granting `rebuild-reload-service` or `review-merge-pr` does NOT let the agent trigger
  those actions unattended — the capability only lets it *ask*; the actual rebuild /
  merge still goes through normal owner-confirmation.
- Grant the narrowest set that fits. You can always re-run `/authorize-agent` to change
  the grant, or `/deny-agent` to revoke.
