#!/bin/bash
# Daemon hook: called by sphere-sdk daemon when a group message arrives.
# Receives message JSON on stdin. Filters own messages, appends to state file, notifies.
# Always exits 0 (daemon hooks must not fail).
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="/tmp/claude"
STATE_FILE="$STATE_DIR/agent-messages.json"
IDENTITY_FILE="$CLAUDE_PROJECT_DIR/.claude/agent/identity.json"
CONFIG_FILE="$CLAUDE_PROJECT_DIR/.claude/agent/config.json"
# Canonical npub → 32-byte x-only hex decoder. See on-dm.sh for rationale.
SPHERE_HELPER="$HOOK_DIR/../../lib/sphere-helper.mjs"
if [ ! -f "$SPHERE_HELPER" ]; then
  SPHERE_HELPER="$HOME/claude_unicity_setup/lib/sphere-helper.mjs"
fi

mkdir -p "$STATE_DIR"

# Read message from stdin
MSG_JSON=$(cat)

# Extract fields. SENDER is the group-message author's x-only hex pubkey
# (NIP-29 events are not gift-wrapped — pubkey on the event is the real
# sender, exposed by the helper as `.from`).
SENDER=$(echo "$MSG_JSON" | jq -r '.from // .pubkey // "unknown"')
BODY=$(echo "$MSG_JSON" | jq -r '.content // .body // ""')
TIMESTAMP=$(echo "$MSG_JSON" | jq -r '.created_at // empty')
GROUP_ID=$(echo "$MSG_JSON" | jq -r '.tags[]? | select(.[0] == "h") | .[1] // empty' 2>/dev/null || echo "")
GROUP_NAME=$(echo "$MSG_JSON" | jq -r '.group_name // "UNICITY_DEV_AGENTS"')

# Filter out own messages. Previously compared SENDER (hex) to OWN_NPUB
# (bech32 from identity.json) — never matched, so own messages always
# leaked into the inbox. Decode the npub to canonical hex first. (The
# helper-side check-messages already filters by pubkey equality, so this
# is a belt-and-braces guard for direct event delivery paths.)
if [ -f "$IDENTITY_FILE" ] && [ -f "$SPHERE_HELPER" ]; then
  OWN_NPUB=$(jq -r '.npub // ""' "$IDENTITY_FILE" 2>/dev/null)
  if [ -n "$OWN_NPUB" ]; then
    OWN_HEX=$(node "$SPHERE_HELPER" npub-to-hex "$OWN_NPUB" 2>/dev/null || true)
    if [ -n "$OWN_HEX" ] && [ "$SENDER" = "$OWN_HEX" ]; then
      exit 0
    fi
  fi
fi

# Convert unix timestamp to ISO if numeric
if [[ "$TIMESTAMP" =~ ^[0-9]+$ ]]; then
  TIMESTAMP=$(date -u -d "@$TIMESTAMP" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    date -u -r "$TIMESTAMP" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    echo "$TIMESTAMP")
fi
TIMESTAMP="${TIMESTAMP:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

# Check if sender is owner (priority). Same bech32-vs-hex bug as own-message
# filter above — fixed by decoding owner_npub to hex via sphere-helper.
# Trust the helper-computed priority field when the daemon passed one.
HELPER_PRIORITY=$(echo "$MSG_JSON" | jq -r '.priority // empty')
OWNER_NPUB=""
OWNER_HEX=""
IS_PRIORITY=false
if [ -f "$CONFIG_FILE" ]; then
  OWNER_NPUB=$(jq -r '.owner_npub // ""' "$CONFIG_FILE" 2>/dev/null)
  if [ -n "$OWNER_NPUB" ] && [ -f "$SPHERE_HELPER" ]; then
    OWNER_HEX=$(node "$SPHERE_HELPER" npub-to-hex "$OWNER_NPUB" 2>/dev/null || true)
  fi
fi
if [ "$HELPER_PRIORITY" = "true" ]; then
  IS_PRIORITY=true
elif [ -n "$OWNER_HEX" ] && [ "$SENDER" = "$OWNER_HEX" ]; then
  IS_PRIORITY=true
fi

# Build message entry
NEW_MSG=$(jq -n \
  --arg type "group" \
  --arg from "$SENDER" \
  --arg from_name "" \
  --arg body "$BODY" \
  --arg timestamp "$TIMESTAMP" \
  --argjson priority "$IS_PRIORITY" \
  --arg group_id "$GROUP_ID" \
  --arg group_name "$GROUP_NAME" \
  '{
    type: $type,
    from: $from,
    from_name: $from_name,
    body: $body,
    timestamp: $timestamp,
    priority: $priority,
    read: false,
    group: {
      id: $group_id,
      name: $group_name
    }
  }')

# Append to state file (create if missing)
if [ -f "$STATE_FILE" ]; then
  CURRENT=$(cat "$STATE_FILE")
else
  CURRENT='{"unread": false, "unread_count": 0, "priority_count": 0, "messages": []}'
fi

UPDATED=$(echo "$CURRENT" | jq \
  --argjson msg "$NEW_MSG" \
  --argjson is_priority "$IS_PRIORITY" \
  '.messages += [$msg] |
   .unread = true |
   .unread_count = (.unread_count + 1) |
   .priority_count = (if $is_priority then .priority_count + 1 else .priority_count end)')

echo "$UPDATED" > "$STATE_FILE"

# Notify
if [ -f "$HOOK_DIR/notify.sh" ]; then
  # shellcheck source=notify.sh
  source "$HOOK_DIR/notify.sh"

  if [ "$IS_PRIORITY" = "true" ]; then
    notify "Unicity Agent: Priority Group Message" "From owner in ${GROUP_NAME}: ${BODY:0:100}" "critical"
  else
    notify "Unicity Agent: Group" "${GROUP_NAME}: ${BODY:0:100}" "low"
  fi
fi

exit 0
