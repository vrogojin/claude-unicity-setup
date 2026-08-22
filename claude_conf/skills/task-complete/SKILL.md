---
name: task-complete
description: On finishing a task — update its ticket, move the project-board card, and reconcile docs/ROADMAP.md. Delegates to /update-issue, ticketer.sh, and /roadmap-sync. Invoked from /push-pr's final step or the Stop gate #15 nudge; idempotent.
argument-hint: [issue number or PR number]
---

# /task-complete — Close Out a Task

The completion half of F2 (design §4.3). A task the human started has shipped (a PR
exists, or the bound branch merged) and its ticket/board/roadmap trail needs closing.
You are invoked either from `/push-pr`'s final step or by **Stop gate #15**. This is
pure orchestration of existing tools — it writes no ticket text of its own beyond a
progress comment, and it is idempotent.

## Locate the task

```bash
STATE_DIR="$( . "$CLAUDE_PROJECT_DIR/.claude/hooks/state-dir.sh" 2>/dev/null && printf '%s' "$STATE_DIR" )"
TL="$STATE_DIR/task-lifecycle.json"
TICKETER="$CLAUDE_PROJECT_DIR/.claude/hooks/ticketer.sh"
```

The relevant record is a `status:"open"` or `"ticketed"` task in `$TL` whose `pr` is
set (the hook stamped it when it detected the PR). Read its `task_id`, `branch`,
`ticket`, and `pr`. If `$ARGUMENTS` names an issue/PR number, prefer that.

If the task has **no ticket yet** (`ticket == null`), first run the ticket pass from
`/task-start` step 4 (find, then create-or-propose) so there is something to close —
then continue.

## Step 1 — Update the ticket

Post a completion progress comment linking the PR, via the existing skill:

```
/update-issue <ticket-number> Task complete — shipped in PR #<pr>. <one-line summary>
```

`/update-issue` pushes the branch and posts a structured comment. If the PR has
**merged**, also close the issue:

```bash
gh issue close <ticket-number> --reason completed 2>/dev/null || true
```

(If the PR is still open, leave the issue open — closing happens when it merges.)

## Step 2 — Move the board card

Via the ticketer board op (best-effort — a board miss never fails completion):

```bash
# merged → Done ; still open for review → In progress ; paused/abandoned → Paused
bash "$TICKETER" board <ticket-number> --status "Done"
```

## Step 3 — Reconcile the roadmap (delegate)

Delegate to the single roadmap⇄board writer — do NOT hand-edit `docs/ROADMAP.md`:

```
/roadmap-sync
```

This is deliberate: `/roadmap-sync` clears its **own** Stop gate (#6) as well, so one
run settles both the roadmap gate and this task's gate — no deadlock, since gate #15
is ordered after gate #6.

## Step 4 — Mark the record complete

```bash
jq -c --arg id "<task_id>" --arg now "$(date -u +%FT%TZ)" \
  '.tasks |= map(if .task_id==$id then .status="complete" | .completed_at=$now else . end)' \
  "$TL" > "$TL.tmp" && mv "$TL.tmp" "$TL"
```

Marking the record `complete` clears gate #15 (it only counts `open`/`ticketed`
tasks with a PR). Terminal records reap themselves after 14 days.

## Guardrails

- **Idempotent:** every step is safe to re-run — `/update-issue` posts an additive
  comment, `board` is a set-to-value, `/roadmap-sync` is a reconcile, and the record
  flip is a no-op once `complete`.
- **Don't fabricate status:** report only what actually shipped (the PR, the merge).
  If tests were skipped or work was partial, say so in the comment.
- **Paused, not done:** if the task was abandoned rather than finished, set the board
  to `Paused` and mark the record `complete` with a note — never leave a shipped task
  wedging the gate.
