---
name: task-start
description: On starting a real task — judge whether it's actually a task, recall prior work, and if prior art exists build ON TOP of it rather than replicate, then find or open its tracking ticket. Invoked by the task-lifecycle hook's nudge; advisory and idempotent.
argument-hint: [keywords or task description]
---

# /task-start — Open a Task Cleanly

The `task-lifecycle-check.sh` UserPromptSubmit hook opened a task record for this
prompt and nudged you here. This skill is the **reasoning** half of F2 (design §4.3):
the hook already classified/tracked deterministically; here you judge, recall, and
decide whether a ticket is warranted. Everything below is idempotent — running it
twice for the same task changes nothing the second time.

**This is not a gate.** If the prompt turns out to be a question or a trivial tweak,
you DISMISS the record and move on. The point is to avoid silently re-implementing
something that already exists, and to leave a ticket trail for real work.

## Where the task record lives

```bash
STATE_DIR="$( . "$CLAUDE_PROJECT_DIR/.claude/hooks/state-dir.sh" 2>/dev/null && printf '%s' "$STATE_DIR" )"
TL="$STATE_DIR/task-lifecycle.json"
TICKETER="$CLAUDE_PROJECT_DIR/.claude/hooks/ticketer.sh"
```

The record for the current prompt is the most recent `status:"open"` task in
`$TL` (fields: `task_id`, `title_guess`, `keywords`, `branch`, `ticket`).

## Step 1 — Triviality judge (the second filter)

The hook's classifier is deterministic and dumb; you are the second filter. Read the
actual prompt. If it is a **question**, a **one-line tweak**, a **revert**, a pure
**config change**, or otherwise not real feature/fix work, mark the record
`dismissed` and STOP (a dismissed record suppresses re-nudging on those keywords for
24 h):

```bash
jq -c --arg id "<task_id>" --arg now "$(date -u +%FT%TZ)" \
  '.tasks |= map(if .task_id==$id then .status="dismissed" | .completed_at=$now else . end)' \
  "$TL" > "$TL.tmp" && mv "$TL.tmp" "$TL"
```

Only continue if this is genuinely a task worth tracking.

## Step 2 — Recall prior work (the deep pass)

Run the existing deep recall skill with the record's keywords — do NOT re-implement
its search here:

```
/recall-prior-work <keywords from the task record>
```

Wait for its verdict: **done before / partially done / no trace**, with refs
(closed/merged PRs + issues, memory cards, ROADMAP lines, typed edges).

## Step 3 — If prior art exists: DELTA, then build ON TOP

If recall found prior work, do **not** start from scratch and do **not** duplicate it.
State the **delta explicitly** — what THIS request adds over what already exists — and
instruct the implementation to build on top of the named prior artifact (the file,
branch, or PR recall surfaced). Then record a typed edge so the next recall is a pure
lookup (valid relations only — the store rejects anything else):

```bash
# build-on-top / replacement  → supersedes ;  near-identical work → duplicates
bash "$CLAUDE_PROJECT_DIR/.claude/hooks/remote-coord.sh" edge-add \
  "<this task: a keyword or title>" supersedes "<prior PR/issue/feature ref>" \
  "task-start: extends prior work with <the delta>"
```

(The relation MUST be one of `duplicates|supersedes|blocks|conflicts-with` —
`extends` is not a stored relation; use `supersedes` for build-on-top.)

If recall found **no trace**, proceed as genuinely new work — no edge needed yet.

## Step 4 — Ticket pass (find, else propose/create per OD-5)

The `ticketer.sh` layer is the ONE place that touches GitHub for tickets — it owns
marker-dedup, the `agent:auto` label, and the shared daily cap. Never call `gh issue
create` yourself.

**Find first** (marker, then keywords):

```bash
bash "$TICKETER" find --task-id "<task_id>"
bash "$TICKETER" find --keywords "<space-separated keywords>"
```

- **Found** → this task already has a ticket. Comment that work is starting and set
  the board to in-progress, then record the number:

  ```bash
  bash "$TICKETER" comment <n> --body "Work starting — branch TBD (task-start)."
  bash "$TICKETER" board <n> --status "In progress"   # best-effort; a board miss is fine
  ```

- **Not found** → decide by `ticket_mode` (OD-5), read from config:

  ```bash
  MODE="$(jq -r '.automation.lifecycle.ticket_mode // "propose"' "$CLAUDE_PROJECT_DIR/.claude/agent/config.json")"
  ```

  - **`propose` (interactive default):** DRAFT the ticket (title + body) in your reply
    and ask the owner for a go-ahead. Create only on an explicit yes. Do NOT auto-create
    in an interactive session.
  - **`auto`, OR a scheduled run (`$AUTOMATION_JOB` is set — there is nobody to ask):**
    create it, capped and labeled:

    ```bash
    printf '%s\n' "<body: what/why, acceptance, links>" > /tmp/tk-body.$$
    bash "$TICKETER" create --title "<concise task title>" \
         --body-file /tmp/tk-body.$$ --task-id "<task_id>"; rc=$?
    rm -f /tmp/tk-body.$$
    ```

    Exit code **3** means the shared daily cap is reached — do NOT retry or open the
    issue another way. Fall back to a SINGLE digest line to the owner ("N tasks need
    tickets today; cap reached") and leave the record un-ticketed.

## Step 5 — Update the record

Stamp the ticket number and move the record to `ticketed` (leave it `open` if you only
proposed and haven't created yet):

```bash
jq -c --arg id "<task_id>" --argjson n <issue-number> \
  '.tasks |= map(if .task_id==$id then .status="ticketed" | .ticket=$n else . end)' \
  "$TL" > "$TL.tmp" && mv "$TL.tmp" "$TL"
```

## Guardrails

- **Idempotent:** `ticketer.sh create` dedups on the marker, so a re-run comments
  instead of opening a second issue. Never open a duplicate.
- **Respect the cap:** exit 3 from `create` is final for the day — digest, don't
  work around it.
- **Propose in interactive sessions:** never auto-create a ticket when a human is
  present unless `ticket_mode:"auto"`. The `agent:auto` label exists so the owner can
  review or mass-close anything the automation opened.
- **Board is best-effort:** a `board` non-zero exit (no project / no matching status)
  is not a failure — note "board not updated" and continue.
