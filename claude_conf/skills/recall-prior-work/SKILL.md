---
name: recall-prior-work
description: Before implementing/fixing/building something, check whether it was done before — search the memory store, git history, closed/merged PRs and issues, docs/ROADMAP.md, and the feature catalog, then report "you may have done this before" with refs. Advisory, never blocking.
---

# /recall-prior-work — "Did I Do This Before?"

We keep dropping and re-implementing features (the wave-batch-v2 hand-re-land silently
dropped working fixes; multiple backend/capsule DUPs live in the feature catalog). This
skill is the DEEP pass behind the fast `recall-prior-work.sh` UserPromptSubmit hook: it
sweeps every record we have of past work and answers **done before / partially done /
no trace**, with references — BEFORE new code gets written.

Advisory only: it informs the plan, it never blocks it.

## Usage

```
/recall-prior-work <feature or fix description / keywords>
```

## Instructions

Derive 3–6 **distinctive keywords** from the argument (nouns and domain terms, not
verbs; include obvious synonyms — e.g. "geocode" AND "address", "consent" AND
"grant"). Then search ALL of the following sources — run the independent searches in
parallel, time-box each, and tolerate absence (a missing source is skipped, not an
error):

0. **Prior-work edge graph FIRST** (Beads-style typed relations — "have I built
   this?" as a lookup, not a vibe): the coordination store's edge log holds
   `duplicates` / `supersedes` / `blocks` / `conflicts-with` edges between features,
   tasks, memory cards, and PR/issue refs:
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/hooks/remote-coord.sh" edges | jq '[.[] | select((.from+.to) | test("kw1|kw2"; "i"))]'
   ```
   A `duplicates`/`supersedes` hit is a near-certain verdict on its own. When your
   search below DISCOVERS such a relation, record it (`edge-add <from> <rel> <to>`)
   so the next query is a lookup. (If this graph outgrows JSONL, `bd`/Beads is a
   drop-in heavier option — git-synced, transactional; do not hard-depend on it.)

1. **Memory store** — the auto-memory dir for this project
   (`~/.claude/projects/<slug>/memory/`; for concierge:
   `/home/vrogojin/.claude/projects/-home-vrogojin-concierge/memory/`):
   ```bash
   grep -ilE 'kw1|kw2' <memory-dir>/*.md
   ```
   Read `MEMORY.md` index lines and the top-matching files — memory entries often
   record WHERE a feature lives, whether it was merged or HELD, and the gotcha that
   bit last time.

2. **Git history** (all branches — held/unmerged work counts as prior work):
   ```bash
   git log --all --oneline -i -E --grep='kw1|kw2' | head -20
   git log --all --oneline -S'<distinctive-identifier>' | head -10   # code-level probe
   git branch -a | grep -iE 'kw1|kw2'                                # parked branches
   ```

3. **Closed/merged PRs + issues** (the record of shipped AND rejected approaches):
   ```bash
   gh pr list --state merged --search "kw1 kw2" --limit 10 --json number,title,mergedAt
   gh pr list --state closed --search "kw1 kw2" --limit 5 --json number,title   # rejected ≠ never tried
   gh issue list --state all --search "kw1 kw2" --limit 10 --json number,title,state
   ```

4. **`docs/ROADMAP.md`** — grep for the keywords; the four-state model says whether
   the item is landed, in-progress, planned, or paused (paused = someone already
   started; find out why it stopped before restarting).

5. **Feature catalog** (if present): `docs/feature-catalog.md` in the repo, else
   `$CLAUDE_JOB_DIR/tmp/feature-catalog.md`, else the path in
   `RECALL_FEATURE_CATALOG`. It maps feature → module → status (live/dark/dev/held/
   mock/stalled) and flags known DUPs.

### Synthesize a verdict

Report one of, with references (file paths, commit SHAs, PR/issue numbers, memory
file names):

- **DONE BEFORE** — it exists. Say where it lives, its status (live/dark/held), and
  what the request should be instead (enable a flag? extend it? nothing?).
- **PARTIALLY / ATTEMPTED** — prior branch/PR/design exists (possibly HELD or
  reverted). Say what exists, why it stopped (memory + PR discussion), and what to
  reuse rather than rewrite.
- **NO TRACE** — genuinely new. Say so plainly, and note the nearest-neighbor work
  worth reading first.

Close with the one-line caution when relevant: re-landing by hand has silently dropped
working fixes before — prefer merging/cherry-picking the prior artifact over
re-implementing from memory.

## Notes

- The fast hook (`hooks/recall-prior-work.sh`) already covers memory/git/roadmap/
  catalog on every implement-intent prompt; this skill adds the `gh` searches, content
  excerpts, and the verdict. If the hook pointed you here, keywords are in its output.
- Never block on this: if `gh` is unauthenticated or slow, report what the local
  sources showed and move on.
