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
# sphere-helper is the canonical source for npub → 32-byte x-only hex
# conversion (handles standard NIP-19, legacy L1-style 33-byte npub, and
# bare hex forms). Resolved relative to this hooks dir, fallback to the
# standard install path so direct invocation also works.
SPHERE_HELPER="$HOOK_DIR/../../lib/sphere-helper.mjs"
if [ ! -f "$SPHERE_HELPER" ]; then
  SPHERE_HELPER="$HOME/claude_unicity_setup/lib/sphere-helper.mjs"
fi

mkdir -p "$STATE_DIR"

# Read message from stdin
MSG_JSON=$(cat)

# Extract fields. `from` is the helper-supplied x-only hex pubkey of the
# real sender (NIP-17 unwrap result); `pubkey` is the legacy field name.
SENDER=$(echo "$MSG_JSON" | jq -r '.from // .pubkey // "unknown"')
BODY=$(echo "$MSG_JSON" | jq -r '.content // .body // ""')
TIMESTAMP=$(echo "$MSG_JSON" | jq -r '.created_at // empty')
# Helper already computes priority (sender hex vs decoded owner hex). Trust it
# when present; otherwise we recompute below using the same helper for npub
# decode so we never compare bech32-to-hex.
HELPER_PRIORITY=$(echo "$MSG_JSON" | jq -r '.priority // empty')

# Convert unix timestamp to ISO if numeric
if [[ "$TIMESTAMP" =~ ^[0-9]+$ ]]; then
  TIMESTAMP=$(date -u -d "@$TIMESTAMP" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    date -u -r "$TIMESTAMP" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    echo "$TIMESTAMP")
fi
TIMESTAMP="${TIMESTAMP:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

# Decode the configured owner npub once to canonical 32-byte hex. The previous
# implementation compared SENDER (hex) to OWNER_NPUB (bech32) — those never
# match, so priority routing was silently dead. Now we shell out to
# sphere-helper.mjs npub-to-hex (handles standard + legacy + bare-hex inputs)
# so the comparison is hex-to-hex.
OWNER_NPUB=""
OWNER_HEX=""
OWNER_NAMETAG=""
if [ -f "$CONFIG_FILE" ]; then
  OWNER_NPUB=$(jq -r '.owner_npub // ""' "$CONFIG_FILE" 2>/dev/null)
  OWNER_NAMETAG=$(jq -r '.owner_nametag // ""' "$CONFIG_FILE" 2>/dev/null)
  if [ -n "$OWNER_NPUB" ] && [ -f "$SPHERE_HELPER" ]; then
    OWNER_HEX=$(node "$SPHERE_HELPER" npub-to-hex "$OWNER_NPUB" 2>/dev/null || true)
  fi
fi

# Determine priority (owner messages are priority). Trust the helper's
# pre-computed value when present; fall back to local hex-to-hex compare.
IS_PRIORITY=false
if [ "$HELPER_PRIORITY" = "true" ]; then
  IS_PRIORITY=true
elif [ -n "$OWNER_HEX" ] && [ "$SENDER" = "$OWNER_HEX" ]; then
  IS_PRIORITY=true
fi

# Resolve sender display name from config (only relevant for owner DMs).
FROM_NAME=""
if [ "$IS_PRIORITY" = "true" ]; then
  FROM_NAME="$OWNER_NAMETAG"
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
    notify "Unicity Agent: Priority DM" "From owner: ${BODY:0:100}" "critical"
  else
    notify "Unicity Agent: DM" "From ${FROM_NAME:-$SENDER}: ${BODY:0:100}" "normal"
  fi
fi

exit 0
