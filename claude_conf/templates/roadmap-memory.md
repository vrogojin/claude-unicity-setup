---
name: roadmap-board-sync
description: This project keeps docs/ROADMAP.md and its GitHub Project board auto-synced (four-state model); run /roadmap-sync to reconcile.
metadata:
  node_type: memory
  type: project
---

This project ships with a **roadmap ⇄ project-board sync pipeline** (installed by
`claude-unicity-setup`). `docs/ROADMAP.md` and the repo's **GitHub Project board**
are two views of the same plan and MUST always stay in sync.

**Four-state model** (emoji in ROADMAP.md ↔ board status column):

- ✅ Completed — shipped / merged / done
- 🚧 In progress — actively being worked on now
- ⏸️ Stalled / paused — started but on hold (blocked / deprioritized / awaiting input)
- 🔵 Planned — agreed, not yet started

**How it works:**

- **`/roadmap-sync`** — reconciles both directions. Detects the board via
  `gh project list` and the `docs/ROADMAP.md` file; creates either if absent
  (ROADMAP.md from a four-state skeleton, the board via `gh project create`).
  Idempotent — it matches cards to lines by title, so re-running never duplicates.
  If `gh` lacks the `project` scope it stops and tells you to run
  `gh auth refresh -s project` — it never fakes success.
- **`roadmap-sync-check.sh`** (PostToolUse Bash hook) — after a commit lands on a
  feature branch, if code/feature files changed but `docs/ROADMAP.md` was NOT
  touched, it writes a state file and nudges. `check-diagnostics.sh` turns that
  into a Stop-nudge (like remote-sync / dep-update): finish by running
  `/roadmap-sync`. Escape hatch: `rm -f /tmp/claude/*/roadmap-sync.json`.

**The rule:** whenever you complete, start, pause, or plan a piece of work, reflect
it in BOTH `docs/ROADMAP.md` and the board — or just run `/roadmap-sync` and let it
reconcile. Never let the two drift.
