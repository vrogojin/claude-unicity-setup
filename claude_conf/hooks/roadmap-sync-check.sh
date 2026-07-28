#!/bin/bash
# Async PostToolUse hook: detects when a feature branch has landed code/feature
# changes WITHOUT a corresponding docs/ROADMAP.md update, and nudges the agent to
# run /roadmap-sync so the roadmap and the GitHub Project board stay in sync.
#
# Fires after Bash tool calls (a `git commit` moves HEAD). Never blocks (async
# hooks cannot block). Writes a state file for check-diagnostics.sh to enforce at
# Stop time — same soft-reminder-becomes-Stop-nudge pattern as remote-sync-check
# and dep-update-check.
#
# Dedup: keyed on the current HEAD sha — the full evaluation only runs when HEAD
# moves, so this is cheap on the vast majority of Bash calls.
# State file: <state-dir>/roadmap-sync.json
# Escape hatch: rm -f /tmp/claude/*/roadmap-sync.json
#
# Degrades to a silent no-op when: not a git repo, `gh` is absent (can't reach a
# board anyway), `jq` is absent, there is no `main` ref to diff against, or we are
# sitting on main/master (the workflow forbids committing code straight to main).

INPUT=$(cat)

# --- Preconditions (any failure → silent no-op) ---
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Resolve a main-ish base ref; without one we cannot scope "the branch's work".
BASE_REF=""
for ref in main master; do
  if git rev-parse --verify "$ref" >/dev/null 2>&1; then BASE_REF="$ref"; break; fi
done
[ -n "$BASE_REF" ] || exit 0

# Only meaningful on a feature branch — never nag while sitting on main/master.
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
[ "$CURRENT_BRANCH" = "HEAD" ] && exit 0
[ "$CURRENT_BRANCH" = "$BASE_REF" ] && exit 0

. "$(cd "$(dirname "$0")" 2>/dev/null && pwd)/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"
STATE_FILE="$STATE_DIR/roadmap-sync.json"
NOTIFIED_FILE="$STATE_DIR/roadmap-sync-notified"
mkdir -p "$STATE_DIR" 2>/dev/null || true

HEAD_SHA=$(git rev-parse HEAD 2>/dev/null)
[ -n "$HEAD_SHA" ] || exit 0

# --- Dedup: skip the full evaluation if HEAD hasn't moved since last check ---
if [ -f "$STATE_FILE" ]; then
  LAST_HEAD=$(jq -r '.head_sha // ""' "$STATE_FILE" 2>/dev/null)
  if [ "$LAST_HEAD" = "$HEAD_SHA" ]; then
    exit 0
  fi
fi

# --- Scope: files this branch changed vs its merge-base with the base ref ---
# Three-dot diff = changes introduced on THIS branch only (ignores base-ref moves).
CHANGED=$(git diff --name-only "$BASE_REF"...HEAD 2>/dev/null)

# Empty branch (no divergence yet) → nothing to reconcile.
if [ -z "$CHANGED" ]; then
  rm -f "$STATE_FILE" "$NOTIFIED_FILE" 2>/dev/null || true
  exit 0
fi

# If the roadmap itself is among the changes, the branch already tracks it → clear.
if printf '%s\n' "$CHANGED" | grep -qx 'docs/ROADMAP.md'; then
  rm -f "$STATE_FILE" "$NOTIFIED_FILE" 2>/dev/null || true
  exit 0
fi

# Classify the remaining files: does any qualify as a code/feature change?
# Doc-only and trivial-config changes must NOT trip the nudge (no false positives).
CODE_FILES=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    # Docs / prose
    *.md|*.mdx|*.markdown|*.txt|*.rst|*.adoc|docs/*|*/docs/*) continue ;;
    LICENSE|LICENSE.*|COPYING|NOTICE|AUTHORS|CHANGELOG*|*/CHANGELOG*) continue ;;
    # Trivial repo/meta config
    .gitignore|.gitattributes|.editorconfig|.mailmap) continue ;;
    # Agent-local config (never product work)
    .claude/*|*/.claude/*) continue ;;
  esac
  CODE_FILES=$((CODE_FILES + 1))
done <<< "$CHANGED"

DETECTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%S" 2>/dev/null)

# Doc-only / trivial branch → not pending, but record HEAD so we don't re-scan it.
if [ "$CODE_FILES" -eq 0 ]; then
  jq -n \
    --arg head_sha "$HEAD_SHA" \
    --arg branch "$CURRENT_BRANCH" \
    --arg detected_at "$DETECTED_AT" \
    '{pending:false, head_sha:$head_sha, branch:$branch, code_files:0, detected_at:$detected_at}' \
    > "$STATE_FILE" 2>/dev/null || true
  rm -f "$NOTIFIED_FILE" 2>/dev/null || true
  exit 0
fi

# --- Pending: code changed on this branch, ROADMAP.md was not touched ---
jq -n \
  --arg head_sha "$HEAD_SHA" \
  --arg branch "$CURRENT_BRANCH" \
  --argjson code_files "$CODE_FILES" \
  --arg detected_at "$DETECTED_AT" \
  '{pending:true, head_sha:$head_sha, branch:$branch, code_files:$code_files, detected_at:$detected_at}' \
  > "$STATE_FILE" 2>/dev/null || true

# --- Notify once per HEAD (dedup via notified file) ---
PREV_KEY=""
[ -f "$NOTIFIED_FILE" ] && PREV_KEY=$(cat "$NOTIFIED_FILE" 2>/dev/null)
if [ "$HEAD_SHA" != "$PREV_KEY" ]; then
  HOOK_DIR="$(dirname "$0")"
  if [ -f "$HOOK_DIR/notify.sh" ]; then
    # shellcheck source=notify.sh
    source "$HOOK_DIR/notify.sh"
    notify "Unicity: Roadmap Out of Sync" \
      "$CURRENT_BRANCH changed $CODE_FILES code file(s) but not docs/ROADMAP.md. Run /roadmap-sync." \
      "normal"
  fi
  echo "$HEAD_SHA" > "$NOTIFIED_FILE" 2>/dev/null || true
fi

exit 0
