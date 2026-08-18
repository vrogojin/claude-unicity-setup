#!/bin/bash
# recall-prior-work.sh — UserPromptSubmit hook: "did I do this before?"
#
# We keep dropping/re-implementing features (the wave-batch-v2 hand-re-land silently
# dropped working fixes; grep the memory index for "staging-parity"). This hook is the
# cheap FIRST line: when a prompt looks like implement/add/fix/build intent, it runs a
# FAST, local-only recall search over (1) the auto-memory store, (2) git history,
# (3) docs/ROADMAP.md, (4) a feature catalog if present — and injects an ADVISORY
# "you may have done this before: [refs]" as additionalContext. The deep pass (closed
# PRs/issues via gh, content excerpts) lives in the /recall-prior-work skill, which
# this hook points at.
#
# WHY UserPromptSubmit (not PreToolUse): intent is stated in the user's prompt, once —
# a PreToolUse Edit/Write matcher fires per tool call, long after the plan formed, and
# has no reliable "new feature vs routine edit" signal. UserPromptSubmit runs exactly
# once per request, and its stdout/additionalContext channel is purpose-built for
# advisory context injection. Mirrors the posture of check-diagnostics.sh surfaces:
# advisory, never blocking.
#
# NEVER BLOCKS: always exits 0 with either no output or additionalContext JSON.
# Time-boxed: every search is wrapped in `timeout`; worst case ~5s, typical <1s.
# Debounced: identical keyword sets within 10 min emit nothing (STATE_DIR marker).
#
# Env overrides:
#   RECALL_DISABLE=1              turn the hook off
#   RECALL_MEMORY_DIR=<dir>       memory store (default: this repo's auto-memory dir)
#   RECALL_FEATURE_CATALOG=<file> feature catalog markdown (optional)
set -uo pipefail

[ "${RECALL_DISABLE:-0}" = "1" ] && exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HOOK_DIR/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"
# Shared task classifier (intent gate + keyword extraction + task-id hash),
# factored out so the F2 task-lifecycle hook keys on the SAME logic (C1). If the
# lib is somehow absent, fall back is impossible without duplicating it, so the
# hook simply stays silent (advisory hook — never a hard failure).
. "$HOOK_DIR/lib/task-classifier.sh" 2>/dev/null || exit 0

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)
[ -n "$PROMPT" ] || exit 0

# --- Intent gate: only prompts that read as "make something" -------------------------
# Word-boundary match on implement/build/add/create/fix/wire/integrate/support/feature/
# bug/rework/refactor. Skip slash-commands (skills handle themselves) and tiny prompts.
# (Now delegated to the shared classifier lib — same gates, one source of truth.)
tc_intent_ok "$PROMPT" || exit 0

# --- Keyword extraction: distinctive terms only --------------------------------------
# Lowercase, strip punctuation, drop stopwords + the intent verbs themselves, keep
# tokens of length >= 4, dedupe, take the first 6. Fewer than 2 → too vague, bail.
KEYWORDS=$(tc_keywords "$PROMPT")
KW_COUNT=$(echo "$KEYWORDS" | sed '/^$/d' | wc -l)
[ "$KW_COUNT" -ge 2 ] || exit 0

# --- Debounce: same keyword set within 10 min → stay quiet ---------------------------
KW_HASH=$(tc_task_id "$KEYWORDS")
MARKER="$STATE_DIR/recall-prior-work.last"
if [ -f "$MARKER" ]; then
  LAST_HASH=$(cut -d' ' -f1 "$MARKER" 2>/dev/null)
  LAST_TS=$(cut -d' ' -f2 "$MARKER" 2>/dev/null)
  NOW_TS=$(date +%s)
  if [ "$LAST_HASH" = "$KW_HASH" ] && [ $((NOW_TS - ${LAST_TS:-0})) -lt 600 ] 2>/dev/null; then
    exit 0
  fi
fi
printf '%s %s\n' "$KW_HASH" "$(date +%s)" > "$MARKER" 2>/dev/null || true

# --- Resolve search roots ------------------------------------------------------------
PROJ="${CLAUDE_PROJECT_DIR:-$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd || echo .)}"
if [ -n "${RECALL_MEMORY_DIR:-}" ]; then
  MEM_DIR="$RECALL_MEMORY_DIR"
else
  # Same slug scheme as team-coord.sh's team_root: the repo's auto-memory dir.
  SLUG="$(printf '%s' "$PROJ" | sed 's#/#-#g')"
  MEM_DIR="${HOME:-/tmp}/.claude/projects/$SLUG/memory"
fi
CATALOG="${RECALL_FEATURE_CATALOG:-}"
if [ -z "$CATALOG" ]; then
  for c in "$PROJ/docs/feature-catalog.md" "${CLAUDE_JOB_DIR:-}/tmp/feature-catalog.md"; do
    [ -n "$c" ] && [ -f "$c" ] && { CATALOG="$c"; break; }
  done
fi

# Build an alternation regex from the keywords (they are already [a-z0-9_-] tokens).
KW_RE=$(echo "$KEYWORDS" | sed '/^$/d' | paste -sd'|' -)
[ -n "$KW_RE" ] || exit 0

FINDINGS=""

# --- 0. Prior-work edge graph (Beads-style typed relations, remote-coord.sh store) ---
# duplicates/supersedes/blocks/conflicts-with edges make "have I built this?" a
# lookup: any edge whose endpoints mention a keyword is a strong prior-work signal.
EDGES_FILE="$MEM_DIR/coord/edges.jsonl"
if [ -f "$EDGES_FILE" ]; then
  EDGE_HITS=$(timeout 2 grep -iE "$KW_RE" "$EDGES_FILE" 2>/dev/null | head -3 \
    | jq -r '"    \(.from) —\(.rel)→ \(.to)\(if (.note // "") != "" then " (" + .note + ")" else "" end)"' 2>/dev/null)
  [ -n "$EDGE_HITS" ] && FINDINGS="${FINDINGS}\n- prior-work graph (typed edges):\n${EDGE_HITS}"
fi

# --- 1. Memory store: files whose index line or body hits >= 2 distinct keywords -----
if [ -d "$MEM_DIR" ]; then
  MEM_HITS=$(timeout 2 bash -c '
    for f in "$1"/*.md; do
      [ -e "$f" ] || continue
      n=$(grep -cioE "$2" "$f" 2>/dev/null); [ -n "$n" ] || n=0
      distinct=$(grep -ioE "$2" "$f" 2>/dev/null | tr "A-Z" "a-z" | sort -u | wc -l)
      [ "$distinct" -ge 2 ] && printf "%s %s\n" "$n" "$(basename "$f")"
    done | sort -rn | head -4 | awk "{print \$2}"
  ' _ "$MEM_DIR" "$KW_RE" 2>/dev/null | paste -sd, - | sed 's/,/, /g')
  [ -n "$MEM_HITS" ] && FINDINGS="${FINDINGS}\n- memory: ${MEM_HITS}"
fi

# --- 2. git history: commit subjects matching any keyword (local, no network) --------
if [ -d "$PROJ/.git" ] || git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1; then
  GIT_HITS=$(timeout 3 git -C "$PROJ" log --all --oneline -i --grep="$KW_RE" -E --format='%h %s' 2>/dev/null \
    | head -4 | sed 's/^/    /')
  [ -n "$GIT_HITS" ] && FINDINGS="${FINDINGS}\n- git commits:\n${GIT_HITS}"
fi

# --- 3. ROADMAP: lines mentioning any keyword ----------------------------------------
if [ -f "$PROJ/docs/ROADMAP.md" ]; then
  RM_HITS=$(timeout 2 grep -inE "$KW_RE" "$PROJ/docs/ROADMAP.md" 2>/dev/null \
    | head -3 | cut -c1-160 | sed 's/^/    L/')
  [ -n "$RM_HITS" ] && FINDINGS="${FINDINGS}\n- docs/ROADMAP.md:\n${RM_HITS}"
fi

# --- 4. Feature catalog (if present) -------------------------------------------------
if [ -n "$CATALOG" ] && [ -f "$CATALOG" ]; then
  CAT_HITS=$(timeout 2 grep -inE "$KW_RE" "$CATALOG" 2>/dev/null \
    | head -3 | cut -c1-160 | sed 's/^/    L/')
  [ -n "$CAT_HITS" ] && FINDINGS="${FINDINGS}\n- feature catalog ($(basename "$CATALOG")):\n${CAT_HITS}"
fi

[ -n "$FINDINGS" ] || exit 0

CONTEXT="PRIOR-WORK RECALL (advisory, non-blocking): this request may overlap earlier work — check before re-implementing (features have been silently dropped and rebuilt before):${FINDINGS}\n\nKeywords matched: $(echo "$KEYWORDS" | paste -sd, - | sed 's/,/, /g'). For the deep pass (closed/merged PRs + issues via gh, memory excerpts), run: /recall-prior-work $(echo "$KEYWORDS" | head -3 | tr '\n' ' ' | sed 's/ $//')"

jq -n --arg ctx "$(printf '%b' "$CONTEXT")" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$ctx}}' 2>/dev/null
exit 0
