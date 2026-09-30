#!/bin/bash
# Daemon hook: called by sphere-sdk daemon when a group message arrives.
# Receives message JSON on stdin. Filters own messages, appends to state file, notifies.
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
GROUP_ID=$(echo "$MSG_JSON" | jq -r '.tags[] | select(.[0] == "h") | .[1] // empty' 2>/dev/null || echo "")
GROUP_NAME=$(echo "$MSG_JSON" | jq -r '.group_name // "UNICITY_DEV_AGENTS"')

# Filter out own messages
OWN_NPUB=""
if [ -f "$IDENTITY_FILE" ]; then
  OWN_NPUB=$(jq -r '.npub // ""' "$IDENTITY_FILE" 2>/dev/null)
fi
if [ -n "$OWN_NPUB" ] && [ "$SENDER" = "$OWN_NPUB" ]; then
  exit 0
fi

# Convert unix timestamp to ISO if numeric
if [[ "$TIMESTAMP" =~ ^[0-9]+$ ]]; then
  TIMESTAMP=$(date -u -d "@$TIMESTAMP" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    date -u -r "$TIMESTAMP" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    echo "$TIMESTAMP")
fi
TIMESTAMP="${TIMESTAMP:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

# Check if sender is owner (priority)
OWNER_NPUB=""
IS_PRIORITY=false
if [ -f "$CONFIG_FILE" ]; then
  OWNER_NPUB=$(jq -r '.owner_npub // ""' "$CONFIG_FILE" 2>/dev/null)
  if [ -n "$OWNER_NPUB" ] && [ "$SENDER" = "$OWNER_NPUB" ]; then
    IS_PRIORITY=true
  fi
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

# Cap retained history to the newest N (default 500) so the shared state file can't grow
# unbounded — see agent-comms-check.sh for the leak this prevents (AGENT_MESSAGES_MAX overrides).
CAP="${AGENT_MESSAGES_MAX:-500}"; case "$CAP" in ''|*[!0-9]*) CAP=500 ;; esac

# Append to state file (create if missing), atomically and under a lock shared with
# on-dm.sh (same STATE_FILE, same lock name) — a DM and a group message can arrive
# at the same moment and each spawns its own hook process, so an unlocked
# read-modify-write here races with on-dm.sh's, not just with itself.
#
# The lock is released (fd 9 closed) as soon as the write is done, BEFORE notify/
# classify-inbound run below, so a slow notify/classify can't hold a concurrent
# invocation hostage until ITS OWN lock timeout.
DEFAULT_STATE='{"unread": false, "unread_count": 0, "priority_count": 0, "messages": []}'
LOCK="$STATE_FILE.lock"

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock -w 5 9 || { echo "on-group-message.sh: lock timeout on $STATE_FILE — dropping this message rather than risk a corrupt write" >&2; exit 0; }
fi

# Read CURRENT fresh, now that we hold the lock. NEVER trust a file that fails to
# parse as JSON — jq on invalid input produces empty stdout, and blindly writing
# that back (the previous bug here, shared with on-dm.sh) truncates the whole state
# file to a stray newline, which then fails every SUBSEQUENT read forever.
if [ -f "$STATE_FILE" ] && CURRENT=$(cat "$STATE_FILE") && jq -e . >/dev/null 2>&1 <<<"$CURRENT"; then
  :
else
  [ -f "$STATE_FILE" ] && echo "on-group-message.sh: $STATE_FILE was missing or invalid JSON — resetting it (previous content, if any, is lost)" >&2
  CURRENT="$DEFAULT_STATE"
fi

UPDATED=$(jq \
  --argjson msg "$NEW_MSG" \
  --argjson is_priority "$IS_PRIORITY" \
  --argjson cap "$CAP" \
  '.messages += [$msg] |
   .unread = true |
   .unread_count = (.unread_count + 1) |
   .priority_count = (if $is_priority then .priority_count + 1 else .priority_count end) |
   .messages |= .[-$cap:]' \
  <<<"$CURRENT") || UPDATED=""

# Only ever replace the file with something jq actually produced.
if [ -n "$UPDATED" ] && jq -e . >/dev/null 2>&1 <<<"$UPDATED"; then
  TMP="$STATE_FILE.tmp.$$"
  echo "$UPDATED" > "$TMP" && mv "$TMP" "$STATE_FILE"
else
  echo "on-group-message.sh: failed to build updated state (jq error) — leaving $STATE_FILE untouched, message dropped" >&2
fi

if command -v flock >/dev/null 2>&1; then exec 9>&-; fi

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

# Route the just-appended message through the authorization classifier (DEFAULT-DENY).
# Guarded so a classifier failure can never break this daemon hook.
if [ -f "$HOOK_DIR/classify-inbound.sh" ]; then
  bash "$HOOK_DIR/classify-inbound.sh" >/dev/null 2>&1 || true
fi

exit 0
