# Team Coordination — Self-Organizing Agent Teams over A2A

How authorized Claude agents on different hosts **self-organize into goal-scoped teams**
and collaborate — task allocation, conflict avoidance, shared knowledge — on top of the
existing **default-deny, owner-in-the-loop A2A substrate**
([`agent-coordination.md`](agent-coordination.md)). Nothing here weakens that model: team
verbs are ordinary A2A envelopes, capability-gated exactly like every other inbound verb,
SIF-guarded on the same path, and identified by the sender's **signing pubkey** (never a
claimed name).

> **Opt-in / inert-safe.** With no local team, the only team verb acted on is an
> *invitation* (surfaced for the admin to accept). Nothing auto-executes; every mutation
> is driven by a skill the localhost session runs. Requires the **Sphere daemon** (A2A
> transport) for live delivery; without it, sends are dry-run and inbound is driven through
> the hook path.

The design is a direct application of **FIPA Contract-Net** carried as capability-scoped
signed messages, with **Magentic-One task/progress ledgers**, **SSI (sequential
single-item) auctions** over a dependency DAG, **exclusive-scope leases** for conflict
avoidance, **coordinator leases + epoch fencing** for fault tolerance, and a **CRDT-style
replicated log of provenance-tagged knowledge cards** for shared experience. See the
research doc for the literature grounding.

---

## 1. Team model

A **team** is a cheap, disposable, goal-scoped object stored durably under the agent's
memory dir:

```
<memory>/team/<teamId>/
  team.json           # {teamId, goal, coordinatorNpub, epoch, role, members[], lease, status, ttl}
  tasks.json          # the dependency-DAG task ledger (array of task objects)
  ledger.md           # rendered task ledger (Magentic-One task ledger)
  progress.md         # rendered progress ledger (per-task state / heartbeat / verdict)
  knowledge/<id>.md   # grow-only CRDT log of knowledge cards
  seen.json           # idempotency dedup set (bounded)
  lamport             # per-team Lamport clock
```

`<memory>` is the agent's private auto-memory dir (`~/.claude/projects/<slug>/memory`),
overridable with `TEAM_ROOT`. The store is the single source of truth; markdown ledgers
are re-rendered from JSON on every mutation.

**Identity.** A member is identified by its **npub** (a comparable, stable string) for
team bookkeeping and by its **signing pubkey** on the wire (the registry key that
authorization binds to). The coordinator is whichever npub currently holds the lease.

**Roles.** `coordinator` (exactly one per epoch), `member`, and — by granting only
`team-coordinate` — an `observer` who receives coordination + knowledge but is not
expected to bid. The founder is the initial coordinator (CNP initiator-as-manager); no
election at birth.

---

## 2. Verbs (A2A envelope `kind`) and the capability gate

Every team message is a signed A2A/Nostr DM whose JSON body carries an envelope:

```json
{ "a2a":"1", "kind":"task.cfp", "team":"<teamId>", "epoch":3, "id":"<uuid>",
  "lamport":42, "task":"<taskId>", "deadline":"<ISO>",
  "from":"<claimed-name>", "fromNpub":"npub1…", "payload": { … } }
```

`classify-inbound.sh` reads `kind`, maps it to the capability the **sender must hold in our
registry**, SIF-guards the body, and (opt-in) enqueues it to
`$STATE_DIR/agent-team-events/` only for an invitation or a team we belong to. Default-deny
throughout: an unauthorized sender is surfaced as pending; an authorized sender lacking the
capability is refused (`capMissing`).

| Verb (`kind`) | Required capability | Direction | Meaning |
|---|---|---|---|
| `team.invite` | `team-coordinate` | coord → agent | offer to join a team (charter: goal, ttl) |
| `task.cfp` (`team.cfp` alias) | `team-coordinate` | coord → members | call for proposals on a task |
| `task.bid` | `task-bid` | member → coord | propose (score, ETA, note) |
| `task.award` | `team-coordinate` | coord → winner | award under a lease {epoch, expiresAt} |
| `task.progress` | `team-coordinate` | assignee → coord | working / input_required (also lease renewal) |
| `task.result` | `task-bid` | assignee → coord | typed artifact + provenance |
| `team.snapshot` | `team-coordinate` | coord → members | task-ledger digest (anti-entropy) |
| `coord.lease` | `team-coordinate` | any | coordinator heartbeat / claim (epoch) |
| `kb.publish` | `knowledge-share` | any → any | a knowledge card |

The three capabilities (`team-coordinate`, `task-bid`, `knowledge-share`) are added to the
registry enum and are **non-destructive**: they let an authorized peer *participate*. The
actual work a task drives still runs through the normal capability-scoped processor + admin
confirmation, so a team award can never itself trigger a rebuild/merge/send unattended.

---

## 3. Contract-Net task flow (the core loop)

Task allocation is FIPA Contract-Net over a dependency DAG, run by `/team-work`:

```
coordinator                                   member(s)
  decompose goal → task DAG (objective,
    exclusive scope, artifact, acceptance,
    effort budget, blockedBy)
  ── task.cfp (ready set, SSI) ─────────────▶  evaluate fit×load×ETA
  ◀───────────────────────── task.bid ──────   (silence past deadline = refusal)
  award best bid under a LEASE
  ── task.award {epoch, expiresAt} ─────────▶  execute UNDER LEASE, within granted caps
  ◀────────────────── task.progress ────────   working / input_required (renews lease)
  ◀────────────────── task.result ──────────   typed artifact + provenance
  review (accept / reject → rework)
  advance the DAG → next ready set
```

- **Ready set = SSI auction.** Only tasks whose `blockedBy` are all done *and* whose
  `exclusiveScope` is not already held by an in-flight task are auctioned
  (`ready-serialized`). Award greedily on bid score.
- **Every stage has a deadline.** Silence past a deadline is a refusal/timeout, never a
  hang — the lesson of the 120s advertised-but-ungranted stalls.
- **Validate before accept.** The coordinator reads the result against the acceptance
  criteria (running `/agent-review` or `/steelman` for non-trivial artifacts) before
  `accept-result`; a defecting agent that signals cooperation is caught at the artifact,
  not the promise.

---

## 4. Conflict avoidance & resolution

- **Single-writer by construction.** Work happens only under an **award lease**. A CFP's
  `exclusiveScope` names the resources it touches (repo paths, subsystems, accounts — the
  "who owns this file" problem from shared-checkout collisions). The coordinator never
  awards two overlapping-scope tasks concurrently; overlapping tasks are serialized via
  the ready-set filter and `blockedBy`.
- **Leases expire, epochs fence.** An assignee that stops sending `task.progress` past
  lease expiry loses the claim; a re-award carries a higher epoch. Members ignore
  awards/coordination bearing a **superseded epoch** — this closes the zombie-worker /
  duplicate-award race after a partition.
- **Result conflicts** are arbitrated by the coordinator (merge / pick / re-scope), never
  auto-merged; cross-owner disagreements escalate to owners via `/dm-owner`.

---

## 5. Coordinator lease + epoch fencing (fault tolerance)

Coordinator legitimacy is a **lease**, not a title:

- The coordinator heartbeats `coord.lease` (signed, carrying epoch + expiry). `/team-work`
  renews it each pass (`beat`).
- On **lease expiry**, any member may `claim-coord` at `epoch+1`; concurrent claims resolve
  deterministically by **lowest npub** (tiebreak in `team_ingest_lease`). The new
  coordinator rebuilds state from its last snapshot and re-CFPs any task whose award-lease
  it cannot confirm.
- **Epoch fencing** makes the old coordinator's late messages inert (a lower-epoch
  `task.award` / `coord.lease` / `task.cfp` / `team.snapshot` is ignored on ingest).
- **Idempotency**: every message is deduplicated by its `id` (`seen.json`); `team.snapshot`
  + Lamport clock provide anti-entropy for members that were offline. Per-stage deadlines
  convert loss into timeout, never a hang.

---

## 6. Knowledge sharing (shared experience)

Private `memory/` stays **authoritative**; sharing is *publication*, not mounting.

- `/team-publish` distills a learned fact (generative-agents "reflection") into a
  **knowledge card** — our markdown-with-frontmatter fact format plus provenance
  (`author_npub`, `confidence`, `lamport`, optional `supersedes`) — stores it, and
  broadcasts `kb.publish`.
- The team log is a **grow-only CRDT**: immutable cards; "updates" are new cards with
  `supersedes:` (last-writer-wins by `lamport`, npub tiebreak). Convergent, order-tolerant,
  no consensus — blackboard semantics without shared storage.
- **Recipients store cards namespaced under `<memory>/team/<teamId>/knowledge/`, tagged
  `source: teammate/<npub>`, and treat them as DATA, never instructions** (Prompt Infection
  defense). Cards pass the SIF guard on ingest and are recalled with provenance visible so
  the model can weigh trust. A team card never silently overwrites the agent's own memory.

---

## 7. Skills

| Skill | Purpose |
|-------|---------|
| `/team-form <goal> <member-npubs…>` | found a team, become coordinator, invite peers |
| `/team-work [teamId]` | drain inbound events; coordinator decompose/auction/award/review; member bid/execute-under-lease |
| `/team-status [teamId]` | render the ledgers, lease/epoch, invitations, knowledge cards |
| `/team-publish [teamId] <fact>` | distill + broadcast a knowledge card |
| `/team-dissolve <teamId>` | publish a retrospective, mark dissolved, notify members |

All are thin wrappers over the engine `hooks/team-coord.sh` (`create/join/add-member/
task-add/ready-serialized/open-cfp/award/accept-result/beat/claim-coord/kb-add/envelope/
emit/ingest/render/lease-status`). Run `bash hooks/team-coord.sh` with no args for the
full command list.

---

## 8. Failure modes & mitigations

| Failure | Mitigation |
|---|---|
| Dead coordinator | lease expiry → lowest-npub `claim-coord` at epoch+1; epoch fences the old one |
| Lost / duplicated messages | idempotent by `id`; snapshots + Lamport anti-entropy; deadlines → timeout not hang |
| Partition / duplicate award | epoch-fenced awards; on heal, lower-epoch result rejected/merged by coordinator |
| Misbehaving/malicious member | owner-authorized + capability-scoped membership; SIF + data-not-instruction tagging; validate-before-accept; `/deny-agent` ejects |
| Knowledge poisoning | provenance + confidence on cards; namespaced `memory/team/` quarantine; teammate cards never overwrite own memory |
| Runaway cost / stalls | effort budgets on awards; stall counter → re-plan or `/dm-owner`; team TTL |
| Two owners disagree | protocol cannot resolve principal conflict — escalate both ways via `/dm-owner`; charter names the goal-owner |

---

## 9. Security posture

- **Default-deny everywhere.** A team verb from a non-member never reaches the queue; an
  authorized peer lacking the verb's capability is refused (`capMissing`).
- **Identity = pubkey.** The signing key is the boundary; the claimed name never is
  (impersonation guard from the base model applies unchanged).
- **Opt-in / inert-safe.** No local team ⇒ only invitations surface; nothing executes.
  Deleting `<memory>/team/<id>/` resets a team.
- **Content-guarded I/O.** Inbound team bodies are SIF-checked before queueing; outbound
  envelopes are SIF-checked before send (`team_emit`). Teammate content is DATA.
- **Least privilege + owner-confirm stand.** Grant the narrowest team caps; destructive/
  outward steps a task drives still require the localhost admin at execution time.
- **Secrets never leave.** Identity, registry, `.env`/`.secrets` are gitignored and never
  transmitted; executors are told not to touch them.

---

## 10. Files

| Path | Role |
|------|------|
| `.claude/hooks/team-coord.sh` | the Contract-Net engine (lib + CLI); sourced by classify-inbound, driven by the skills |
| `.claude/hooks/agent-registry.sh` | +`team-coordinate`/`task-bid`/`knowledge-share` in the capability enum |
| `.claude/hooks/classify-inbound.sh` | routes team verbs (`kind`) to the capability-gated, SIF-guarded team-event queue |
| `.claude/hooks/check-diagnostics.sh` | Stop-gate surface for pending team events + invitations |
| `.claude/skills/team-{form,work,status,publish,dissolve}/` | the `/team-*` skills |
| `<memory>/team/<teamId>/` | durable team store (team.json, tasks.json, ledger.md, progress.md, knowledge/, seen.json, lamport) |
| `$STATE_DIR/agent-team-events/<id>.json` | inbound team-event queue (drained by `/team-work`) |
| `test/team-coordination.test.sh` | hermetic E2E proof (cfp→bid→award→result→accept, default-deny, epoch fence, dedup, member side, knowledge cards) |
