#!/bin/bash
# Daemon hook: called when a FIREWALLED group message surfaces (owner/team only).
# Receives one surfaced record JSON on stdin (from sphere-helper's pipeline):
#   { type:"group", from_npub, nametag, tier, sif, msg_id, timestamp, wrapped,
#     priority, group:{id,name} }
#
# Red-team F5: group senders are classified by the per-npub contacts.json, NEVER
# by relay group presence. This hook RE-DERIVES the tier from contacts.json (F15)
# and refuses to surface anything not owner|team — an unknown npub posting into
# the group is NOT trusted merely for being in the group.
# Always exits 0 (daemon hooks must not fail).
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$HOOK_DIR/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"
STATE_FILE="$STATE_DIR/agent-messages.json"
CONFIG_FILE="$CLAUDE_PROJECT_DIR/.claude/agent/config.json"
CONTACTS_FILE="$CLAUDE_PROJECT_DIR/.claude/agent/contacts.json"

mkdir -p "$STATE_DIR"

MSG_JSON=$(cat)

FROM_NPUB=$(echo "$MSG_JSON" | jq -r '.from_npub // empty')
WRAPPED=$(echo "$MSG_JSON" | jq -r '.wrapped // empty')
MSG_ID=$(echo "$MSG_JSON" | jq -r '.msg_id // empty')
SIF=$(echo "$MSG_JSON" | jq -r '.sif // "unknown"')
NAMETAG=$(echo "$MSG_JSON" | jq -r '.nametag // ""')
TIMESTAMP=$(echo "$MSG_JSON" | jq -r '.timestamp // empty')
TIMESTAMP="${TIMESTAMP:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
GROUP_ID=$(echo "$MSG_JSON" | jq -r '.group.id // ""')
GROUP_NAME=$(echo "$MSG_JSON" | jq -r '.group.name // "UNICITY_DEV_AGENTS"')

if [ -z "$WRAPPED" ] || [ -z "$FROM_NPUB" ]; then
  echo "on-group: dropping malformed record (no wrapped frame / from_npub)" >&2
  exit 0
fi

# --- F15/F5: re-derive tier from contacts.json ---
OWNER_NPUB=""
[ -f "$CONFIG_FILE" ] && OWNER_NPUB=$(jq -r '.owner_npub // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
TIER="pending"
if [ -n "$OWNER_NPUB" ] && [ "$FROM_NPUB" = "$OWNER_NPUB" ]; then
  TIER="owner"
elif [ -f "$CONTACTS_FILE" ]; then
  if jq -e --arg n "$FROM_NPUB" '.blocked | index($n)' "$CONTACTS_FILE" >/dev/null 2>&1; then
    TIER="blocked"
  else
    TIER=$(jq -r --arg n "$FROM_NPUB" '.contacts[$n].tier // "pending"' "$CONTACTS_FILE" 2>/dev/null || echo "pending")
  fi
fi

case "$TIER" in
  owner|team) : ;;
  *)
    echo "on-group: refusing to surface $FROM_NPUB — re-derived tier '$TIER' not owner|team (F5/F15)" >&2
    exit 0
    ;;
esac

IS_PRIORITY=false
[ "$TIER" = "owner" ] && IS_PRIORITY=true

NEW_MSG=$(jq -n \
  --arg type "group" \
  --arg from "$FROM_NPUB" \
  --arg from_name "$NAMETAG" \
  --arg tier "$TIER" \
  --arg sif "$SIF" \
  --arg msg_id "$MSG_ID" \
  --arg wrapped "$WRAPPED" \
  --arg timestamp "$TIMESTAMP" \
  --argjson priority "$IS_PRIORITY" \
  --arg group_id "$GROUP_ID" \
  --arg group_name "$GROUP_NAME" \
  '{ type: $type, from: $from, from_name: $from_name, tier: $tier, sif: $sif,
     msg_id: $msg_id, wrapped: $wrapped, timestamp: $timestamp,
     priority: $priority, read: false,
     group: { id: $group_id, name: $group_name } }')

if [ -f "$STATE_FILE" ]; then CURRENT=$(cat "$STATE_FILE"); else
  CURRENT='{"unread": false, "unread_count": 0, "priority_count": 0, "messages": []}'
fi

UPDATED=$(echo "$CURRENT" | jq \
  --argjson msg "$NEW_MSG" \
  --argjson is_priority "$IS_PRIORITY" \
  '.messages += [$msg] | .unread = true |
   .unread_count = (.unread_count + 1) |
   .priority_count = (if $is_priority then .priority_count + 1 else .priority_count end)')

echo "$UPDATED" > "$STATE_FILE"

if [ -f "$HOOK_DIR/notify.sh" ]; then
  # shellcheck source=notify.sh
  source "$HOOK_DIR/notify.sh"
  WHO="${NAMETAG:-${FROM_NPUB:0:14}…}"
  if [ "$IS_PRIORITY" = "true" ]; then
    notify "Unicity Agent: Priority Group Message" "From owner ${WHO} in ${GROUP_NAME} — run /check-messages" "critical"
  else
    notify "Unicity Agent: Group" "${WHO} [${TIER}] in ${GROUP_NAME} — run /check-messages" "low"
  fi
fi

exit 0
