# a2a-session-arm — in-session, event-driven A2A auto-processing

`a2a-session-arm.sh` + `a2a-queue-watch.sh` make every installed agent **act on** the
authorized A2A queues — both the 1:1 DM/work-item queue **and** the coordination/consult
queue — instead of only receiving them. They slot in beside the pieces the framework
already ships:

| Stage | Mechanism | Before this change |
|-------|-----------|--------------------|
| RECEIVE | `daemon-session.sh` (SessionStart) → live relay subscription | automatic |
| CLASSIFY + QUEUE (DEFAULT-DENY) | `classify-inbound.sh` → `agent-workitems/` (DMs), `agent-consult-events/` (consults), `agent-team-events/` (team) | automatic |
| Stop-gate (block idle while `queued`) | `check-diagnostics.sh` — work-items → `/process-agent-requests`; consult/team events + open consults → `/coordinator-advise` | automatic (gates BOTH queues) |
| **In-session, event-driven drain / wake** | **`a2a-session-arm.sh` + `a2a-queue-watch.sh` (this change)** | **was the gap** |

The gap this closes: a hook cannot spawn the capability-scoped processor subagent (only the
model can, via the skills), so a busy session left queued peer requests — including the
**consult** queue, which is serviced by `/coordinator-advise`, not `/process-agent-requests`
— untouched until it tried to Stop.

## Two levers, both zero idle cost

- **Drain-once (SessionStart):** if anything is queued when a session starts, the hook
  injects an `additionalContext` nudge to run `/process-agent-requests` (DMs) **and**
  `/coordinator-advise` (consults) + `/team-work` (team) now. Silent when nothing is queued.
- **Event-driven watcher:** the hook nudges the session to arm a **persistent Monitor** over
  `a2a-queue-watch.sh`, which emits a line **only when a NEW authorized item appears** in any
  of the three queues — so the session is woken to dispatch **only on real arrivals**. This is
  deliberately NOT an unconditional `/loop <interval> /skill` that runs a skill every N
  minutes regardless of queue state (that burns tokens and clutters the console while idle).
  A per-id `mkdir` claim wakes exactly ONE session per new item; a heartbeat keeps normally
  ONE watcher live per repo (a starting session re-arms only when it goes stale).

## Registration — automatic via setup.sh

This is wired into the framework's canonical registration: `claude_conf/settings.json`
carries the SessionStart entry, and `setup.sh` deploys it (`cp -r claude_conf/.` →
`.claude/`). So **every `setup.sh` run activates it** — no per-project hand-edit. The
SessionStart `startup|resume|clear|compact` block is:

```json
"hooks": [
  { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/daemon-session.sh start", "timeout": 20 },
  { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/serena-reaper.sh start",   "timeout": 20 },
  { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/a2a-session-arm.sh",        "timeout": 15 }
]
```

To pick it up in an existing install: pull the framework and re-run `./setup.sh` in the
target project.

## Flags (env)

| Var | Default | Meaning |
|-----|---------|---------|
| `A2A_SESSION_ARM_DISABLE` | `0` | `1` turns the SessionStart hook off entirely. |
| `A2A_SESSION_ARM_WATCH` | `1` | **watcher default-ON**; `0` = drain-once nudge only, do not arm the watcher. |
| `A2A_SESSION_ARM_WATCH_STALE` | `20` | Seconds before a watcher heartbeat is "stale" → a starting session re-arms. |
| `A2A_QUEUE_WATCH_INTERVAL` | `3` | `a2a-queue-watch.sh` poll seconds (cheap directory listings). |

## Safety (do not weaken)

Both scripts **only nudge / watch** — never dispatch, authorize, or widen scope. They read
queue **counts + ids + a heartbeat**, never message bodies, the registry's authz decisions, or
`.env`/`.secrets`/`identity.json`. DEFAULT-DENY is enforced upstream (only `authorized` peers
are ever enqueued); the capability-scoped processor in the skills is the sole executor and
refuses out-of-scope asks; `rebuild-reload-service` / `review-merge-pr` (and anything
destructive/outward) stay REQUEST-ONLY — propose to the owner, never auto-execute.

Test: `claude_conf/hooks/test/a2a-session-arm.test.sh` (node-free, hermetic).
