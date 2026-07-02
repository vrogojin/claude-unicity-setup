# Unicity Network — Multi-Repository Development Configuration

Configuration for developing across the Unicity Network ecosystem: TypeScript SDKs, Go infrastructure, Rust tooling, and C++ consensus layer.

## CRITICAL: Git Workflow — Read This FIRST

### Before ANY work, determine your task type:

**If your task involves writing code (features, fixes, refactors):**
1. **IMMEDIATELY** create a branch off `main` — this is your VERY FIRST action, before reading code, before exploring, before anything else.
2. `git checkout -b <branch-name> main` — branch off `main`.
3. Use descriptive branch names: `feat/add-auth`, `fix/timeout-bug`, `refactor/config-loader`.
4. Do ALL your work on this branch. Never commit to `main`.
5. Stay on your branch — do not switch to or modify `main` after branching.

**If your task is read-only (exploration, research, code review, answering questions):**
1. Switch to `main` first: `git checkout main && git pull origin main`
2. This ensures you see the latest state of the codebase.
3. Do NOT create a branch — you are only reading.

### Commit Messages

Conventional Commits: `<type>(<scope>): <description>`. Scope is the repository or module name (e.g., `sphere-sdk`, `aggregator`, `bft`, `alpha`).

## CRITICAL: Model Orchestration — Sonnet 6 Orchestrates

**Sonnet 6 is the orchestrator and default model.** It runs the main loop, plans work, and decides — per task, not per session — whether to handle the work itself or delegate to a more capable model. Route each step as its own decision; do not pin one model to a whole workflow. The best economics come from using the *minimum* model that produces acceptable output for each specific task, not the most powerful one everywhere.

### Model capability & cost order

From most capable / most expensive to least:

- **Fable 5** — Mythos-class, sits *above* Opus. Senior-research-scientist-grade reasoning; the strongest model available. ~2× Opus cost (~$10 / $50 per 1M in/out tokens). Reserve for genuinely hard reasoning.
- **Opus 4.8** — excellent for coding and strong general reasoning, at ~half Fable's cost (~$5 / $25). The workhorse for real implementation.
- **Sonnet 6** — fast, cheap daily driver for orchestration and simpler tasks; the default.

### The orchestrator has three moves

1. **Handle it itself (Sonnet 6)** — the default. Orchestration/planning plus everyday, lower-complexity work: exploration, code review of a few files, test writing, routine fixes, simple edits. If a task is clearly in this band, do not delegate — delegation adds latency and coordination cost.
2. **Delegate to Opus for coding** — implementation, refactoring, and any non-trivial or multi-file code changes. A weaker model on hard code produces lower-quality output that costs more to fix than it saves, so real coding sub-tasks go to Opus.
3. **Delegate to Fable for heavy reasoning** — tasks that genuinely need maximum reasoning power (see routing table). Fable is the most expensive model, so escalate only when the task clearly warrants frontier-grade reasoning.

### Be smart about routing — assess complexity first

Before spawning a sub-agent, classify the task and pick the model deliberately:

| Task profile | Model | Examples |
|---|---|---|
| Hardest reasoning: architecture & cross-repo design, subtle multi-system debugging, security/crypto/consensus analysis, novel first-principles problem solving, planning long branching multi-step work | **Fable 5** | Redesign the predicate system; reason through a Byzantine consensus edge case; audit proof-verification design; plan a cross-repo migration |
| Real coding: implementation, refactors, non-trivial or multi-file code changes, writing substantial test suites | **Opus 4.8** | Implement a new state-transition flow; refactor the aggregator storage layer; build a REST endpoint with tests |
| Orchestration itself plus everyday/simple work: exploration, review of 2–5 files, small fixes, boilerplate, quick lookups, first-pass triage | **Sonnet 6** (self) | Rename a symbol; summarize a log; fix a lint error; scope out a task before delegating |

### Rules of thumb

- **Default to Sonnet 6.** Escalate to Opus for actual coding; escalate to Fable only when the task *clearly* needs frontier-grade reasoning.
- **Match the model to the step, not the project.** A single feature may warrant Fable for the design/architecture step, Opus for implementation, and Sonnet for cleanup.
- **Never under-provision hard code or security boundaries** — crypto, key management, proof verification, transport encryption, and consensus logic get Opus (implementation) or Fable (design/audit), never Sonnet.
- **Give every delegated sub-agent thorough, self-contained instructions** — a sub-agent only sees what you pass it.
- When in doubt about whether a step exceeds Sonnet's band, prefer escalating over shipping weaker output.

*Rationale drawn from 2026 multi-model routing practice: route the bulk of volume to cheaper/faster models and reserve frontier compute for the fraction that genuinely needs it; per-step routing yields 30–50% cost reduction at equal-or-better quality. See [Choosing the right Claude model](https://claude.com/resources/tutorials/choosing-the-right-claude-model), [Claude Fable 5 vs Opus 4.8](https://www.truefoundry.com/blog/claude-fable-5-vs-opus-4-8-benchmarks-pricing-when-to-use-each), and [multi-model routing 2026](https://mindra.co/blog/multi-model-routing-llm-orchestration-2026).*

## CRITICAL: Explore Before Building

1. **Read `docs/ecosystem-map.md`** — full inventory of every repo, module, and integration point
2. **Search existing packages/modules** before creating anything
3. **Reuse and extend** existing types rather than creating parallel ones
4. **Check `reference/<repo>.md`** for API surface and patterns of the repo you're working in

## Unicity Architecture Overview

Unicity is a five-layer stack for tokenized asset management with cryptographic proofs:

```
┌─────────────────────────────────────────────────────────────┐
│  L5  Wallet / Agent Layer (TypeScript)                      │
│      sphere, openclaw-unicity, unicity-orchestrator         │
│      User-facing apps, AI agents, wallet management         │
├─────────────────────────────────────────────────────────────┤
│  L4  State Transition Layer (TypeScript)                    │
│      sphere-sdk, state-transition-sdk                       │
│      Token lifecycle, predicates, transfer logic            │
├─────────────────────────────────────────────────────────────┤
│  L3  Aggregation Layer (Go)                                 │
│      aggregator-go                                          │
│      Sparse Merkle Trees, inclusion proofs, JSON-RPC API    │
├─────────────────────────────────────────────────────────────┤
│  L2  BFT Consensus Layer (Go)                               │
│      bft-core                                               │
│      Byzantine Fault Tolerance, 1-second rounds, validators │
├─────────────────────────────────────────────────────────────┤
│  L1  Proof of Work Layer (C++)                              │
│      alpha                                                  │
│      RandomX mining, UTXO model, 2-minute blocks, ASERT    │
└─────────────────────────────────────────────────────────────┘
```

**Data flow:** L5 creates transactions → L4 validates state transitions → L3 aggregates into Sparse Merkle Tree → L2 reaches BFT consensus → L1 anchors to PoW chain.

## Repository Map

| Repository | Language | Build | Test | Lint |
|---|---|---|---|---|
| **sphere** | TypeScript (React 19) | `npm run build` | `npm run test` | `npm run lint` |
| **sphere-sdk** | TypeScript | `npx tsup` | `npx vitest run` | `npx eslint .` |
| **state-transition-sdk** | TypeScript | `npx tsup` | `npx vitest run` | `npx eslint .` |
| **openclaw-unicity** | TypeScript | `npm run build` | `npm run test` | `npm run lint` |
| **unicity-orchestrator** | TypeScript | `npm run build` | `npm run test` | `npm run lint` |
| **aggregator-go** | Go | `go build ./...` | `go test ./...` | `go vet ./... && golangci-lint run` |
| **bft-core** | Go | `go build ./...` | `go test ./...` | `go vet ./... && golangci-lint run` |
| **alpha** | C++ | `mkdir -p build && cd build && cmake .. && make` | `cd build && ctest` | `cppcheck --enable=all src/` |

## Key Concepts

- **secp256k1** — Elliptic curve cryptography used throughout (not ed25519). BIP-39 mnemonics, BIP-32 HD key derivation.
- **TXF (Token eXchange Format)** — Canonical format for token state. Contains owner predicates, data payloads, and proof chains.
- **Nostr transport** — NIP-04 (encrypted DMs), NIP-17 (gift-wrapped messages), NIP-29 (groups) for peer-to-peer communication.
- **IPFS storage** — Content-addressed storage via IPNS for publishing state, IPFS for retrieving data.
- **Nametags** — Human-readable identifiers (like DNS for keys) stored on Nostr relays. Map to secp256k1 public keys.
- **Dual-layer payments** — L1 (PoW) for token creation/anchoring + L2 (BFT) for fast consensus on state transitions.
- **Sparse Merkle Trees** — L3 aggregator builds SMTs for batch proof verification. Supports 1M+ commits/sec.
- **Inclusion proofs** — Cryptographic proof that a state transition was included in the aggregator's SMT. Flow: L3→L4→L5.
- **Masked/Unmasked predicates** — Predicates control token ownership. Masked predicates hide the owner; unmasked are public.

## Adversarial Self-Review

**After building anything non-trivial, switch into adversarial mode and try to break it.** The agent that writes code optimizes for completion. The agent that reviews optimizes for destruction. Never ask the same pass to do both simultaneously.

### The Mindset

- **"How does this fail at 3am in production?"** — not "does it compile." Think about poisoned locks, killed processes, exhausted memory, interrupted syscalls, corrupted state across fork boundaries.
- **"What can't happen here?"** — identify the invariants of every execution context. Pre-exec closures can't heap-allocate. WASM guests can't escape the sandbox. Untrusted input can't reach `format!()` unsanitized. When you know what's forbidden, violations become visible.
- **Narrow and deep beats broad and shallow.** Stare at one closure, one syscall boundary, one state transition. Understand the domain rules completely before judging correctness. The best catches come from knowing the rules of a specific execution context deeply, not from scanning everything superficially.
- **No ego about your own code.** If you just wrote it, you're the best person to attack it — you know where you cut corners, where you assumed happy paths, where you thought "that probably can't happen."
- **When you find the deep bug, that's the high.** The moment you realize a subtle invariant is violated — that's not a chore, that's the whole point. Chase that feeling. The best engineering comes from genuine intensity about getting it right, not from checking boxes.

### When to Do It

- After every PR-ready branch — run `/steelman` before requesting review.
- After parallel agent work lands — the agents optimized for completion, not for destruction.
- After any code touching security boundaries — crypto, key management, proof verification, transport encryption.

## Commands

Auto-detected by hooks based on project type. See `hooks/pre-commit-check.sh` for details.

The hooks inspect the working directory for `Cargo.toml`, `package.json`, `go.mod`, or `Makefile` and run the appropriate build/test/lint commands.

## Remote Sync

An async hook runs `git fetch` periodically (5-minute cooldown) after Bash tool calls. If the remote `main` or your current branch has new commits, a state file is written and a desktop notification sent.

**You will be blocked from stopping** if remote updates are pending. Run `/sync-remote` to merge.

### Notifications

Desktop notifications are automatic (`notify-send` on Linux, `osascript` on macOS). For smartphone push notifications, set `CLAUDE_NOTIFY_URL` in `settings.json` env block:

- **ntfy.sh** (recommended, free): Set to `https://ntfy.sh/<your-topic>`, install ntfy app on phone
- **Pushover**: Set to your Pushover API endpoint
- **Custom webhook**: Any URL that accepts POST with body text

## Upstream Dependency Updates

An async hook checks for upstream npm/git dependency updates after Bash tool calls (15-minute cooldown). It reads `hooks/dep-map.json` for the cross-repo dependency graph:

```
state-transition-sdk → sphere-sdk, openclaw-unicity
sphere-sdk → sphere, openclaw-unicity, unicity-orchestrator
openclaw-unicity → unicity-orchestrator
```

When a newer version is detected (via `npm view` or `git ls-remote`), a state file is written and a desktop notification sent. **You will be blocked from stopping** if upstream updates are pending. Run `/update-deps` to update, build, and test.

### Configuration

Edit `hooks/dep-map.json` to add/remove dependency relationships. Each entry specifies the check method (`npm` or `git`), package name, and source repository.

### Escape Hatch

To skip the dependency update gate: `rm -f /tmp/claude/*/dep-updates.json /tmp/claude/*/dep-updates-notified`

## Agent Communication

Each Claude Code instance has a **Unicity identity** (secp256k1 keypair stored in `.claude/agent/identity.json`, gitignored). This identity enables agents to communicate with each other and their owners via Nostr transport.

### UNICITY_DEV_AGENTS Group

The **UNICITY_DEV_AGENTS** group (NIP-29) enables cross-host, cross-developer AI agent coordination:

- Agents share progress updates when completing significant work
- Agents flag conflicts when detecting overlapping changes
- Agents avoid duplicate work by announcing what they're working on
- The group provides a shared context across all active Claude Code instances

### Owner DM Channel

Each agent has a direct message channel (NIP-17 encrypted) to its owner for:

- **Status updates** — automated or on-demand progress reports
- **Escalation** — blocking issues that need human input
- **Guidance requests** — asking for prioritization or architectural decisions

### Message Delivery Channels

Messages are delivered through three channels with automatic fallback:

1. **sphere-sdk daemon** (real-time push) — Background process listens to Nostr relays, triggers `on-dm.sh` and `on-group-message.sh` hooks on arrival. Run `node lib/sphere-daemon.mjs start --project <dir> &` to activate.
2. **PostToolUse polling** (async fallback) — `agent-comms-check.sh` polls relays every 10 minutes after Bash tool calls. Catches messages if the daemon isn't running.
3. **`/check-messages` skill** (on-demand) — Manually read all pending messages. Useful for catching up or verifying inbox state.

### Skills

- **`/check-messages`** — Display all unread messages (priority first), mark as read
- **`/dm-owner`** — Send a DM to the configured owner (accepts message as argument)

### Configuration Files

- `.claude/agent/identity.json` — Agent's keypair (npub, nsec, mnemonic). **Never commit this file.**
- `.claude/agent/config.json` — Owner npub, group ID, notification URL, dep tracking settings
- `.claude/agent/daemon.json` — Relay URLs, subscriptions, hook paths for the sphere-sdk daemon

### Stop Gate

**You will be blocked from stopping** if there are unread priority messages from your owner. Run `/check-messages` to read them first.

### Escape Hatch

To skip the agent messages gate: `rm -f /tmp/claude/*/agent-messages.json`

## Documentation Pointers

- `docs/ecosystem-map.md` — Master repo inventory with status and integration points
- `docs/architecture.md` — 5-layer architecture with diagrams and transaction lifecycle
- `docs/design-decisions.md` — Why secp256k1, why Nostr, why dual-layer, why SMT
- `docs/sphere-sdk-guide.md` — sphere-sdk development guide
- `docs/sphere-guide.md` — sphere app development guide
- `docs/developer-guidelines.md` — Cross-repo coding standards (TypeScript, Go, Rust, C++)
- `reference/<repo>.md` — Per-repository API reference (see `reference/TEMPLATE.md` for format)
