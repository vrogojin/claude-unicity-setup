#!/bin/bash
# Async PostToolUse hook: fallback polling for agent messages.
# Fires after Bash tool calls. Never blocks (async hooks cannot block).
# Polls Nostr relays via sphere-helper.mjs if the daemon isn't running.
# Merges new messages into the shared state file.
#
# Cooldown: skips if last poll was <10 minutes ago.
# State file: /tmp/claude/agent-messages.json

INPUT=$(cat)

cd "$CLAUDE_PROJECT_DIR" 2>/dev/null || exit 0

IDENTITY_FILE="$CLAUDE_PROJECT_DIR/.claude/agent/identity.json"
CONFIG_FILE="$CLAUDE_PROJECT_DIR/.claude/agent/config.json"

# Skip if no identity configured
[ -f "$IDENTITY_FILE" ] || exit 0
[ -f "$CONFIG_FILE" ] || exit 0

. "$(cd "$(dirname "$0")" 2>/dev/null && pwd)/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"
STATE_FILE="$STATE_DIR/agent-messages.json"
COOLDOWN_FILE="$STATE_DIR/agent-comms-last-poll"
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$STATE_DIR"

# --- Cooldown: skip if last poll was <10 minutes ago ---
NOW=$(date +%s)
if [ -f "$COOLDOWN_FILE" ]; then
  LAST_POLL=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
  ELAPSED=$(( NOW - LAST_POLL ))
  if [ "$ELAPSED" -lt 600 ]; then
    exit 0
  fi
fi

echo "$NOW" > "$COOLDOWN_FILE"

# --- Locate sphere-helper.mjs ---
# Try relative to hooks dir (deployed), then relative to project
HELPER=""
for candidate in \
  "$CLAUDE_PROJECT_DIR/../lib/sphere-helper.mjs" \
  "$CLAUDE_PROJECT_DIR/lib/sphere-helper.mjs" \
  "$(dirname "$HOOK_DIR")/../lib/sphere-helper.mjs"; do
  if [ -f "$candidate" ]; then
    HELPER="$candidate"
    break
  fi
done

if [ -z "$HELPER" ]; then
  # No helper available — cannot poll
  exit 0
fi

# --- Calculate since timestamp (10 minutes ago) ---
SINCE=$(( NOW - 600 ))

# --- Poll for messages ---
POLL_RESULT=$(node "$HELPER" check-messages \
  --identity "$IDENTITY_FILE" \
  --config "$CONFIG_FILE" \
  --since "$SINCE" 2>/dev/null || echo '{"messages":[]}')

# The helper output is ALREADY firewalled (only owner/team surfaced messages
# appear in .messages; unknown senders / blocked / SIF-held never do). We do NOT
# merge raw here — we dispatch each record through the SAME hooks the daemon uses,
# so the F15 tier re-derivation + wrapped-only write happen in exactly one place.
NEW_COUNT=$(echo "$POLL_RESULT" | jq '(.messages // []) | length' 2>/dev/null || echo 0)
PENDING_COUNT=$(echo "$POLL_RESULT" | jq '(.pending // []) | length' 2>/dev/null || echo 0)
HELD_COUNT=$(echo "$POLL_RESULT" | jq '(.held // []) | length' 2>/dev/null || echo 0)

if [ "$NEW_COUNT" -eq 0 ] 2>/dev/null && [ "$PENDING_COUNT" -eq 0 ] 2>/dev/null && [ "$HELD_COUNT" -eq 0 ] 2>/dev/null; then
  exit 0
fi

dispatch() { # $1 = hook script, stdin = record JSON
  local hook="$HOOK_DIR/$1"
  [ -x "$hook" ] || return 0
  CLAUDE_PROJECT_DIR="$CLAUDE_PROJECT_DIR" bash "$hook" || true
}

# Surfaced messages → on-dm.sh / on-group-message.sh
echo "$POLL_RESULT" | jq -c '.messages[]?' 2>/dev/null | while IFS= read -r rec; do
  if [ "$(echo "$rec" | jq -r '.type')" = "group" ]; then
    echo "$rec" | dispatch "on-group-message.sh"
  else
    echo "$rec" | dispatch "on-dm.sh"
  fi
done

# Pending contact requests + SIF-held → on-notice.sh (structural only, F6)
echo "$POLL_RESULT" | jq -c '.pending[]? | {kind:"pending_contact", from_npub:.npub, count_held:.count_held}' 2>/dev/null | while IFS= read -r rec; do
  echo "$rec" | dispatch "on-notice.sh"
done
echo "$POLL_RESULT" | jq -c '.held[]? | {kind:"held", from_npub:.npub, tier:.tier, reason:.reason}' 2>/dev/null | while IFS= read -r rec; do
  echo "$rec" | dispatch "on-notice.sh"
done

exit 0
