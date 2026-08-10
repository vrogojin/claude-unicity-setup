---
name: team-dissolve
description: Retire a team when its goal is met or abandoned — publish a retrospective knowledge-card set the members keep, mark the team dissolved, and notify members.
---

# /team-dissolve — Retire a Team

Ends a team cleanly: publish a **retrospective** (what worked, gotchas — the "lifelong
team learning" members keep after the team is gone), mark the team `dissolved`, and notify
members. See `docs/team-coordination.md`.

## Usage

```
/team-dissolve <teamId>
```

Let `TC="$CLAUDE_PROJECT_DIR/.claude/hooks/team-coord.sh"`.

## Instructions

1. **Confirm** with the admin that the goal is complete (or the team is being abandoned).
   Show the final ledger first: `bash "$TC" render <teamId>` then
   `cat "$(bash "$TC" root)/<teamId>/ledger.md"`.

2. **Publish a retrospective** (optional but recommended). Distill 1–3 durable lessons and
   share each as a knowledge card so members retain them after dissolution:
   ```
   /team-publish <teamId> <lesson — what worked / what to avoid next time>
   ```

3. **Mark the team dissolved** and notify members:
   ```bash
   bash "$TC" dissolve <teamId>
   bash "$TC" emit <teamId> "$(bash "$TC" envelope <teamId> team.snapshot \
      --payload "$(jq -nc '{status:"dissolved", note:"team goal complete — thank you"}')")"
   ```

4. **Report** that the team is retired. The team store (ledgers + knowledge cards) is left
   in place under `<memory>/team/<teamId>/` as a durable record; it no longer accepts
   coordination (its status is `dissolved`). To purge it entirely, the admin can remove
   that directory.

## Safety

- Dissolving does not revoke any capability grants — if you no longer want a former member
  to coordinate at all, run `/deny-agent <npub>` (or re-`/authorize-agent` with a narrower
  set). Dissolution only stops this team's protocol.
