# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

This is the Claude Code configuration repository for the **Unicity Network** ecosystem — a multi-language, multi-repository development environment covering TypeScript SDKs, Go infrastructure, Rust tooling, and C++ consensus layer. The `claude_conf/` directory contains the full `.claude/` configuration that gets deployed to any Unicity workspace.

## Model Orchestration

**Sonnet 6 orchestrates and is the default model.** Decide per task — not per session — whether to handle it yourself or delegate. Model capability/cost order (most capable/expensive first): **Fable 5** (Mythos-class, above Opus; frontier reasoning; ~2× Opus cost) > **Opus 4.8** (excellent for coding) > **Sonnet 6** (fast, cheap default).

- **Handle it yourself (Sonnet 6)** — orchestration/planning plus everyday, low-complexity work: exploration, small fixes, review of a few files, quick lookups.
- **Delegate coding to Opus** — implementation, refactors, non-trivial or multi-file code changes.
- **Delegate heavy reasoning to Fable** — hardest reasoning only: architecture, subtle multi-system debugging, security/crypto/consensus analysis, novel problem solving. It's the most expensive model, so escalate only when the task clearly warrants it.

Route per step (a feature may use Fable to design, Opus to implement, Sonnet to clean up), default to Sonnet 6, and never under-provision hard code or security boundaries. See `claude_conf/CLAUDE.md` → "Model Orchestration" for the full policy applied in deployed workspaces.

## Repository Structure

```
setup.sh                       # Interactive setup: deploy config, create identity, join group
#                                (use `--serena-only <repo>` to re-apply just the Serena MCP config)
lib/
├── sphere-helper.mjs          # Node.js CLI helper wrapping sphere-sdk for agent ops
└── sphere-daemon.mjs          # Background daemon: listens for Nostr DMs/group messages
claude_conf/
├── CLAUDE.md                  # Main CLAUDE.md for Unicity projects
├── .mcp.json                  # MCP servers (Serena, Dockerized): broad READ-ONLY identity mount of the
#                                workspace root → Serena sees every branch/worktree/repo; setup.sh deploys to project root
├── docker/
│   └── Dockerfile.serena      # Custom Serena image (adds Go+gopls, clangd to official image)
├── settings.json              # Hooks config (PreToolUse, Stop, PostToolUse), team agents mode
├── settings.local.json        # Permissions, sandbox config, MCP servers
├── hooks/                     # Shell hooks enforcing workflow
│   ├── branch-guard.sh        # Blocks Edit/Write on main/master
│   ├── prefer-serena.sh       # Blocks native Grep on code; redirects to Serena semantic tools
│   ├── pre-commit-check.sh    # Auto-detect: blocks git commit if lint/format fail
│   ├── check-diagnostics.sh   # Auto-detect: blocks stop if build errors, remote updates, dep updates, or urgent messages pending
│   ├── steelman-plan.sh       # Forces adversarial self-critique before ExitPlanMode
│   ├── remote-sync-check.sh   # Async: detects remote branch updates (PostToolUse)
│   ├── dep-update-check.sh    # Async: detects upstream dependency updates (PostToolUse)
│   ├── agent-comms-check.sh   # Async: fallback polling for agent messages (PostToolUse)
│   ├── roadmap-sync-check.sh  # Async: nudges when a branch changed code but not docs/ROADMAP.md (PostToolUse)
│   ├── on-dm.sh               # Daemon hook: incoming DM → state file + notify
│   ├── on-group-message.sh    # Daemon hook: incoming group msg → state file + notify
│   ├── dep-map.json           # Cross-repo dependency graph config
│   └── notify.sh              # Cross-platform notification utility (sourced by hooks)
├── skills/                    # Custom slash commands for parallel agent workflows
│   ├── breakdown/             # /breakdown — split phase doc into parallel work streams
│   ├── worker/                # /worker — generate prompt for parallel worker agent
│   ├── agent-review/          # /agent-review — review completed agent work
│   ├── steelman/              # /steelman — adversarial code review
│   ├── task-status/           # /task-status — check progress across tasks/worktrees
│   ├── push-pr/               # /push-pr — push branch and create GitHub PR
│   ├── update-issue/          # /update-issue — post progress update on GitHub issue
│   ├── sync-remote/           # /sync-remote — fetch and merge remote updates
│   ├── roadmap-sync/          # /roadmap-sync — reconcile docs/ROADMAP.md ⇄ GitHub Project board
│   ├── update-deps/           # /update-deps — update upstream deps, adapt code, build, test
│   ├── check-messages/        # /check-messages — read and display agent messages
│   ├── dm-owner/              # /dm-owner — send DM to configured owner
│   ├── dm-agent/              # /dm-agent — DM another agent (first-contact handshake)
│   ├── list-agents/           # /list-agents — show the authorized-agents registry
│   ├── authorize-agent/       # /authorize-agent — grant a remote agent capabilities
│   ├── deny-agent/            # /deny-agent — deny a remote agent
│   ├── process-agent-requests/ # /process-agent-requests — dispatch to capability-scoped processors
│   ├── team-form/            # /team-form — found a goal-scoped team + invite peers (Contract-Net)
│   ├── team-work/            # /team-work — run the team loop (auction/award/bid/execute/review)
│   ├── team-status/          # /team-status — render team ledgers, lease/epoch, knowledge cards
│   ├── team-publish/         # /team-publish — distill + broadcast a knowledge card
│   └── team-dissolve/        # /team-dissolve — retire a team with a retrospective
├── agent/                     # Agent identity, config, and authorized-agents registry (gitignored)
├── templates/                 # Seed files setup.sh copies into targets (ROADMAP.md skeleton, roadmap memory record)
├── reference/                 # Per-repository API reference docs (loaded on demand)
└── docs/                      # Architecture docs, guides, design decisions
```

## Key Hooks Behavior

The hooks auto-detect project type and enforce quality gates:

- **Edit/Write on main** → blocked; must create a feature branch first
- **Grep (native tool) on code** → blocked; redirected to Serena's semantic tools (`find_symbol`, `find_referencing_symbols`, `search_for_pattern`, …). Grep passes through only for non-code text — a non-code glob (`*.md`, `*.json`), a non-code `type`, or a non-code path (`docs/`, `*.log`, `package.json`). Auto-disabled when Docker/Serena is unavailable; bypass with `CLAUDE_PREFER_SERENA=0`
- **git commit** → auto-detects language:
  - Rust: blocks if `cargo fmt --all --check` or `cargo clippy` fail
  - TypeScript: blocks if `npm run lint` or `npm run typecheck` fail
  - Go: blocks if `go vet` or `gofmt` report issues
- **Stop** → auto-detects and blocks if build errors exist; also blocks if remote has unmerged updates, upstream dependency updates are pending, the roadmap is out of sync (code changed without a `docs/ROADMAP.md` update), or unread priority agent messages exist
- **ExitPlanMode** → blocked once to force steelman self-critique (5 adversarial questions), then allowed on second call
- **PostToolUse (async)** → after Bash calls, runs `git fetch` with 5-minute cooldown to detect remote updates; writes state file and sends desktop notification if behind
- **PostToolUse (async)** → after Bash calls, checks upstream npm/git deps with 15-minute cooldown; writes state file and sends desktop notification if newer versions available
- **PostToolUse (async)** → after Bash calls, polls Nostr relays for agent messages with 10-minute cooldown (fallback if sphere-sdk daemon not running)
- **PostToolUse (async)** → after Bash calls (i.e. once a `git commit` moves HEAD), if the current **feature branch** changed code/feature files but not `docs/ROADMAP.md`, writes a state file and notifies; dedup keyed on HEAD sha. No-op on `main`/`master`, doc-only or trivial commits, or when `gh` is unavailable

## Roadmap ⇄ Project Board Sync Pipeline

Every project provisioned by `setup.sh` gets a roadmap that is kept in lockstep
with its GitHub Project board. **`docs/ROADMAP.md` and the Project board MUST
always stay in sync** — they are two views of the same plan.

- **Four-state model:** ✅ Completed · 🚧 In progress · ⏸️ Stalled/paused · 🔵 Planned. The emoji on each roadmap line maps to the card's board `Status`.
- **`/roadmap-sync`** (`skills/roadmap-sync/`) reconciles both directions, idempotently (cards matched to lines by title, so no duplicates). It creates `docs/ROADMAP.md` from the four-state skeleton if absent, and creates the board via `gh project create` if none exists — surfacing `gh auth refresh -s project` when the token lacks the `project` scope rather than faking success.
- **`roadmap-sync-check.sh`** (PostToolUse) detects drift after a commit and nudges; **`check-diagnostics.sh`** escalates a pending state into a Stop-nudge (same soft→Stop pattern as remote-sync / dep-update). Escape hatch: `rm -f /tmp/claude/*/roadmap-sync.json`.
- **On install**, `setup.sh` (Phase 9) seeds `docs/ROADMAP.md` from `claude_conf/templates/ROADMAP.md` (if the target lacks one) and writes a per-project memory record from `claude_conf/templates/roadmap-memory.md` into the resolved `~/.claude/projects/<slug>/memory/` dir (index line appended to `MEMORY.md`), both guarded against clobbering existing files.

## Skills Workflow

The skills support a parallel agent development workflow:
1. `/breakdown docs/ecosystem-map.md` — plan parallel work streams
2. `/worker tasks/STREAM_X.md` — generate a focused prompt for a parallel Claude session
3. Workers execute in separate git worktrees
4. `/agent-review stream-x` — review completed work against task file
5. `/steelman` — adversarial review before merge
6. `/task-status` — check overall progress
7. `/check-messages` — read agent messages (group + DMs)
8. `/dm-owner <message>` — send a DM to the configured owner

### Cross-Host Agent Coordination

Agents on other hosts coordinate under an owner-in-the-loop, **default-deny** model:
unknown agents are queued for your authorization and never acted upon; authorized agents'
requests are dispatched to subagents scoped to their granted capabilities. **Whether a
given instance is the coordinator or an ordinary participant comes from its own
`.claude/agent/config.json`** (`agent_nametag`, plus the recorded coordinator) — never
assume the hub role from this document. Owner commands: `/list-agents`,
`/authorize-agent <name-or-npub> <caps>`, `/deny-agent <name-or-npub>`,
`/dm-agent <name-or-npub> <message>`, `/process-agent-requests`. Full model:
[`docs/agent-coordination.md`](docs/agent-coordination.md).

**Self-organizing teams (Contract-Net over A2A).** Authorized peers can form goal-scoped
teams that decompose work, auction tasks (cfp → bid → award-under-lease → result → review),
and share knowledge — all as capability-gated A2A verbs on the same default-deny substrate.
Three new non-destructive capabilities gate participation: `team-coordinate`, `task-bid`,
`knowledge-share`. Commands: `/team-form <goal> <member-npubs…>`, `/team-work [teamId]`,
`/team-status [teamId]`, `/team-publish [teamId] <fact>`, `/team-dissolve <teamId>`.
Opt-in and inert-safe (no local team ⇒ only invitations surface); requires the Sphere
daemon for live delivery. Full model: [`docs/team-coordination.md`](docs/team-coordination.md).

## Scheduled Automation

Three optional autonomous features layer on the existing coordination/recall/roadmap
machinery. **All three are OFF by default** — `setup.sh` (Phase 11) seeds the config and
installs the scheduler plumbing but enables nothing. Full design:
[`docs/nightly-sweep-lifecycle-design.md`](docs/nightly-sweep-lifecycle-design.md).

| Feature | Purpose | Trigger |
|---|---|---|
| **Syncup** (`syncup`) | Early-morning coordinator peer-sync: drain inbound peer traffic, process consults + capability-scoped requests, emit our own deterministic `sync.report`, DM the owner a digest. Widens no permission. | Scheduled, **07:00 local** (coordinator role only) |
| **Task-lifecycle** (`lifecycle`) | On task start: recall prior work + find/create the ticket; on task complete: update ticket/board/roadmap. | **Event-driven** — `UserPromptSubmit` + `PostToolUse` + Stop gate #15 (not scheduled) |
| **Nightly housekeeping** (`housekeeping`) | 3 AM sweep in a disposable git worktree off `main`: refactor recent work to named defects, add + run tests, `/steelman`, loop until green. | Scheduled, **03:00 local** |

**Config surface** — all in `.claude/agent/config.json`, never `settings.json` env (deep-merged, so setup re-runs preserve your tuning):

- Top-level `"role": "coordinator" | "peer"` — gates outbound syncup traffic (a `peer` never emits). Set by the `setup.sh` prompt / `SETUP_ROLE`.
- `"automation": { "syncup": {…}, "lifecycle": {…}, "housekeeping": {…} }` — each block carries `enabled:false` plus its knobs (`time`, `max_wall_minutes`, `max_turns`, `retry_once` for syncup; `ticket_mode`, `max_new_tickets_per_day` for lifecycle; `scope_days`, `max_items`, `max_prs`, `max_diff_lines`, `max_iterations`, `web_research`, `allow_new_deps`, `output:"pr"` for housekeeping).

**Enable one feature (safely):**

- **Scheduled jobs** (`syncup`, `housekeeping`): set `.automation.<job>.enabled=true`, then register the timer with `bash .claude/hooks/automation/scheduler.sh install <job>`. The scheduler picks a backend by platform probe (systemd user timers → `schtasks` → cron) and runs an **install-time preflight** (claude auth, `gh auth`, `jq`, Linux `enable-linger`) with exact remediation — it does not fail silently at 3 AM. Observe with `scheduler.sh status [<job>]`.
- **Task-lifecycle** is event-driven — no scheduler entry. Just set `.automation.lifecycle.enabled=true`; the `task-lifecycle-check.sh` hook (already wired into `settings.json`) activates.

**Output model (housekeeping):** every sweep produces a **PR** on `sweep/<date>` + a `/steelman` verdict in the PR body + a short **morning-review report** (dated file, PR-body prepend, and a SessionStart digest). It **never auto-merges** — you accept by merging the PR. The wrapper (not the model) pushes, and only to `sweep/*`; the diff is secret-scanned pre-push.

**Kill switches:**

- `AUTOMATION_DISABLE=1` (env) — `run-job.sh` disables **every** scheduled job at the runner without touching timers.
- Per-job `.automation.<job>.enabled=false` — turns off that one job (the runner and the lifecycle hook both gate on it).
- `TASK_LIFECYCLE_DISABLE=1` (env) — turns off the task-lifecycle hook entirely.
- A stuck run: `rm -f /tmp/claude/*/automation/<job>.lock` (flock, so process death already releases it).

## Editing Configuration

When modifying `claude_conf/`:
- `settings.json` controls hooks (which tools trigger which scripts), team agents mode, and environment
- `settings.local.json` controls permissions (allowed bash commands, web domains, MCP tools) and sandbox settings
- Hook scripts must output JSON with `{"decision": "block", "reason": "..."}` to block, or exit 0 to allow
- Reference docs follow the template in `reference/TEMPLATE.md` — one file per repository, scoped to API surface
- The main `CLAUDE.md` is the primary context document loaded by every Claude session in Unicity projects

## Unicity Ecosystem

The configuration targets 8 repositories across 4 languages:

| Repository | Language | Layer |
|---|---|---|
| sphere | TypeScript (React 19) | L5 Wallet |
| sphere-sdk | TypeScript | L4-L5 SDK |
| state-transition-sdk | TypeScript | L4 State |
| openclaw-unicity | TypeScript | L5 Agent |
| unicity-orchestrator | TypeScript | L5 MCP |
| aggregator-go | Go | L3 Aggregation |
| bft-core | Go | L2 Consensus |
| alpha | C++ | L1 PoW |

Commit messages follow Conventional Commits: `<type>(<scope>): <description>` where scope is the repository or module name.
