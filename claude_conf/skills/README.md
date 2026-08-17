# Unicity Development Skills

Custom slash commands for managing parallel agent workflows across the Unicity ecosystem.

## Available Skills

| Command | Purpose |
|---------|---------|
| `/agent-review <stream>` | Review completed agent work before merging |
| `/task-status` | Check progress across all tasks and worktrees |
| `/worker <task-file>` | Generate a prompt for a parallel worker agent |
| `/breakdown <phase-doc>` | Break a phase into parallel work streams |
| `/push-pr <description>` | Push branch and create a GitHub PR with structured template |
| `/update-issue <number> [message]` | Push branch and post progress update on a GitHub issue |
| `/steelman [branch]` | Adversarial review — try to break code before it ships |
| `/roadmap-sync [--dry-run]` | Reconcile `docs/ROADMAP.md` ⇄ the GitHub Project board (four-state model) |
| `/a2a <op> …` | **Turnkey A2A** — one exact command per op (issue/redeem/ingest/check/dm/consult/advise/verify/authorize/onboard); all resolution baked in. Umbrella over the coordination skills below |
| `/check-messages` | Read agent messages (owner DMs + `UNICITY_DEV_AGENTS` group) |
| `/dm-owner <message>` | Send a DM to the configured owner |
| `/dm-agent <name-or-npub> <message>` | DM another Claude agent (first-contact handshake) |
| `/list-agents [status]` | Show the authorized-agents registry |
| `/authorize-agent <name-or-npub> <caps>` | Authorize a remote agent + grant capabilities |
| `/deny-agent <name-or-npub>` | Deny a remote agent (its messages are dropped) |
| `/process-agent-requests` | Dispatch queued authorized requests to capability-scoped processors |
| `/team-form <goal> <member-npubs…>` | Found a goal-scoped team + invite peers (Contract-Net coordinator) |
| `/team-work [teamId]` | Run the team loop — auction/award/bid/execute/review; drains team events |
| `/team-status [teamId]` | Render team ledgers, coordinator lease/epoch, invitations, knowledge cards |
| `/team-publish [teamId] <fact>` | Distill + broadcast a knowledge card to the team |
| `/team-dissolve <teamId>` | Retire a team with a retrospective |

## Usage

### Starting a New Phase

```
/breakdown docs/ecosystem-map.md
```

Creates task files, dependency graph, and git worktree commands.

### Dispatching Workers

```
/worker tasks/2_STREAM_B_AGGREGATOR.md
```

Generates a focused prompt to paste into a new Claude session in the worktree.

### Checking Progress

```
/task-status
```

Shows completion status across all task files, worktrees, and packages.

### Reviewing Completed Work

```
/agent-review stream-b
```

Systematically reviews work against task file, runs verification, and prepares merge.

## Workflow

```
┌─────────────────────────────────────────────────────────────┐
│  1. /breakdown        Plan parallel streams                  │
│  2. /worker (×N)      Generate worker prompts                │
│  3. [Workers execute in parallel worktrees]                  │
│  4. /agent-review     Review each completed stream           │
│  5. /steelman         Adversarial review before merge        │
│  6. Merge approved work                                      │
│  7. /task-status      Check overall progress                 │
│  8. Repeat until phase complete                              │
└─────────────────────────────────────────────────────────────┘
```

## Review Categories

`/agent-review` checks these areas:

1. **Security** - Crypto, auth, injection, secrets
2. **Correctness** - Logic, edge cases, error handling
3. **Reliability** - Failure modes, timeouts, cleanup
4. **Performance** - Caching, allocations, async
5. **Concurrency** - Races, locks, async safety
6. **API/Ergonomics** - Consistency, builders, docs
7. **Observability** - Logging, events, debug
8. **Testing** - Coverage, edge cases
9. **Configuration** - Defaults, validation
10. **Future/Debt** - Stubs, TODOs

## Files

```
.claude/skills/
├── README.md              # This file
├── agent-review/
│   ├── SKILL.md           # /agent-review command
│   └── reference.md       # Coordinator guidelines
├── task-status/
│   └── SKILL.md           # /task-status command
├── worker/
│   └── SKILL.md           # /worker command
├── breakdown/
│   └── SKILL.md           # /breakdown command
├── push-pr/
│   └── SKILL.md           # /push-pr command
├── steelman/
│   └── SKILL.md           # /steelman command
├── update-issue/
│   └── SKILL.md           # /update-issue command
├── roadmap-sync/
│   └── SKILL.md           # /roadmap-sync command
├── check-messages/
│   └── SKILL.md           # /check-messages command
├── dm-owner/
│   └── SKILL.md           # /dm-owner command
├── dm-agent/
│   └── SKILL.md           # /dm-agent command — DM another agent (handshake)
├── list-agents/
│   └── SKILL.md           # /list-agents command
├── authorize-agent/
│   └── SKILL.md           # /authorize-agent command
├── deny-agent/
│   └── SKILL.md           # /deny-agent command
├── process-agent-requests/
│   └── SKILL.md           # /process-agent-requests — capability-scoped dispatch
├── team-form/            # /team-form — found a team + invite peers (Contract-Net)
├── team-work/            # /team-work — run the team loop (auction/award/bid/execute/review)
├── team-status/          # /team-status — render team ledgers + lease/epoch + knowledge
├── team-publish/         # /team-publish — distill + broadcast a knowledge card
└── team-dissolve/        # /team-dissolve — retire a team with a retrospective
```

## Agent Coordination Skills

The `dm-agent`, `list-agents`, `authorize-agent`, `deny-agent`, and
`process-agent-requests` skills implement the **owner-in-the-loop coordination** model
for coordinating Claude agents across hosts (default-deny authorization registry +
capability-scoped request processing). See [`docs/agent-coordination.md`](../../docs/agent-coordination.md).

## Tips

- Skills auto-complete when you type `/`
- Arguments are passed after the command: `/worker tasks/file.md`
- Review findings get appended to `tasks/TODO_POST_REVIEW.md`
- Worker prompts should be run in separate Claude sessions in worktrees
