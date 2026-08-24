#!/bin/bash
# PreToolUse hook (Edit|Write): blocks writes to REPO CODE while the target
# file's OWN git worktree is on main/master — forcing a feature branch first.
#
# Worktree-aware: it resolves the branch of the worktree that actually contains
# the file being edited, NOT $CLAUDE_PROJECT_DIR (which is pinned to the shared
# main checkout). This fixes two false-blocks:
#   1. git-worktree agents correctly on a feature branch were blocked because
#      CLAUDE_PROJECT_DIR sat on main.
#   2. writes OUTSIDE any git repo (scratchpad, ~/.claude memory) were blocked.

INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

# On Windows the path arrives backslash-spelled. `dirname` then returns "." and the
# worktree lookup below silently inspects the wrong repository — the guard reads as
# "allowed" for every file. Normalize once, here, and everything downstream is sane.
FILE=${FILE//\\//}

# Branch of the worktree containing $1 (walk up to an existing dir first, since
# a Write target may not exist yet). Empty if the path is not inside a git repo.
branch_of() {
  local d="$1"
  while [ -n "$d" ] && [ ! -d "$d" ] && [ "$d" != "/" ]; do d=$(dirname "$d"); done
  [ -d "$d" ] || return 1
  git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null
}


# Claude Code's own memory store is a git repo in our setup (it syncs itself to
# a private remote and lives on main by design). It is not repo code, so the
# branch rule must not apply to it — otherwise every memory write is blocked.
case "$FILE" in
  */.claude/projects/*/memory/*) exit 0 ;;
esac

if [ -n "$FILE" ]; then
  BRANCH=$(branch_of "$(dirname "$FILE")")
  # Not inside any git repo (scratchpad, ~/.claude memory, /tmp) → always allow.
  [ -z "$BRANCH" ] && exit 0
else
  # No file path in the payload (unexpected for Edit|Write) → fall back to the
  # project dir's branch so the guard still fires on main.
  BRANCH=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
fi

if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  jq -n --arg reason "You are on '$BRANCH'. Create a feature branch before writing code: git checkout -b <branch-name> main" '{
    "decision": "block",
    "reason": $reason
  }'
  exit 0
fi

exit 0
