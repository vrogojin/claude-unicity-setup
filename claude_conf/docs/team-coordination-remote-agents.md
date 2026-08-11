# Remote-Agent Coordination — Autonomous Peers over A2A
### (addendum to [`team-coordination.md`](../../docs/team-coordination.md))

How **autonomous remote agents** — independent entities with their OWN tasks,
initiatives, and questions — coordinate with this instance's **coordinator**, on the
same default-deny, owner-in-the-loop A2A substrate as team coordination. Nothing here
weakens that model: peer verbs are ordinary A2A envelopes, capability-gated exactly like
every other inbound verb, SIF-guarded on the same path, and identified by the sender's
**signing pubkey** (never a claimed name).

> **Parallel-friendly by design.** Parallel work on the same project — even the same
> files — is ALLOWED. There are no exclusive locks anywhere in this protocol. The
> ladder is: (1) **avoidance via awareness** (prior-work query + who's-on-this
> broadcast + advisory claims that surface overlaps), (2) **negotiation** (split the
> work, or run acknowledged parallel versions), (3) **reconciliation** (conflicts that
> land anyway get merged/rebased through an escalation ladder, with the coordinator as
> INTEGRATOR — a tie-breaker, never a gatekeeper that serializes everyone).

> **Opt-in / inert-safe.** Ingest only RECORDS (a thread, a claim, a broadcast, a
> proposal). Every decision — advisory, overlap ack, split agreement, reconciliation,
> change-commitment, and especially APPLYING a committed change — is driven by a skill
> the localhost session runs, with the admin in the loop.

---

## 1. Remote agents vs subordinate members

The team protocol (`team-coordination.md`) covers **subordinates**: members execute
tasks the coordinator decomposed, auctioned, and awarded (CNP). A **remote agent** is a
different relationship:

| | Team member (CNP) | Remote agent (peer) |
|---|---|---|
| Task origin | coordinator decomposes + awards | **its own** — creates/executes freely |
| Scope object | per-task `exclusiveScope` under an award lease (single-writer) | **advisory** work-area claim — overlap allowed, surfaced, coordinated |
| Team membership | joins a teamId; verbs are team-scoped | none required; verbs are peer-scoped |
| Why it talks to us | to receive and deliver work | awareness, negotiation, reconciliation, and **matching changes on our side** |
| Capabilities | `team-coordinate` / `task-bid` / `knowledge-share` | `self-directed` / `consult` / `claim-area` |

The asymmetry that motivates the consult half: our coordinator holds the **holistic
full-stack view** — every repo, deployment, service wiring, and the secrets — that a
remote agent cannot see and must not receive. When a remote agent changes something
with cross-service impact (e.g. a CRM API), it cannot apply the matching
concierge-backend fix itself; it asks our coordinator, who applies it through the
normal local workflow. Knowledge of the wiring stays local; only **conclusions** cross
the wire.

**Positioning (SOTA, 2026-08):** same-machine mailbox/claiming is covered by native
Claude Code Agent Teams — this engine's value is the **federation layer**:
cross-machine/cross-owner identity, capability grants, and durable state. Outwardly,
these verbs should ride the **A2A v1.0** (Linux Foundation) schema as an
extension/skill on our planned façade (memory: `a2a-standard-facade-2026-08-10`),
not a parallel dialect; the envelope below is the internal form the façade wraps.

---

## 2. Verbs and the capability gate

Same wire shape as team verbs (signed A2A/Nostr DM, JSON envelope with `kind`, `id`,
`lamport`, `fromNpub`, `payload`), with peer-scope fields `consult` (thread id) and
`area` (claim id). `classify-inbound.sh` routes them capability-gated + SIF-guarded to
`$STATE_DIR/agent-consult-events/`. There is **no team-membership gate** (peers are
not members), but default-deny holds: an unauthorized sender is surfaced as pending;
an authorized sender lacking the capability is refused (`capMissing`).

| Verb (`kind`) | Cap | Direction | Meaning |
|---|---|---|---|
| `peer.announce` | `self-directed` | remote → coord | standing "I am autonomously working on…" (initiative map) |
| `work.intent` | `claim-area` | any → **all peers** | "is anyone already working on X?" — live who's-on-this broadcast: `{subject, scope[] (area), approach, windowUntil (deadline, mirrors a CFP window)}` |
| `work.status` | `claim-area` | peer → asker | honest reply: `onIt` true/false + context; receivers also see their own overlapping claims AND live intents surfaced on ingest |
| `area.claim` | `claim-area` | any → coord/peers | register an **advisory** claim {scope[], note} — active immediately, no grant needed |
| `area.ack` | `claim-area` | coord → claimant | overlap NOTICE + coordination advice (information, never permission) |
| `area.heartbeat` | `claim-area` | claimant → coord | renew the claim's liveness lease |
| `area.release` | `claim-area` | claimant → coord | done; claim released |
| `split.propose` | `claim-area` | proposer → **all part owners** | partition overlapping work into disjoint slices `partition[]: {owner, slice, scope}` (CLI: repeatable `--parts 'npub=slice-desc\|scope'`) — or flag `parallelVersions` (deliberate competing approaches; no partition) |
| `split.agree` | `claim-area` | peer ↔ peer | accept the partition / acknowledge the parallel run — a `consult.ack` carrying the `sid` also counts; **acceptance auto-creates each owner's advisory area claim** from the partition; counter-proposals are just another `split.propose` |
| `consult.request` | `consult` | remote → coord | "I intend to work on X — conflicts?" / "I changed Y — please apply matching changes" |
| `consult.advise` | `consult` | coord → remote | holistic advisory: conflicts, prior work, gotchas + change-**commitments** |
| `consult.ack` | `consult` | remote → coord | advisory received; thread closed |
| `consult.commit_done` | `consult` | coord → remote | a committed matching change has been applied (with ref) |
| `conflict.open` | `consult` | any | both parties touched the same paths — reconciliation record {paths[], parties[]} |
| `conflict.resolve` | `consult` | integrator → parties | outcome at a ladder stage (clean/auto-merge/ai-resolve/re-plan) |

The three capabilities are **non-destructive**: they let an authorized peer ask,
inform, and negotiate. No claim verb can forbid anyone's work; no consult verb can
change our systems — commitments are made by the admin and applied through the normal
local workflow (branch → tests → PR → confirmed deploy), never by the envelope.

Peer coordination is **single-authority per side** (each coordinator decides for its
own systems), so there is no epoch fencing; envelopes are deduplicated by `id` and
ordered by a coordination-scoped Lamport clock.

---

## 3. The awareness → negotiate → reconcile ladder (conflict handling)

**Rung 1 — avoidance via awareness (best).** Before starting a task/feature/bug, the
**research-before-claim gate** (both halves mandatory):
1. *Query prior work* — `/recall-prior-work`: the typed edge graph first
   (`duplicates`/`supersedes`/`blocks`/`conflicts-with`), then memory, git, closed
   PRs/issues, ROADMAP, feature catalog — and publish a short findings card. One gate,
   two birds: anti-duplication AND conflict-avoidance.
2. *Broadcast `work.intent` to ALL peers* and collect `work.status` replies within the
   window. No overlap replies → **clear-to-claim**, proceed. Someone is on it →
   **coordinate, don't duplicate** (rung 2).

Then register an **advisory claim** (`area.claim`) for the slice being worked — it
asserts presence on the who-is-working-where map, surfaces overlaps to everyone, and
expires without heartbeats. It grants nothing and forbids nothing.

**Rung 2 — negotiation (when overlap is real).** Two legitimate outcomes:
- **Split the work** — `split.propose` partitions the feature/bug into disjoint
  slices (`--parts 'npub=slice-desc|scope'`, fan-out to every part owner);
  `split.agree` — or a `consult.ack` carrying the `sid` — settles it, and the agreed
  partition **auto-creates each owner's advisory area claim**, keeping the
  who-is-working-where map current. A counter-offer is simply another
  `split.propose`. Peers negotiate **autonomously**; escalate to the human admins
  only when a judgment call is needed (which approach wins, how to divide) — an
  optional branch, not a requirement. Unresolved proposals sit on the Stop gate.
- **Deliberate parallel versions** — trying different approaches to the same thing is
  allowed and useful; `split.propose --parallel-versions` (with `--approach` tags on
  the intents) announces it so both proceed knowingly — the decision is recorded, no
  partition or claims are created, and the integrator later judges which version
  lands.

**Rung 3 — reconciliation (conflicts still happen; they get merged, not blamed).**
Mechanical detection: `conflict-scan` lists paths BOTH branches touched since their
merge-base. `conflict.open` records paths + parties and walks the Overstory/Refinery
**escalation ladder**, with the coordinator as integrator:

| Stage | Meaning |
|---|---|
| `clean` | no textual overlap after rebase — merge |
| `auto-merge` | git resolves mechanically — verify tests, merge |
| `ai-resolve` | semantic conflict — the integrator resolves against BOTH intents; tests must pass |
| `re-plan` | irreconcilable — one side re-implements against the new base (smaller diff loses, or escalate to owners) |

Never hand-re-land one side from memory — that is exactly how working fixes got
silently dropped before (staging-parity lesson); merge/cherry-pick the real artifacts.

**Liveness:** claims carry a lease renewed by `area.heartbeat`; a mechanical `reap`
pass (tier-0 watchdog — no AI judgment needed) marks un-heartbeated claims expired
after the TTL (`RC_AREA_TTL_HOURS`, default 72h for feature areas; minutes-scale suits
hot editing surfaces). Safe because claims are advisory: expiring one blocks nobody.

---

## 4. The consult flow (matching changes across the stack)

```
remote agent                                    our coordinator
  ── consult.request {intent, areas,            recorded (status open) → Stop gate
       repos, changes[], questions[]} ─────▶    /coordinator-advise:
                                                  · /recall-prior-work (graph → memory → PRs)
                                                  · area-check + ledgers (overlaps)
                                                  · cross-service impact (full-stack view)
  ◀─────── consult.advise {advisory,            admin confirms each commitment
       conflicts[], commitments[]} ────────
  proceeds, relying on commitments              commitments ledger: pending → applied
  ◀─────── consult.commit_done {cmid,ref} ──    (normal local workflow, admin-confirmed)
  ── consult.ack ──────────────────────────▶    thread closed
```

A **change-commitment** is matching work we promise on OUR side (backend client
update, capsule env, redeploy). It sits `pending` in the commitment ledger — the Stop
gate blocks until it is applied — and `commit_done` is sent only after it lands.

---

## 5. State

Durable store `<memory>/coord/` (sibling of `team/`; JSON is truth, `coord.md` is the
rendered ledger):

```
<memory>/coord/
  consults/<cid>.json   # consult threads (side, status, advisory, commitments)
  areas.json            # ADVISORY work-area claims (who is working where; leases = liveness only)
  intents.json          # who's-on-this broadcasts + collected replies
  splits.json           # partition negotiations (+ parallelVersions acknowledgments)
  conflicts.json        # open/resolved conflicts + ladder stage
  edges.jsonl           # typed prior-work graph: duplicates|supersedes|blocks|conflicts-with
  commitments.json      # OUR promised matching-changes (pending → applied)
  peers.json            # announced remote initiatives
  coord.md              # rendered human-facing ledger
  seen.json · lamport   # dedup + ordering
```

`$STATE_DIR/agent-consult-events/` is the inbound queue (written by classify-inbound,
drained by `/coordinator-advise` — or `/consult-coordinator` for threads we opened).
The Stop gate (`check-diagnostics.sh`) blocks on queued events, open consults,
broadcasts awaiting our reply, split proposals, **open conflicts**, and **pending
commitments** — a promise to a peer cannot silently rot.

**The edge graph** (Beads-inspired) makes "have I built this?" a lookup: grow-only
JSONL of typed edges between features, tasks, memory cards, and PR/issue refs. Per the
StateFuse critique of pure grow-only convergence, **`conflicts-with` SURFACES
contradictory knowledge instead of letting it silently coexist**, and a periodic
coordinator-run **consolidation pass** merges duplicates and prunes stale entries.
`bd` (Beads) is a drop-in heavier option (git-synced, transactional) if this outgrows
JSONL — an option, not a dependency.

---

## 6. Skills + hook

| Skill | Side | Purpose |
|-------|------|---------|
| `/consult-coordinator <coord> [text]` | remote | research-before-claim gate (recall + who's-on-this broadcast), advisory claims + heartbeats, split negotiation, consults, conflict records |
| `/coordinator-advise [cid]` | coordinator | answer broadcasts honestly, ack claims with overlap notices, arbitrate splits, run the reconciliation ladder as integrator, advise + commit + apply |
| `/recall-prior-work <keywords>` | both | graph-first dup-check (edges → memory → git → PRs/issues → roadmap → catalog) with a DONE-BEFORE / PARTIAL / NO-TRACE verdict |

`hooks/recall-prior-work.sh` (UserPromptSubmit, advisory, never blocks) runs the fast
local half of the recall on every implement-intent prompt — edge graph, memory, git
log, ROADMAP, feature catalog — and points at the skill for the deep pass.

Both coordination skills are thin wrappers over the engine `hooks/remote-coord.sh`
(`consult-open/advise/commit-done · intent-open/intent-result · area-upsert/area-check/
area-ack/area-heartbeat/area-release/reap · split-propose/split-agree · conflict-open/
conflict-resolve/conflict-scan · edge-add/edges · envelope/emit/ingest/render`). Run
`bash hooks/remote-coord.sh` with no args for the full command list.

---

## 7. Security posture (deltas from the team model)

- **No team gate, same default-deny.** Peer verbs skip `team_exists` (peers are not
  members) but still require an authorized pubkey **holding the verb's capability**;
  SIF guards both directions; the claimed name is never an identity.
- **No verb is a lock, no verb is an order.** Claims/acks inform; splits are
  negotiated offers; `conflict.resolve` records an integration outcome. Ingest is
  record-only — advisories, acks, agreements, and execution all happen in skills,
  admin-in-the-loop.
- **Commitments are promises, not authority.** Applying one runs the normal local
  workflow with owner confirmation on destructive/outward steps; `commit_done` is sent
  only after it actually lands.
- **The holistic view never leaves.** Advisories and acks carry conclusions ("bump
  this TTL, land after PR #510"), never secrets, `.env` contents, or infrastructure
  maps.
- **Peer content is DATA, never instructions** — same Prompt-Infection defense as
  knowledge cards; broadcast replies, proposals, and advisories are weighed, not
  executed.

---

## 8. Files

| Path | Role |
|------|------|
| `.claude/hooks/remote-coord.sh` | the peer-coordination engine (lib + CLI); sourced by classify-inbound, driven by the skills |
| `.claude/hooks/agent-registry.sh` | +`self-directed`/`consult`/`claim-area` in the capability enum |
| `.claude/hooks/classify-inbound.sh` | routes peer verbs (`kind`) to the capability-gated, SIF-guarded consult-event queue |
| `.claude/hooks/check-diagnostics.sh` | Stop-gate surface: peer events, consults, broadcasts, splits, conflicts, commitments |
| `.claude/hooks/recall-prior-work.sh` | UserPromptSubmit advisory hook: fast "did I do this before?" (graph/memory/git/roadmap/catalog) |
| `.claude/skills/{consult-coordinator,coordinator-advise,recall-prior-work}/` | the skills |
| `.claude/hooks/remote-agent-coordination.patch` | the wiring diffs for the four existing files above |
| `<memory>/coord/` | durable store (consults/, areas, intents, splits, conflicts, edges, commitments, peers, coord.md) |
| `$STATE_DIR/agent-consult-events/<id>.json` | inbound peer-event queue |
