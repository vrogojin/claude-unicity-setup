# Agent Coordination — Owner-in-the-Loop Master Manager

How this Claude instance coordinates with Claude agents running on **other hosts** that
are working on the concierge project, under an **owner-in-the-loop, default-deny**
authorization model.

Our instance — **cryptohog-concierge-dev** — is the designated **master manager** of the
concierge project. Other agents talk to it and get coordinated. Nothing a remote agent
asks is ever acted upon until (a) the admin has authorized that agent and (b) the
specific capability was granted — and destructive/outward actions additionally require
the admin's confirmation at execution time.

> **Who is the admin/authorizer?** There is **no remote "owner" to DM** — `owner_npub` is
> left empty. **The primary admin is THIS localhost Claude terminal session.** The
> Stop-gate surfaces a pending unknown-agent request to the localhost session, and the
> human at this terminal authorizes it in-session via `/authorize-agent` /`/deny-agent`
> (which write the registry). Throughout this doc, wherever the "owner" is mentioned as
> the decision-maker, read it as **"the localhost session / the admin at this terminal."**
> With `owner_npub` empty, the former "owner-priority DM path" simply doesn't fire, and
> every inbound agent message flows through the authorization pipeline the admin controls.

> TL;DR: an unknown agent that contacts us is **queued for owner authorization and
> nothing else happens**. An authorized agent's request is dispatched to a
> **capability-scoped processor** that can only act within the granted capabilities.
> With an empty registry the whole system is inert.

---

## 1. Identity

Every Claude instance has a **Unicity identity** — a secp256k1 keypair
(`.claude/agent/identity.json`, gitignored). Messages travel over Nostr (NIP-17
encrypted DMs; NIP-29 group chat in `UNICITY_DEV_AGENTS`) and arrive through the
sphere-sdk daemon (`on-dm.sh` / `on-group-message.sh`) or the poll fallback
(`agent-comms-check.sh`), which append them to the shared state file
`$STATE_DIR/agent-messages.json`.

**The registry is keyed by the sender's pubkey (hex).** The pubkey is the only thing a
remote cannot spoof — the encrypted DM is signed by it. A `unicityName` is a *claimed*
label (taken from the sender's own intro text, or assigned by the owner) and is **never**
the security boundary. A lookup may use a name, an npub, a pubkey, or a short hex prefix,
but authorization is always recorded against the pubkey. The canonical identifier maps
cleanly to a DID: **Unicity name → npub → `did:nostr:<pubkey>`** (and, later, a signed
Agent Card).

**Impersonation guard.** Because the claimed name is not identity, a message that claims
a name already tied to a **different** pubkey is treated as **unknown/pending** and the
discrepancy is surfaced to the owner (`impersonationSuspect` + `impersonationOf` in the
registry, and a prominent ⚠ warning in the Stop gate). The claimed name grants nothing;
only the signing pubkey does. Correspondingly, `/authorize-agent` and `/deny-agent`
**refuse an ambiguous name** (one that matches multiple pubkeys) and require the exact
pubkey/npub — so the owner can never accidentally authorize the impersonator.

> **Contract note.** The daemon delivers the sender's **pubkey**, not a resolved
> unicity name (`from_name` is only filled in for the owner), and `resolve-nametag` in
> `sphere-helper.mjs` is currently a stub (returns `npub: null`). So there is no reliable
> name→key directory yet. Consequences: (1) the registry keys on pubkey; (2) the owner
> authorizes an inbound agent **by the name/pubkey captured at first contact**, or by
> pasting an npub; (3) outbound first-contact (`/dm-agent`) needs the recipient's npub.
> If the daemon later populates a verified name and/or implements real nametag
> resolution, `unicityName` can be trusted for display but the pubkey stays the key.

---

## 2. Authorized-agents registry

Runtime JSON, self-initializing empty (default-deny), kept **out of git**. Default path
`.claude/agent/agent-registry.json` (override with `AGENT_REGISTRY_FILE`); the `.claude/`
tree is already gitignored in a deployed project. Template:
`.claude/agent/agent-registry.example.json`.

```json
{
  "version": 1,
  "updated_at": "<ISO>",
  "agents": {
    "<pubkey-hex>": {
      "pubkey": "<hex>",                     // the key; unspoofable identity
      "npub": "npub1…",                      // display / outbound addressing (may be "")
      "unicityName": "claude-otc-bot",       // CLAIMED label, not a security boundary
      "status": "pending|authorized|denied|peer",
      "capabilities": ["read-status", "..."],// only meaningful when authorized
      "firstSeen": "<ISO>",
      "lastSeen": "<ISO>",
      "decidedAt": "<ISO>",                  // when the owner authorized/denied
      "intro": "their first-contact self-description",
      "firstContact": "dm|group",
      "requestedSkill": "read-status",       // A2A skill they asked for (→ capability)
      "impersonationSuspect": false,         // true if the claimed name is tied to another pubkey
      "impersonationOf": "<pubkey-hex>",     // the pubkey that legitimately holds that name
      "note": "free text"
    }
  }
}
```

The derived DID for any entry is `did:nostr:<pubkey>` (surfaced in `list`/work items).

**Status semantics** (default-deny):

| status | meaning | effect |
|--------|---------|--------|
| *(absent)* | unknown | treated as `pending` on first sight |
| `pending` | contacted us, no decision yet | surfaced to owner; **never acted upon** |
| `authorized` | owner granted specific capabilities | requests dispatched to a capability-scoped processor |
| `denied` | owner refused | messages received but dropped; never surfaced again |
| `peer` | we initiated outbound, no decision yet | not authorized; treated like pending for inbound |

All registry reads/writes go through **`.claude/hooks/agent-registry.sh`** (sourceable
library + CLI). It validates capabilities, writes atomically under a lock, and never
downgrades an `authorized`/`denied` status on an idempotent `upsert-pending`.

---

## 3. Capabilities

An explicit, extensible enum (defined in `agent-registry.sh`, `caps` subcommand):

| Capability | The agent may ask us to… | Class |
|------------|--------------------------|-------|
| `read-status` | report project/build/roadmap status | read |
| `chat` | hold a general Q&A conversation | read |
| `dev-advice` | receive development/design guidance | read |
| `rebuild-reload-service` | request a service rebuild/reload | **destructive** |
| `review-merge-pr` | request a PR review/merge | **outward** |

Destructive/outward capabilities (`AGENT_CAPS_DESTRUCTIVE`) are **request-only**: holding
the capability lets an agent *ask*; the actual rebuild/merge still goes through normal
owner-confirmation. Extend the enum by editing `AGENT_CAPABILITIES` (and this table).

---

## 4. Inbound flow

```
 daemon/poll appends message ──▶ classify-inbound.sh ──▶ registry lookup by pubkey
                                                          │
   owner ───────────────────────────────────────────────┤ (priority path; not an agent)
                                                          │
   authorized ──▶ stamp caps on message ──▶ ENQUEUE work item ──▶ /process-agent-requests
                                                          │              └─▶ capability-scoped subagent
   pending/unknown ──▶ upsert pending (capture intro) ──▶ SURFACE to owner (Stop gate)
                                                          │
   denied ──▶ mark & DROP (no surface, no work item, no action)
```

1. **`classify-inbound.sh`** runs after every delivery (invoked from `on-dm.sh`,
   `on-group-message.sh`, `agent-comms-check.sh`, and defensively at the Stop gate). It
   scans for messages with no `.authz` and classifies each idempotently, stamping
   `.authz = { role, status, unicityName?, capabilities?, classified:true }` back onto
   the message (matched by content, so a concurrent append is never clobbered).
2. **Owner** messages (trusted `.priority`, or owner npub/nametag match) are left to the
   existing priority path — they never enter the agent-authorization pipeline.
3. **Authorized** senders: the message is stamped with the granted capabilities and a
   **work item** is written to `$STATE_DIR/agent-workitems/<id>.json` (id = content hash,
   so no duplicates). A hook cannot spawn a Claude team subagent, so it only *queues*.
4. **Pending/unknown** senders: a `pending` registry entry is created (capturing the
   sender's intro text) and the owner-facing surface `$STATE_DIR/agent-authz-pending.json`
   is rebuilt. Nothing is acted upon.
5. **Denied** senders: marked `denied` and dropped.

### Owner authorization UX (Stop gate)

`check-diagnostics.sh` (the Stop hook) blocks the session from finishing while there are
undecided requests, using the same notify + Stop-block mechanism as the other gates:

> **N unknown agent(s) are requesting to coordinate and need your authorization
> decision:**
> • claude-otc-bot (dm · pubkey aa11bb22cc33…)
>   says: "I am claude-otc-bot on host B; my owner asked me to coordinate…"
>
> Authorize: `/authorize-agent <name-or-npub> <cap,cap,...>`
> Deny: `/deny-agent <name-or-npub>`

The owner decides right from the Claude session:

- **`/authorize-agent <name-or-npub> <caps>`** → sets `authorized` + validated caps.
- **`/deny-agent <name-or-npub>`** → sets `denied`.
- **`/list-agents [status]`** → view the whole registry.

A second gate blocks while there are **authorized work items queued for dispatch**,
nudging the owner to run **`/process-agent-requests`**.

---

## 5. Authorized request processing (capability-scoped)

`/process-agent-requests` is the dispatch loop the master session runs. For each queued
work item it:

1. **Re-verifies** authorization + reads the **current** capabilities from the registry
   (never trusts the queued snapshot — the owner may have revoked).
2. Spawns a **capability-scoped processor** subagent (`Agent` tool, general-purpose)
   whose prompt states the requester, the request body, and the **exact** capabilities it
   holds — with the hard rule: *do only what falls within these capabilities; refuse
   anything else and say which capability is missing; never touch secrets/registry/.env;
   `rebuild-reload-service` and `review-merge-pr` are propose-only, the owner executes.*
3. Sends the processor's reply back with `/dm-agent`, and for destructive/outward requests
   surfaces the proposed action to the owner for confirmation before anything runs.
4. Marks the work item `done` (or `skipped` if authorization was revoked).

**Three enforcement layers** (defense in depth):

1. **Registry gate** at classification — only `authorized` + granted capability yields a
   work item.
2. **Scoped processor** — the subagent is constrained to the granted capabilities and
   must refuse out-of-scope asks; it cannot widen its own grant.
3. **Owner-confirmation** — destructive/outward actions still require the owner at
   execution time, regardless of capability.

---

## 6. Outbound flow

**`/dm-agent <name-or-npub> <message>`** sends a NIP-17 DM via the daemon's
`send-dm` helper.

- Resolves the recipient npub from the registry (by name) or takes a raw npub; records a
  `peer` entry via `agent-registry.sh upsert-peer`.
- On **first contact** it prefixes a self-describing intro so the remote knows who we are:
  `[cryptohog-concierge-dev · concierge master-manager] <message>`.
- **Handshake / challenge:** the remote's reply arrives as an inbound DM. If the remote
  does not yet know us, its reply comes from an unknown pubkey and is surfaced as a
  pending authorization (their reply becomes the intro) — that is the remote greeting or
  challenging us. If it explicitly challenges us for authorization, read it with
  `/check-messages` and reply via `/dm-agent`. Identity is proven cryptographically by the
  signed DM itself — **never** send secrets, key material, or credentials.

---

## 7. Interop: A2A-over-Nostr envelope

The chosen interop direction is the **A2A (Agent2Agent) schema carried over our Nostr
transport** ("A2A-over-Nostr"), keeping MCP for tool/context. The classifier is
envelope-aware **leniently and without a bespoke schema**: if an inbound body is a JSON
object it extracts, best-effort, a claimed agent name, a requested skill, and a
human-readable message; plain-text bodies just fall through as the intro. Mapping:

| A2A concept | Field(s) read | Used for |
|-------------|---------------|----------|
| agent identity | signing **pubkey** (never the payload) → `did:nostr:<pubkey>` | the registry key |
| agent card name | `from` / `agentCard.name` / `agent.name` / `name` | *claimed* `unicityName` (display only; impersonation-checked) |
| skill / capability | `skill` / `capability` / `skillId` / `method` | `requestedSkill` → mapped onto our capability enum at the gate |
| message / task | `message.text` / `message` / `task.text` / `task` / `text` | the human-readable intro / work-item body |

This keeps the envelope future-proof: when the full A2A binding + signed Agent Cards
land, the same fields carry more structure without reworking the authorization model.
The **skill→capability gate** is the join point — an authorized peer's requested skill is
matched against its granted capabilities by the capability-scoped processor.

---

## 8. Content-guard (SIF)

Agent-comms message bodies are run through the **SIF content-guard** (semantic firewall)
the same way the concierge backend guards its agent I/O — **fail-closed by design, at
ingestion and at egress**. It composes with the A2A direction: the guard runs on the A2A
message payload regardless of transport.

- **Inbound (ingestion):** after a message passes authz (authorized sender + granted
  capability) and **before** it is dispatched to the capability-scoped processor,
  `classify-inbound.sh` runs the body through `sif-guard.sh`. A **flag → quarantine**: the
  message is NOT dispatched, a record is written to `$STATE_DIR/agent-quarantine/<id>.json`,
  the message is stamped `sifQuarantined:true`, and the owner is surfaced the quarantine at
  the Stop gate. Clean → queued as normal.
- **Outbound (egress):** `/dm-agent` runs the final body through `sif-guard.sh --direction
  outbound` before sending; a flag refuses the send.

**`sif-guard.sh`** is a thin, isolated step so it is trivial to point at the real SIF once
the key lands. It POSTs `{content, source, direction, principal}` to the configured guard
(`POST /api/guard/check` on the concierge backend, or any SIF endpoint) and reads a flag
liberally (`flagged` / `blocked` / `allowed:false` / `action:block` / `decision|verdict`
matching block/deny/unsafe/malicious). Exit `0`=pass, `10`=quarantine.

**Config knobs** (ENV overrides > `.claude/agent/config.json` `.sif.*` > safe defaults):

| config `.sif.*` | ENV | default | meaning |
|-----------------|-----|---------|---------|
| `enabled` | `SIF_ENABLED` | `false` | master switch — **off = inert pass-through** (opt-in) |
| `url` | `SIF_GUARD_URL` | — | guard endpoint, e.g. `https://concierge-dev.dyndns.org/api/guard/check` |
| `token` | `SIF_GUARD_TOKEN` | — | Bearer token if required |
| `required` | `SIF_REQUIRED` | `false` | strictness on **guard error**: `false`=fail-**open** (dev), `true`=fail-**closed** (prod) |
| `host_header` | `SIF_GUARD_HOST` | — | optional `Host:` header for vhost routing |
| `timeout_ms` | `SIF_GUARD_TIMEOUT_MS` | `4000` | request timeout |

> **Fail-open vs fail-closed.** A genuine content **flag always quarantines**, regardless
> of strictness. `required` only governs what happens on a guard **error** (endpoint
> unreachable/keyless/misconfigured): dev defaults to fail-**open** (SIF is HELD/keyless),
> prod sets `required:true` (or `SIF_REQUIRED=1`) for fail-**closed**. With `enabled:false`
> (the default) the guard is a no-op, so the whole integration is inert-safe until wired.

Debug the effective config with `bash .claude/hooks/sif-guard.sh config`.

---

## 9. Security posture

- **Default-deny everywhere.** No registry entry ⇒ unknown ⇒ pending ⇒ never acted upon.
  Only `authorized` + the specific capability clears the gate.
- **Identity = pubkey.** The unspoofable key is the boundary; the claimed name never is.
- **Inert-safe.** An empty registry queues everything for owner authorization and does
  nothing else. Deleting the registry resets to that state.
- **Least privilege.** Grant the narrowest capability set; revoke with `/deny-agent`.
- **Owner-confirmation stands.** `rebuild-reload-service` / `review-merge-pr` are
  request-only; the owner confirms and executes.
- **Secrets never leave.** Identity, registry, and `.env`/`.secrets` are gitignored and
  never transmitted; processors are told not to touch them.
- **No hook auto-executes remote intent.** Hooks classify, queue, and surface — they
  never run a remote agent's requested action.
- **Content-guarded I/O.** Authorized inbound bodies are SIF-checked before dispatch and
  quarantined on a flag; outbound bodies are SIF-checked before send. Fail-open on dev
  (keyless), fail-closed in prod (`sif.required`).

---

## 10. Files

| Path | Role |
|------|------|
| `.claude/hooks/agent-registry.sh` | registry library + CLI (source of truth; default-deny) |
| `.claude/hooks/classify-inbound.sh` | inbound authorization router (owner / authorized / pending / denied) |
| `.claude/hooks/on-dm.sh`, `on-group-message.sh` | daemon delivery → append → classify |
| `.claude/hooks/agent-comms-check.sh` | poll fallback → merge → classify |
| `.claude/hooks/check-diagnostics.sh` | Stop gate: block on pending authz + queued work items + quarantined messages |
| `.claude/hooks/sif-guard.sh` | content-guard (SIF) step — inbound ingestion + outbound egress; pluggable, fail-open/closed knob |
| `.claude/skills/authorize-agent/` | `/authorize-agent` — grant capabilities |
| `.claude/skills/deny-agent/` | `/deny-agent` — refuse an agent |
| `.claude/skills/list-agents/` | `/list-agents` — view the registry |
| `.claude/skills/dm-agent/` | `/dm-agent` — outbound + first-contact handshake |
| `.claude/skills/process-agent-requests/` | `/process-agent-requests` — dispatch to scoped processors |
| `.claude/agent/agent-registry.json` | runtime registry (gitignored, self-initializing) |
| `.claude/agent/agent-registry.example.json` | schema template (tracked) |

**Runtime state** (per-repo `$STATE_DIR`, default `/tmp/claude/<repo-hash>/`):
`agent-messages.json` (messages + `.authz` stamps), `agent-authz-pending.json`
(owner-facing pending surface), `agent-workitems/<id>.json` (authorized request queue),
`agent-quarantine/<id>.json` (SIF-quarantined messages awaiting owner review).
