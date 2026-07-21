#!/bin/bash
# Daemon hook: called for firewall NOTICES that need owner attention but must
# NEVER surface peer text (red-team F6). Two kinds:
#   { kind:"pending_contact", from_npub, count_held }  — unknown npub quarantined
#   { kind:"held", from_npub, tier, reason }           — SIF unreachable/degraded
#
# It records a STRUCTURAL notice into agent-messages.json (so /check-messages can
# report it) and sends a structural desktop/push notification. No excerpt, no
# body, no imperative peer-authored text is ever placed in the notice line.
# Always exits 0.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$HOOK_DIR/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"
STATE_FILE="$STATE_DIR/agent-messages.json"

mkdir -p "$STATE_DIR"

MSG_JSON=$(cat)
KIND=$(echo "$MSG_JSON" | jq -r '.kind // "notice"')
FROM_NPUB=$(echo "$MSG_JSON" | jq -r '.from_npub // "unknown"')
COUNT_HELD=$(echo "$MSG_JSON" | jq -r '.count_held // 0')
REASON=$(echo "$MSG_JSON" | jq -r '.reason // ""')
TIER=$(echo "$MSG_JSON" | jq -r '.tier // ""')
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Only allow a known enum of kinds and a bech32-shaped npub — defense against a
# malformed record injecting anything into the notice.
case "$KIND" in pending_contact|held) : ;; *) exit 0 ;; esac
if ! [[ "$FROM_NPUB" =~ ^npub1[0-9ac-hj-np-z]{20,90}$ ]]; then FROM_NPUB="unknown"; fi

NOTICE=$(jq -n \
  --arg kind "$KIND" --arg from "$FROM_NPUB" --arg reason "$REASON" \
  --arg tier "$TIER" --argjson count "$COUNT_HELD" --arg at "$NOW_ISO" \
  '{ kind: $kind, from_npub: $from, tier: $tier, reason: $reason, count_held: $count, at: $at }')

if [ -f "$STATE_FILE" ]; then CURRENT=$(cat "$STATE_FILE"); else
  CURRENT='{"unread": false, "unread_count": 0, "priority_count": 0, "messages": []}'
fi

UPDATED=$(echo "$CURRENT" | jq --argjson n "$NOTICE" \
  '.notices = ((.notices // []) + [$n]) |
   .pending_count = ((.notices // []) | map(select(.kind == "pending_contact")) | length) |
   .unread = true')
echo "$UPDATED" > "$STATE_FILE"

if [ -f "$HOOK_DIR/notify.sh" ]; then
  # shellcheck source=notify.sh
  source "$HOOK_DIR/notify.sh"
  SHORT="${FROM_NPUB:0:16}…"
  if [ "$KIND" = "pending_contact" ]; then
    notify "Unicity Agent: New contact request" \
      "From ${SHORT} (${COUNT_HELD} held). Review: /approve-contact or /deny-contact" "normal"
  else
    notify "Unicity Agent: Message held" \
      "A ${TIER} message is held (semanticd ${REASON}). Configure SIF to release." "normal"
  fi
fi

exit 0
