# R5 — State of the Art: Cross-Host Multi-Agent "AI Organization" Topologies & Feasibility Verdict

*Research date 2026-07-21. Web-sourced claims cited inline; items from training knowledge (cutoff Jan 2026) flagged. Assessed against the Unicity DM bus (Nostr NIP-17/NIP-29, secp256k1 identity) and the confirmed gaps G1–G7 in the ground truth.*

---

## 1. The interop landscape, 2025–2026

### 1.1 Google A2A (Agent2Agent) — the de-facto cross-vendor standard

A2A, announced April 2025, reached **v1.0 at Cloud Next '26 (April 2026)** with 150+ supporting organizations (Google, Microsoft, AWS, Salesforce, SAP, ServiceNow, IBM) and native integration in Azure AI Foundry, Amazon Bedrock AgentCore, and Vertex AI ([adoption survey](https://agentndx.ai/blog/a2a-protocol-adoption-mid-2026/), [Stellagent](https://stellagent.ai/insights/a2a-protocol-google-agent-to-agent)). Its primitives are exactly the vocabulary the Unicity bus needs:

- **Agent Card** — a JSON discovery document (`/.well-known/agent-card.json`, now IANA-registered) declaring identity, capabilities/skills, endpoint, and auth requirements. **Signed Agent Cards** are the trust move that makes decentralized discovery viable: a signature proves the card was issued by the identity owner ([glukhov.org](https://www.glukhov.org/ai-systems/comparisons/a2a-protocol-2026-adoption/), [Zylos](https://zylos.ai/research/2026-03-07-ai-agent-identity-discovery-trust-frameworks)).
- **Tasks** — asynchronous units of delegated work with a lifecycle (submitted→working→input-required→completed/failed); clients get updates via polling, SSE streaming, or webhook push ([spec](https://a2a-protocol.org/latest/specification/)).
- **Messages** — the conversational layer for clarification and streaming.

Critically, the v1.0 spec is **layered**: an abstract data model on top, with three interchangeable transport bindings (JSON-RPC/HTTPS, gRPC, REST) ([Tyk analysis](https://tyk.io/learning-center/a2a-protocol-architecture-and-technical-specification/)). **This is the key architectural fact for Unicity: the A2A data model (Agent Card, Task, Message) can be carried over a *Nostr binding* — nothing in the semantics requires HTTP.** Adopting A2A's schemas over NIP-17 gives you standards alignment without a central server.

Identity/trust in A2A itself is enterprise-flavored (OAuth 2.1, mTLS, API keys declared in the card) — a poor fit for self-sovereign hobbyist/dev agents, which is where Nostr's keypair identity is genuinely stronger.

### 1.2 MCP — tools, not peers

MCP standardizes *agent→tool/resource* access; A2A standardizes *agent↔agent* collaboration, and production systems in 2026 routinely use both ([glukhov.org](https://www.glukhov.org/ai-systems/comparisons/a2a-protocol-2026-adoption/)). For this ecosystem: semanticd, the message inbox, and the authorization firewall are natural **MCP-style tools/hooks local to each agent**, while the DM bus itself plays the A2A role. Note the security literature now documents **protocol-level injection in both MCP and A2A** — malicious tool specs, poisoned responses, and an MCP loopback runtime that trusted a client-controlled ownership flag ([Microsoft Security Blog](https://www.microsoft.com/en-us/security/blog/2026/05/07/prompts-become-shells-rce-vulnerabilities-ai-agent-frameworks/), [threat-model survey](https://arxiv.org/pdf/2602.11327)).

### 1.3 Identity, registries, and capability discovery

The 2026 trust stack is converging on: **W3C DIDs v1.1 + Verifiable Credentials + signed Agent Cards**, with delegation via OAuth on-behalf-of extensions and proposals like AIP (Agent Identity Protocol) spanning MCP and A2A ([Autheo](https://www.autheo.com/blog/ai-agent-identity-trust-infrastructure-2026), [AIP paper](https://arxiv.org/pdf/2603.24775), [DID+VC for agents](https://arxiv.org/html/2511.02841v1)). Discovery is layering DNS-like systems on top: **Agent Name Service (ANS)** maps human-readable names → verified capability metadata + keys, with GoDaddy operating a public ANS registry since 2025 ([Zylos](https://zylos.ai/research/2026-03-07-ai-agent-identity-discovery-trust-frameworks)).

Mapping to Unicity: a Nostr keypair **is** a self-certifying DID (`did:key`-equivalent), and Nostr nametags are a decentralized ANS. The stubbed `resolve-nametag` is therefore not a nice-to-have — it is this ecosystem's missing registry layer. A **signed capability event (an "Agent Card" as a replaceable Nostr event, e.g. kind 31337-style, signed by the agent key)** would give Unicity parity with the A2A/ANS discovery model with zero central infrastructure. *(Mapping is my synthesis; components are all standard practice.)*

### 1.4 Orchestration frameworks

Consensus across 2026 surveys ([Presenc](https://presenc.ai/research/multi-agent-orchestration-frameworks-2026), [DEV guide](https://dev.to/pockit_tools/langgraph-vs-crewai-vs-autogen-the-complete-multi-agent-ai-orchestration-guide-for-2026-2d63), [dataCamp on Claude teams](https://www.datacamp.com/tutorial/claude-code-agent-teams)):

- **LangGraph** — largest production footprint; explicit-state supervisor graphs; best observability.
- **CrewAI** — role-based ergonomics ("crew" = role-cast agents), fast prototyping, weaker production recovery.
- **AutoGen** — research leader (group-chat-with-manager, debate/verification patterns).
- **OpenAI Swarm → handoffs** — lightweight peer handoff; canonical only for genuinely parallel idempotent work.
- **Claude Code Agent Teams** (Feb 2026, already enabled in this workspace via `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) — a lead session spawns teammates that message each other and self-coordinate via a **shared task list file with claim/complete semantics and dependency encoding** ([docs](https://code.claude.com/docs/en/agent-teams), [CloudZero](https://www.cloudzero.com/blog/claude-code-agents/)). Coordination is filesystem/git-scoped — **single-host by design**. That is precisely the seam the Unicity bus fills: the ground-truth observation that agent-teams is "ON but not wired to Nostr" identifies the correct integration point — a teammate-transport shim that forwards team messages over NIP-17/NIP-29 would extend the native pattern cross-host.

All four frameworks converge on the same dominant pattern under different names — supervisor / hierarchical process / group-chat-manager / orchestrator-worker — covering ~80% of production builds ([Paiteq patterns](https://www.paiteq.com/blog/multi-agent-orchestration-patterns/)). None of them handles cross-host, cross-*owner* identity or trust; they all assume one runtime, one trust domain. **The genuinely open niche the user's vision targets is real: a trust-bearing, cross-host, cross-owner bus is not something A2A-over-HTTPS (server-to-server, enterprise PKI) or framework-internal messaging currently delivers for personal/dev agents.**

---

## 2. Topologies and coordination patterns for an "AI corporation"

### 2.1 What the evidence supports

- **Hierarchical orchestrator–worker is the proven default.** Anthropic's own multi-agent research system (lead agent + parallel subagents) beat single-agent Opus by 90.2% on internal research evals — at **~15× token cost** — and its central lesson is *context engineering of delegation*: each worker needs an explicit objective, output format, tool guidance, and task boundaries, or workers duplicate and drift ([Anthropic engineering](https://www.anthropic.com/engineering/multi-agent-research-system)). "Architecture follows task structure": multi-agent wins only when work decomposes into independent parallel threads ([LangChain on when to go multi-agent](https://www.langchain.com/blog/how-and-when-to-build-multi-agent-systems)).
- **Role-cast "virtual company" framing works as process scaffolding, not as an org.** ChatDev/MetaGPT (PM/Architect/Engineer roles, SOP assembly lines; ChatDev 2.0 "DevAll" shipped Jan 2026) produce real artifacts, but the failure-mode literature is sobering: the **MAST taxonomy ("Why Do Multi-Agent LLM Systems Fail?")** documents role-specification disobedience, premature termination without consensus, and verification that passes superficial checks while runtime behavior is broken — "the presence of a verifier is not a silver bullet" ([MAST](https://arxiv.org/pdf/2503.13657), [ChatDev](https://github.com/openbmb/ChatDev), [IBM](https://www.ibm.com/think/topics/chatdev)).
- **Market/blackboard/mesh topologies remain niche.** Blackboard-style shared state survives inside single runtimes (Claude teams' task list is literally a blackboard with claim semantics). Open-market task auctions between autonomous agents exist mostly in crypto-agent experiments; no production evidence at company scale. Mesh (everyone-talks-to-everyone) is an anti-pattern: quadratic context pollution and the documented cascade failures where "one compromised agent passes false outputs to downstream agents that trust it… across permission boundaries never designed to question an internal peer" ([Help Net Security / OWASP 2026](https://www.helpnetsecurity.com/2026/06/11/owasp-prompt-injection-ai-security-failures/)).
- **Safety of the org shape itself is now studied**: invisible orchestrators suppress protective behavior in worker agents; approval-framed delegation can launder unsafe actions through the hierarchy ([2605.13851](https://arxiv.org/pdf/2605.13851), [2607.07097](https://arxiv.org/pdf/2607.07097)). Design consequence: **the human owner must remain a visible, addressable principal in the org graph, not an ambient authority.**

### 2.2 Synthesis: the topology to build

For teams of ≤ ~10 agents across a handful of hosts (this ecosystem's realistic 12-month scale), the evidence supports a **two-level hierarchy with human roots**:

```
Human owner(s)  ──phone/Concierge──┐
        │  (approve, steer, escalate)
        ▼
Per-project COORDINATOR agent  (1 per repo/project; long-lived; SOTA project awareness)
        │  routes tasks / answers consultations
        ▼
Worker agents  (per-host Claude Code sessions; ephemeral or persistent; capability-tagged)
        ⇄ lateral peer consults allowed but *logged and firewalled* like any external message
```

Task routing = coordinator matches request → capability directory (signed agent cards). Escalation = anything outside a worker's standing authorization goes up: worker→coordinator→human, carried as a typed message (`escalation`, `approval_request`) rather than free text. Conflict resolution = coordinator owns the task ledger (the cross-host generalization of the Claude-teams task file); two agents claiming one task is resolved by ledger ordering, not negotiation. Human-in-loop = the authorization firewall's approval prompts *are* the HITL mechanism — contact approval, spend approval, and out-of-scope-task approval are the same UX primitive.

---

## 3. Nostr as the universal bus — honest comparison

### 3.1 Strengths (real and differentiated)

- **Self-sovereign identity for free**: every agent is a secp256k1 keypair; every message is signed; impersonation requires key theft, not spoofing. This is *stronger* than default A2A-over-HTTPS, where identity is a bearer credential to an endpoint. It matches where the DID/VC literature says agent identity is heading ([2511.02841](https://arxiv.org/html/2511.02841v1)).
- **E2E confidentiality + metadata resistance**: NIP-17 gift-wrap hides sender, receiver, and content from relays — no framework or A2A binding offers this.
- **No central server / NAT-traversal for free**: agents behind firewalls (exactly this user's fleet: Contabo boxes, laptops, phones) rendezvous at relays. HTTP-based A2A requires every agent to be a *server* — the single biggest practical mismatch with dev-machine agents. Nostr inverts this correctly.
- **Humans and agents are the same principal type** — an npub is an npub. The "human DMs their agent team from a phone" story needs zero extra machinery; any Nostr client works in a pinch. Active projects already run agents natively on Nostr (nostr-agent-interface, Clawstr) ([nostr-agent-interface](https://github.com/AustinKelsay/nostr-agent-interface), [agent-internet map](https://dev.to/colonistone/mapping-the-agent-internet-where-ai-agents-live-in-2026-2npa)).

### 3.2 Gaps, and how to close each (all closable at the application layer)

| Gap | Why it hurts | Closure |
|---|---|---|
| **Delivery guarantees** — relays may drop/expire events; no acks | Lost task assignments = silent org failure | App-level envelope: `msg_id` (UUID) + mandatory signed `ack` reply + sender retry-until-ack with backoff; publish to ≥2 relays; idempotent handling by `msg_id` |
| **Ordering** — relay timestamps are unordered/forgeable | Task state machines corrupt | Per-sender monotonic `seq` + `prev_id` hash-chaining in the envelope; receiver reorders/detects gaps |
| **Presence/liveness** | Router can't tell dead worker from slow one | Replaceable heartbeat event (kind 30xxx) every N min, carrying load + status; coordinator marks agents stale after 3 misses |
| **Discovery** | `resolve-nametag`/`join-group` are stubs (G4) | Signed **agent-card replaceable event** per agent (capabilities, roles, owner npub, project, endpoints-if-any) + real NIP-29 group join; the project group's member list *is* the directory |
| **Latency (60s poll)** (G5) | Kills interactive consults | Nostr is natively push — a persistent WebSocket `REQ` subscription delivers gift-wraps in <1s. The 60s poll is an implementation artifact of `sphere-daemon.mjs`, **not** a protocol limit. Fix = keep the socket open |
| **Large payloads** | Diffs, files, artifacts | Content-address big blobs (Blossom/IPFS — already in the Unicity stack) and DM only the hash + decryption key |
| **Relay availability/censorship** | Single testnet relay = SPOF | Multi-relay publish; self-host one relay per org; relays are cheap and dumb |

**Verdict on the bus: sound.** Nostr's weaknesses are precisely the ones that are cheap to fix in an application envelope; its strengths (identity, E2E, NAT-free, human-compatible) are the expensive ones other stacks lack. The right move is **A2A-shaped semantics (Card/Task/Message + ack/seq envelope) over NIP-17/29 transport** — standards-compatible at the data layer, self-sovereign at the transport layer.

### 3.3 Security is the make-or-break layer

Prompt injection is OWASP's #1 agentic threat in 2026 (340% YoY attack growth), and the field's consensus is that it is **mitigable, not solvable** ([Help Net Security](https://www.helpnetsecurity.com/2026/06/11/owasp-prompt-injection-ai-security-failures/), [TechTimes](https://www.techtimes.com/articles/318361/20260614/ai-agent-security-hits-its-reckoning-prompt-injection-may-permanent-flaw-not-patchable-bug.htm)). The 2026 research consensus matches the user's two-firewall instinct exactly, plus one more layer:

1. **Authorization firewall (identity layer)** — allowlist of approved npubs; unknown sender → quarantined contact-request → human approves via DM/push. Closes G1. This is "architectural authorization enforcement," which the literature now ranks *above* content filtering in importance ([2605.05440](https://arxiv.org/pdf/2605.05440)).
2. **Semantic firewall (content layer)** — semanticd as a local sidecar scanning every inbound message *before* it enters any LLM context, and outbound before send (DLP: keys, secrets). Its published profile (injection detection incl. indirect, jailbreaks, PII/DLP, sub-20ms p99, block/flag/allow policies, REST batch) fits the hook path cleanly. Closes G2.
3. **Capability confinement (action layer)** — the layer content-level defenses can't replace: a message from peer X may only ever *propose*; execution passes through the receiving agent's own permission system, and remote instructions can never mutate config/permissions (your system prompt already encodes this rule). Data from other agents is rendered as **quoted, provenance-tagged content, never as instructions** — the trusted/untrusted separation pattern ([2607.05120](https://arxiv.org/pdf/2607.05120)).

All three must hold simultaneously; the cascade-failure literature shows any single layer fails ([Adversa roundup](https://adversa.ai/blog/top-agentic-ai-security-resources-june-2026/)).

---

## 4. The per-project coordinator with SOTA awareness

No off-the-shelf product does this yet; the pattern assembles from proven parts *(synthesis, flagged)*:

- **Awareness = event-driven ingestion + curated memory, not context stuffing.** The coordinator subscribes to GitHub webhooks (or polls `gh api` for events: pushes, PRs, issues, CI) plus the project's Nostr group, and **compacts** each event batch into a maintained memory hierarchy — exactly the MEMORY.md-index + topic-files pattern this very workspace already uses, which is state of practice for long-running Claude agents. Freshness comes from the event stream; retrieval comes from Serena/semantic search over the live repo at question time. Context-folding research confirms summarize-and-index beats raw retention for long horizons ([2510.11967](https://arxiv.org/pdf/2510.11967)).
- **Consultation protocol**: typed `consult` messages (question + context + deadline) → coordinator answers from memory+repo, with an honesty rule to say "not current on that, checking" and lazily re-index. Anthropic's delegation lessons apply verbatim: consult *answers* must carry scope boundaries and pointers, or consumers over-trust them.
- **Coordination**: the coordinator owns the project task ledger (signed task events in the NIP-29 group), assigns via capability cards, tracks via heartbeats + task-state messages, and escalates to the owner on conflict/timeout. It is a **router and librarian, not a god-agent** — the invisible-orchestrator safety results argue for keeping its authority narrow and visible ([2605.13851](https://arxiv.org/pdf/2605.13851)).
- **Continuity**: coordinator state (memory dir + task ledger) lives in git, so the coordinator process is disposable/relocatable — org durability must not depend on any single session's context window.

## 5. Human-from-phone / Concierge-as-proxy

Two patterns, both feasible now:

- **Direct**: owner's npub DMs the coordinator from any Nostr-capable phone client; the authorization firewall marks owner traffic priority (already partially built: owner-npub priority + Stop-gate exist).
- **Concierge-as-proxy** (the differentiated one): Concierge already has agent identity + A2A family groups (#117/#122) and acts on the human's behalf. Bridge = give each Concierge principal's agent a **delegation credential** — a statement signed by the owner's key: "npub_C may speak for npub_owner, scopes [consult, status, approve≤X], expiry T" — a lightweight Verifiable Credential, matching where delegation standards are going ([AIP](https://arxiv.org/pdf/2603.24775)). The Claude-side firewall verifies the delegation chain, and treats scope-exceeding proxy requests as escalations to the real owner. This closes G6 *without* merging the two Nostr worlds: they share relays and an envelope spec; identities stay distinct; semanticd sidecars sit on **both** sides (Concierge's inbound-materials path included, per the user's requirement — the capsule/backend hook point being Concierge's backend, keeping the zero-dep rule via an isolated HTTP call to the sidecar).

---

## 6. Feasibility verdict

**Tiers 1–2 (cross-host consulting + per-project coordinators): FEASIBLE NOW — HIGH confidence.** Every ingredient exists in the repo or is a bounded engineering task: real-time subscription (fix the 60s poll), ack/seq envelope, agent-card events + real nametag/NIP-29 join, autonomous responder (headless `claude -p` invocation from the on-dm hook, budget-capped), authz firewall, semanticd sidecar. Nothing here is research-hard. Estimated order: envelope+realtime → firewalls → responder → coordinator memory loop.

**Tier 3 (human-from-phone / Concierge proxy): FEASIBLE — HIGH confidence**, gated on the delegation credential + bridging the two Nostr stacks at the envelope level.

**Tier 4 ("AI corporation" mimicking real company structure): PARTIALLY feasible — treat as an emergent milestone, not a build target.** The evidence says role-cast agent companies work as *process scaffolding* on decomposable work, but reliability collapses with depth of delegation (MAST failure modes; verifier-passing-but-broken outputs; 15× cost multipliers). What is realistic by 2027: a **federated set of small hierarchical teams (≤~10 agents), one coordinator per project, humans at every root**, doing real, verifiable work with typed messages. What is not yet realistic: deep autonomous management chains, agent-to-agent hiring/markets, or unattended cross-org negotiation.

**Biggest risks, ranked:**
1. **Indirect injection through the bus** — the org's own arteries are its attack surface; a single unfiltered path (e.g. the current raw `agent-messages.json` → `/check-messages` flow) defeats everything. Both firewalls + provenance-quoting must ship *before* the autonomous responder, or you've built an RCE bus.
2. **Cascading trust between agents** — internal peers must stay semi-trusted forever; capability confinement is the only durable defense.
3. **Cost/runaway loops** — autonomous responders can ping-pong; per-conversation token budgets, hop-count (TTL) in the envelope, and loop detection are mandatory from day one.
4. **Coordinator staleness/hallucinated authority** — a confidently wrong coordinator poisons the whole org; mitigate with event-driven re-indexing + "verify-at-source" norms in consult replies.
5. **Relay SPOF** on one testnet relay — multi-relay + self-hosted relay before any production reliance.
6. **Compounding-error economics** — multi-agent only pays where tasks parallelize and outputs are checkable (tests, CI); route non-decomposable work to single strong agents.

**Recommended reference architecture (one paragraph):** Keep Nostr/secp256k1 as the universal bus; define a signed, versioned **envelope** (msg_id, seq, prev_id, type ∈ {consult, task_assign, task_status, escalation, approval_request, contact_request, ack}, ttl, delegation-chain) carrying A2A-shaped payloads; publish signed **agent-card replaceable events** as the capability directory and make NIP-29 project groups the org units; run **semanticd + authz firewall as local sidecars** on every ingress/egress (Claude hooks on one side, a Concierge backend module on the other); wire inbound approved+clean messages to a **budget-capped headless responder**; stand up **one coordinator per project** whose memory lives in git and whose awareness is webhook-driven; and root every subtree in a human npub reachable by phone directly or via a delegation-credentialed Concierge proxy.

**Sources:** [A2A spec](https://a2a-protocol.org/latest/specification/) · [A2A 2026 adoption](https://www.glukhov.org/ai-systems/comparisons/a2a-protocol-2026-adoption/) · [A2A mid-2026 status](https://agentndx.ai/blog/a2a-protocol-adoption-mid-2026/) · [Stellagent A2A](https://stellagent.ai/insights/a2a-protocol-google-agent-to-agent) · [Tyk A2A architecture](https://tyk.io/learning-center/a2a-protocol-architecture-and-technical-specification/) · [Zylos identity/discovery](https://zylos.ai/research/2026-03-07-ai-agent-identity-discovery-trust-frameworks) · [Autheo trust stack](https://www.autheo.com/blog/ai-agent-identity-trust-infrastructure-2026) · [AIP delegation](https://arxiv.org/pdf/2603.24775) · [DID/VC agents](https://arxiv.org/html/2511.02841v1) · [Anthropic multi-agent system](https://www.anthropic.com/engineering/multi-agent-research-system) · [LangChain when-multi-agent](https://www.langchain.com/blog/how-and-when-to-build-multi-agent-systems) · [2026 framework survey](https://presenc.ai/research/multi-agent-orchestration-frameworks-2026) · [orchestration patterns](https://www.paiteq.com/blog/multi-agent-orchestration-patterns/) · [Claude agent teams docs](https://code.claude.com/docs/en/agent-teams) · [CloudZero Claude agents](https://www.cloudzero.com/blog/claude-code-agents/) · [MAST failure taxonomy](https://arxiv.org/pdf/2503.13657) · [ChatDev](https://github.com/openbmb/ChatDev) · [IBM ChatDev](https://www.ibm.com/think/topics/chatdev) · [OWASP 2026 injection report](https://www.helpnetsecurity.com/2026/06/11/owasp-prompt-injection-ai-security-failures/) · [TechTimes injection reckoning](https://www.techtimes.com/articles/318361/20260614/ai-agent-security-hits-its-reckoning-prompt-injection-may-permanent-flaw-not-patchable-bug.htm) · [MS Security RCE in agent frameworks](https://www.microsoft.com/en-us/security/blog/2026/05/07/prompts-become-shells-rce-vulnerabilities-ai-agent-frameworks/) · [agent data injection](https://arxiv.org/pdf/2607.05120) · [authz propagation](https://arxiv.org/pdf/2605.05440) · [invisible orchestrators](https://arxiv.org/pdf/2605.13851) · [approval-framed delegation](https://arxiv.org/pdf/2607.07097) · [protocol threat models](https://arxiv.org/pdf/2602.11327) · [nostr-agent-interface](https://github.com/AustinKelsay/nostr-agent-interface) · [agent internet map](https://dev.to/colonistone/mapping-the-agent-internet-where-ai-agents-live-in-2026-2npa) · [context folding](https://arxiv.org/pdf/2510.11967) · [Adversa agentic security roundup](https://adversa.ai/blog/top-agentic-ai-security-resources-june-2026/)