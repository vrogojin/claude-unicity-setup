#!/bin/bash
# Daemon hook: called when a FIREWALLED DM surfaces (owner/team only).
# Receives one surfaced record JSON on stdin (from sphere-helper's pipeline):
#   { type, from_npub, nametag, tier, sif, msg_id, timestamp, wrapped, priority }
#
# Security posture (design §3.5 / §4.4 + red-team F15):
#   - RE-DERIVE the tier from contacts.json (the single source of truth) and
#     refuse to write anything whose re-derived tier is not owner|team. The
#     `.tier` stamp on the record is a hint, NEVER an authorization.
#   - Write ONLY the quarantined `<peer_message>` `wrapped` frame to the inbox —
#     never the raw body. The frame is the only model-facing text.
#   - Notifications carry STRUCTURAL facts only (npub/nametag/tier) — never peer
#     text (red-team F4/F6: never interpolate peer strings into a notice line).
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

# A record without a wrapped frame or sender is malformed — drop it.
if [ -z "$WRAPPED" ] || [ -z "$FROM_NPUB" ]; then
  echo "on-dm: dropping malformed record (no wrapped frame / from_npub)" >&2
  exit 0
fi

# --- F15: re-derive tier from contacts.json, never trust the stamp ---
OWNER_NPUB=""
[ -f "$CONFIG_FILE" ] && OWNER_NPUB=$(jq -r '.owner_npub // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
TIER="pending"
if [ -n "$OWNER_NPUB" ] && [ "$FROM_NPUB" = "$OWNER_NPUB" ]; then
  TIER="owner"
elif [ -f "$CONTACTS_FILE" ]; then
  # blocked wins; then contact tier
  if jq -e --arg n "$FROM_NPUB" '.blocked | index($n)' "$CONTACTS_FILE" >/dev/null 2>&1; then
    TIER="blocked"
  else
    TIER=$(jq -r --arg n "$FROM_NPUB" '.contacts[$n].tier // "pending"' "$CONTACTS_FILE" 2>/dev/null || echo "pending")
  fi
fi

case "$TIER" in
  owner|team) : ;;  # authorized to surface
  *)
    echo "on-dm: refusing to surface $FROM_NPUB — re-derived tier '$TIER' not owner|team (F15)" >&2
    exit 0
    ;;
esac

IS_PRIORITY=false
[ "$TIER" = "owner" ] && IS_PRIORITY=true

# --- Build inbox entry: wrapped frame is the ONLY model-facing text ---
NEW_MSG=$(jq -n \
  --arg type "dm" \
  --arg from "$FROM_NPUB" \
  --arg from_name "$NAMETAG" \
  --arg tier "$TIER" \
  --arg sif "$SIF" \
  --arg msg_id "$MSG_ID" \
  --arg wrapped "$WRAPPED" \
  --arg timestamp "$TIMESTAMP" \
  --argjson priority "$IS_PRIORITY" \
  '{ type: $type, from: $from, from_name: $from_name, tier: $tier, sif: $sif,
     msg_id: $msg_id, wrapped: $wrapped, timestamp: $timestamp,
     priority: $priority, read: false }')

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

# --- Structural notification only (no peer text) ---
if [ -f "$HOOK_DIR/notify.sh" ]; then
  # shellcheck source=notify.sh
  source "$HOOK_DIR/notify.sh"
  WHO="${NAMETAG:-${FROM_NPUB:0:14}…}"
  if [ "$IS_PRIORITY" = "true" ]; then
    notify "Unicity Agent: Priority DM" "From owner ${WHO} — run /check-messages" "critical"
  else
    notify "Unicity Agent: DM" "From ${WHO} [${TIER}] — run /check-messages" "normal"
  fi
fi

exit 0
