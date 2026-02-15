# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

This is the Claude Code configuration repository for the **Unicity Network** ecosystem — a multi-language, multi-repository development environment covering TypeScript SDKs, Go infrastructure, Rust tooling, and C++ consensus layer. The `claude_conf/` directory contains the full `.claude/` configuration that gets deployed to any Unicity workspace.

## Repository Structure

```
claude_conf/
├── CLAUDE.md                  # Main CLAUDE.md for Unicity projects
├── settings.json              # Hooks config (PreToolUse, Stop), team agents mode
├── settings.local.json        # Permissions, sandbox config, MCP servers
├── hooks/                     # Shell hooks enforcing workflow
│   ├── branch-guard.sh        # Blocks Edit/Write on main/master
│   ├── pre-commit-check.sh    # Auto-detect: blocks git commit if lint/format fail
│   ├── check-diagnostics.sh   # Auto-detect: blocks stop if build has errors or remote updates pending
│   ├── steelman-plan.sh       # Forces adversarial self-critique before ExitPlanMode
│   ├── remote-sync-check.sh   # Async: detects remote branch updates (PostToolUse)
│   └── notify.sh              # Cross-platform notification utility (sourced by hooks)
├── skills/                    # Custom slash commands for parallel agent workflows
│   ├── breakdown/             # /breakdown — split phase doc into parallel work streams
│   ├── worker/                # /worker — generate prompt for parallel worker agent
│   ├── agent-review/          # /agent-review — review completed agent work
│   ├── steelman/              # /steelman — adversarial code review
│   ├── task-status/           # /task-status — check progress across tasks/worktrees
│   ├── push-pr/               # /push-pr — push branch and create GitHub PR
│   ├── update-issue/          # /update-issue — post progress update on GitHub issue
│   └── sync-remote/           # /sync-remote — fetch and merge remote updates
├── reference/                 # Per-repository API reference docs (loaded on demand)
└── docs/                      # Architecture docs, guides, design decisions
```

## Key Hooks Behavior

The hooks auto-detect project type and enforce quality gates:

- **Edit/Write on main** → blocked; must create a feature branch first
- **git commit** → auto-detects language:
  - Rust: blocks if `cargo fmt --all --check` or `cargo clippy` fail
  - TypeScript: blocks if `npm run lint` or `npm run typecheck` fail
  - Go: blocks if `go vet` or `gofmt` report issues
- **Stop** → auto-detects and blocks if build errors exist; also blocks if remote has unmerged updates
- **ExitPlanMode** → blocked once to force steelman self-critique (5 adversarial questions), then allowed on second call
- **PostToolUse (async)** → after Bash calls, runs `git fetch` with 5-minute cooldown to detect remote updates; writes state file and sends desktop notification if behind

## Skills Workflow

The skills support a parallel agent development workflow:
1. `/breakdown docs/ecosystem-map.md` — plan parallel work streams
2. `/worker tasks/STREAM_X.md` — generate a focused prompt for a parallel Claude session
3. Workers execute in separate git worktrees
4. `/agent-review stream-x` — review completed work against task file
5. `/steelman` — adversarial review before merge
6. `/task-status` — check overall progress

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
