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
# Timestamp of the last SUCCESSFUL poll (messages actually fetched), used as the lookback
# floor so a gap longer than the cooldown can't silently drop inbound messages.
LAST_OK_FILE="$STATE_DIR/agent-comms-last-ok"
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
# Prefer the path recorded at setup time (env, then config): the framework helper lives under
# the clone (it loads @unicitylabs/sphere-sdk from the clone's node_modules), NOT under the
# hooks copied into .claude/, so the relative candidates below miss on a fresh peer.
HELPER=""
if [ -n "${TEAM_SPHERE_HELPER:-}" ] && [ -f "${TEAM_SPHERE_HELPER}" ]; then
  HELPER="$TEAM_SPHERE_HELPER"
else
  HELPER_CFG="$(jq -r '.transport.helper_path // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
  if [ -n "$HELPER_CFG" ] && [ -f "$HELPER_CFG" ]; then
    HELPER="$HELPER_CFG"
  else
    for candidate in \
      "$CLAUDE_PROJECT_DIR/../lib/sphere-helper.mjs" \
      "$CLAUDE_PROJECT_DIR/lib/sphere-helper.mjs" \
      "$(dirname "$HOOK_DIR")/../lib/sphere-helper.mjs"; do
      if [ -f "$candidate" ]; then
        HELPER="$candidate"
        break
      fi
    done
  fi
fi

if [ -z "$HELPER" ]; then
  # No transport helper resolvable → inbound relay polling cannot run. On a fresh peer this
  # is a real misconfiguration (no recorded transport.helper_path), not a benign no-op, so
  # surface it (rate-limited by the cooldown already stamped above) instead of exiting silently.
  echo "WARN(agent-comms-check): sphere-helper.mjs unresolved — inbound relay polling DISABLED. Set \$TEAM_SPHERE_HELPER or record transport.helper_path (re-run setup.sh)." >&2
  exit 0
fi

# NODE_PATH → the clone's node_modules (helper dir → ../node_modules) so the helper loads
# @unicitylabs/sphere-sdk even when invoked from outside the clone (mirrors sphere-daemon.mjs).
HELPER_NODE_PATH="$(cd "$(dirname "$HELPER")/.." 2>/dev/null && pwd)/node_modules:${NODE_PATH:-}"

# --- Calculate since timestamp ---
# Look back to the LAST SUCCESSFUL poll, not a fixed NOW-600. The cooldown (600s) can be
# exceeded by an arbitrary gap between Bash tool calls; a fixed 10-min window can't cover its
# own gap, so anything that arrived in the interim would be dropped. Bound the lookback to a
# sane max (24h) so a very stale marker doesn't request an enormous window. Fall back to
# NOW-600 when there is no prior successful poll.
MAX_LOOKBACK=86400
SINCE=$(( NOW - 600 ))
if [ -f "$LAST_OK_FILE" ]; then
  LAST_OK=$(cat "$LAST_OK_FILE" 2>/dev/null || echo 0)
  case "$LAST_OK" in ''|*[!0-9]*) LAST_OK=0 ;; esac
  if [ "$LAST_OK" -gt 0 ]; then
    SINCE="$LAST_OK"
    [ $(( NOW - SINCE )) -gt "$MAX_LOOKBACK" ] && SINCE=$(( NOW - MAX_LOOKBACK ))
  fi
fi

# --- Poll for messages ---
# Capture the helper's REAL exit code (no inline `|| echo` fallback, which would mask a
# transport failure as exit 0 and let the fallback JSON below advance the last-OK floor).
POLL_RESULT=$(NODE_PATH="$HELPER_NODE_PATH" node "$HELPER" check-messages \
  --identity "$IDENTITY_FILE" \
  --config "$CONFIG_FILE" \
  --since "$SINCE" 2>/dev/null)
POLL_RC=$?

if [ "$POLL_RC" -ne 0 ]; then
  # Helper failed (crash / relay unreachable / network down) — do NOT advance the last-OK
  # floor. Advancing it on an outage would silently shrink the next lookback window and drop
  # messages the relay retained during the gap. Leaving the floor intact lets the next
  # successful poll recover them. Fall through with an empty set (async hook stays exit 0).
  POLL_RESULT='{"messages":[]}'
elif echo "$POLL_RESULT" | jq -e 'has("messages")' >/dev/null 2>&1; then
  # Genuine success (helper exited 0 AND returned parseable JSON with a messages array):
  # record NOW as the next lookback floor.
  echo "$NOW" > "$LAST_OK_FILE" 2>/dev/null || true
fi

NEW_COUNT=$(echo "$POLL_RESULT" | jq '.messages | length' 2>/dev/null || echo 0)

# Exit if no new messages
if [ "$NEW_COUNT" -eq 0 ] 2>/dev/null; then
  exit 0
fi

# --- Merge into state file ---
if [ -f "$STATE_FILE" ]; then
  CURRENT=$(cat "$STATE_FILE")
else
  CURRENT='{"unread": false, "unread_count": 0, "priority_count": 0, "messages": []}'
fi

# Merge: append new messages, update counts
MERGED=$(echo "$CURRENT" | jq \
  --argjson new_msgs "$(echo "$POLL_RESULT" | jq '.messages')" \
  '.messages += $new_msgs |
   .unread = true |
   .unread_count = (.unread_count + ($new_msgs | length)) |
   .priority_count = (.priority_count + ($new_msgs | map(select(.priority == true)) | length))')

echo "$MERGED" > "$STATE_FILE"

# --- Route newly-merged messages through the authorization classifier (DEFAULT-DENY) ---
if [ -f "$HOOK_DIR/classify-inbound.sh" ]; then
  bash "$HOOK_DIR/classify-inbound.sh" >/dev/null 2>&1 || true
fi

# --- Notify ---
PRIORITY_NEW=$(echo "$POLL_RESULT" | jq '[.messages[] | select(.priority == true)] | length' 2>/dev/null || echo 0)

if [ -f "$HOOK_DIR/notify.sh" ]; then
  # shellcheck source=notify.sh
  source "$HOOK_DIR/notify.sh"

  if [ "$PRIORITY_NEW" -gt 0 ] 2>/dev/null; then
    notify "Unicity Agent: Priority Messages" "$PRIORITY_NEW priority + $NEW_COUNT total new message(s)" "critical"
  else
    notify "Unicity Agent: New Messages" "$NEW_COUNT new message(s) from dev group" "normal"
  fi
fi

exit 0
