---
name: roadmap-sync
description: Reconcile docs/ROADMAP.md with the repo's GitHub Project board (four-state model). Creates either if absent; idempotent both-direction sync. Use when the roadmap-sync hook blocks Stop, or after landing/pausing/planning work.
argument-hint: "[--dry-run]"
---

# Roadmap ⇄ Project Board Sync

Reconcile this project's **`docs/ROADMAP.md`** with its **GitHub Project board** so
the two never drift. The roadmap is the human-readable mirror of the board; every
roadmap line maps to one card, and the emoji encodes the card's status.

**Four-state model** (roadmap emoji ↔ board `Status` field):

| Emoji | Board status | Meaning |
|-------|--------------|---------|
| ✅ | Completed / Done | Shipped, merged, done. |
| 🚧 | In Progress | Actively being worked on now. |
| ⏸️ | Stalled / Paused | Started but on hold (blocked / deprioritized / awaiting input). |
| 🔵 | Planned / Todo | Agreed, not yet started. |

`--dry-run` (optional): report the diff you *would* apply, change nothing.

---

## Process

### 1. Gather state (run in parallel)

```bash
# Per-repo state dir (hook state files are namespaced per repo).
STATE_DIR="$( . "$CLAUDE_PROJECT_DIR/.claude/hooks/state-dir.sh" 2>/dev/null && printf '%s' "$STATE_DIR" )"
STATE_DIR="${STATE_DIR:-/tmp/claude}"

cat docs/ROADMAP.md 2>/dev/null || echo "__NO_ROADMAP__"
gh auth status 2>&1 | head -3
gh project list --owner "@me" --format json 2>&1 | head -c 2000
gh repo view --json name,owner,url 2>/dev/null
```

### 2. Ensure `gh` can reach Projects

GitHub Projects (v2) need the **`project`** OAuth scope. If any `gh project`
command returns an error mentioning the scope (e.g. `error: your token has not
been granted the required scopes ... 'project'` or `'read:project'`), STOP and
tell the user to grant it — never fake a result:

```bash
gh auth refresh -s project
```

Re-run step 1 after they refresh. Do not proceed to board writes until
`gh project list` succeeds.

### 3. Ensure `docs/ROADMAP.md` exists

If step 1 printed `__NO_ROADMAP__`, create it from the skeleton and report that you
did. Prefer the shipped template; fall back to an inline skeleton:

```bash
mkdir -p docs
if [ -f .claude/templates/ROADMAP.md ]; then
  cp .claude/templates/ROADMAP.md docs/ROADMAP.md
else
  cat > docs/ROADMAP.md <<'EOF'
# Roadmap

Status legend: ✅ Completed · 🚧 In progress · ⏸️ Stalled/paused · 🔵 Planned.
Keep one item per line: `- <emoji> **<title>** — <description>`.

## ✅ Completed

## 🚧 In progress

## ⏸️ Stalled / paused

## 🔵 Planned
EOF
fi
```

### 4. Ensure a board exists

From step 1, decide whether this repo already has a Project board. Match by a
title tied to the repo (e.g. the repo name, or an existing board the user points
you at). If none exists, create one and note the URL:

```bash
REPO_NAME="$(gh repo view --json name -q .name)"
gh project create --owner "@me" --title "$REPO_NAME Roadmap" --format json
```

- For an **organization** board use `--owner <org>` instead of `@me`; if that
  fails on scope, surface the `gh auth refresh -s project` instruction from step 2
  (org projects may also need admin approval — say so rather than looping).
- A freshly created board has a default `Status` single-select field with options
  `Todo / In Progress / Done`. Add the missing states so all four map cleanly —
  add a **Planned**, **Stalled** option (or reuse `Todo`→Planned, `Done`→Completed)
  and record the mapping you chose in your report. Use `gh project field-list` /
  `gh project field-create` as needed. If the GitHub CLI version can't edit
  single-select options, map onto the existing options and note the limitation.

### 5. Read both sides

- **Roadmap → items:** parse `docs/ROADMAP.md` into `(status, title)` pairs. A
  line `- <emoji> **Title** — desc` yields the title and its status from the emoji
  (or from the section header it sits under). Ignore comment/placeholder lines.
- **Board → cards:** `gh project item-list <number> --owner <owner> --format json`
  → each card's title + `Status`.

Match roadmap lines to cards **by title** (case-insensitive, trimmed). This
title-keyed matching is what makes the sync **idempotent** — re-running never
creates a duplicate card for a title that already has one.

### 6. Reconcile both directions

Build the union of titles and, for each, apply the minimal change. With
`--dry-run`, only *print* the planned action.

- **On roadmap, not on board** → create a draft card and set its status:
  ```bash
  gh project item-create <number> --owner <owner> --title "<title>" --format json
  # then set its Status field via: gh project item-edit --id <item-id> \
  #   --field-id <status-field-id> --project-id <project-id> \
  #   --single-select-option-id <option-id-for-that-status>
  ```
- **On board, not on roadmap** → add a line to the matching `##` section of
  `docs/ROADMAP.md` (status from the card's `Status`).
- **Both, status differs** → treat the side the user just edited as source of
  truth. Default: if this run was triggered by the Stop hook after a code commit,
  the human intent is usually captured in the roadmap edit the user is about to
  make — so prefer the **roadmap** as authoritative for status, and update the
  **board** to match. State which direction you took, per item.
- **Both, status matches** → no-op.

Keep roadmap items under the correct `##` section (move the line if its emoji
changed). Never delete a card or a roadmap line automatically — if one side has an
item the other lacks and it looks intentionally removed, flag it for the user
instead of deleting.

### 7. Clear the Stop-gate state

If not `--dry-run`, clear the hook's state file so `check-diagnostics.sh` stops
blocking:

```bash
rm -f "$STATE_DIR/roadmap-sync.json" "$STATE_DIR/roadmap-sync-notified"
```

### 8. Report

Print a concise summary:

```
Roadmap ⇄ board sync:
- Board: <title> (#<number>) <url>   [created | existing]
- ROADMAP.md: <created | updated | unchanged>
- Cards created:   N  (titles)
- Roadmap lines added: N  (titles)
- Status changes: N  (title: old → new, direction)
- Flagged for review: N  (title — reason)
- Scope: OK  (or: needs `gh auth refresh -s project`)
```

If you created ROADMAP.md or the board from scratch, say so explicitly and remind
the user to fill in real items (the skeleton ships with a single placeholder).
