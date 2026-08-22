#!/bin/bash
# Daemon hook: called by sphere-sdk daemon when a DM arrives.
# Receives message JSON on stdin. Appends to state file and notifies.
# Always exits 0 (daemon hooks must not fail).
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$HOOK_DIR/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"
STATE_FILE="$STATE_DIR/agent-messages.json"
IDENTITY_FILE="$CLAUDE_PROJECT_DIR/.claude/agent/identity.json"
CONFIG_FILE="$CLAUDE_PROJECT_DIR/.claude/agent/config.json"

mkdir -p "$STATE_DIR"

# Read message from stdin
MSG_JSON=$(cat)

# Extract fields
SENDER=$(echo "$MSG_JSON" | jq -r '.pubkey // .from // "unknown"')
BODY=$(echo "$MSG_JSON" | jq -r '.content // .body // ""')
TIMESTAMP=$(echo "$MSG_JSON" | jq -r '.created_at // empty')

# Convert unix timestamp to ISO if numeric
if [[ "$TIMESTAMP" =~ ^[0-9]+$ ]]; then
  TIMESTAMP=$(date -u -d "@$TIMESTAMP" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    date -u -r "$TIMESTAMP" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    echo "$TIMESTAMP")
fi
TIMESTAMP="${TIMESTAMP:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

# Resolve sender name from config
FROM_NAME=""
OWNER_NPUB=""
if [ -f "$CONFIG_FILE" ]; then
  OWNER_NPUB=$(jq -r '.owner_npub // ""' "$CONFIG_FILE" 2>/dev/null)
  if [ "$SENDER" = "$OWNER_NPUB" ]; then
    FROM_NAME=$(jq -r '.owner_nametag // ""' "$CONFIG_FILE" 2>/dev/null)
  fi
fi

# Determine priority (owner messages are priority).
# Honor a priority flag already computed upstream by our trusted poll helper
# (check-messages sets .priority by comparing hex pubkeys — the daemon delivers that
# shape). Raw Nostr events carry no .priority, so this can't be spoofed by a sender.
IS_PRIORITY=false
INCOMING_PRIORITY=$(echo "$MSG_JSON" | jq -r '.priority // empty' 2>/dev/null)
if [ "$INCOMING_PRIORITY" = "true" ]; then
  IS_PRIORITY=true
elif [ -n "$OWNER_NPUB" ] && [ "$SENDER" = "$OWNER_NPUB" ]; then
  IS_PRIORITY=true
fi

# Build message entry
NEW_MSG=$(jq -n \
  --arg type "dm" \
  --arg from "$SENDER" \
  --arg from_name "$FROM_NAME" \
  --arg body "$BODY" \
  --arg timestamp "$TIMESTAMP" \
  --argjson priority "$IS_PRIORITY" \
  '{
    type: $type,
    from: $from,
    from_name: $from_name,
    body: $body,
    timestamp: $timestamp,
    priority: $priority,
    read: false
  }')

# Append to state file (create if missing)
if [ -f "$STATE_FILE" ]; then
  CURRENT=$(cat "$STATE_FILE")
else
  CURRENT='{"unread": false, "unread_count": 0, "priority_count": 0, "messages": []}'
fi

# Cap retained history to the newest N (default 500) so the shared state file can't grow
# unbounded — see agent-comms-check.sh for the leak this prevents (AGENT_MESSAGES_MAX overrides).
CAP="${AGENT_MESSAGES_MAX:-500}"; case "$CAP" in ''|*[!0-9]*) CAP=500 ;; esac

UPDATED=$(echo "$CURRENT" | jq \
  --argjson msg "$NEW_MSG" \
  --argjson is_priority "$IS_PRIORITY" \
  --argjson cap "$CAP" \
  '.messages += [$msg] |
   .unread = true |
   .unread_count = (.unread_count + 1) |
   .priority_count = (if $is_priority then .priority_count + 1 else .priority_count end) |
   .messages |= .[-$cap:]')

echo "$UPDATED" > "$STATE_FILE"

# Notify
if [ -f "$HOOK_DIR/notify.sh" ]; then
  # shellcheck source=notify.sh
  source "$HOOK_DIR/notify.sh"

  if [ "$IS_PRIORITY" = "true" ]; then
    notify "Unicity Agent: Priority DM" "From owner: ${BODY:0:100}" "critical"
  else
    notify "Unicity Agent: DM" "From ${FROM_NAME:-$SENDER}: ${BODY:0:100}" "normal"
  fi
fi

# Route the just-appended message through the authorization classifier (DEFAULT-DENY).
# Guarded so a classifier failure can never break this daemon hook.
if [ -f "$HOOK_DIR/classify-inbound.sh" ]; then
  bash "$HOOK_DIR/classify-inbound.sh" >/dev/null 2>&1 || true
fi

exit 0
