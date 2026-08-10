#!/bin/bash
# classify-inbound.sh — the authorization router for inbound agent messages.
#
# Runs AFTER the daemon (on-dm.sh / on-group-message.sh) or the poll fallback
# (agent-comms-check.sh) has appended a message to the shared state file. It scans
# for any message that has not yet been classified (`.authz == null`) and, for each,
# decides — against the authorized-agents registry — what may happen with it:
#
#   owner       → left to the existing priority path (marked classified, untouched).
#   authorized  → stamped with the sender's granted capabilities AND enqueued as a
#                 WORK ITEM for the master session to dispatch to a capability-scoped
#                 subagent (a hook cannot itself spawn a Claude team agent).
#   pending/unknown → a pending registry entry is created (capturing the sender's
#                 intro text) and surfaced to the owner via agent-authz-pending.json,
#                 which the Stop gate (check-diagnostics.sh) blocks on. NOT acted upon.
#   denied      → marked and dropped. No surface, no work item, no action.
#
# DEFAULT-DENY: anything not explicitly `authorized` never produces a work item.
# INERT-safe: with an empty registry every agent message becomes a pending
# authorization request and nothing else happens until the owner decides.
#
# Idempotent: only messages with `.authz == null` are processed, and work items are
# keyed by a deterministic content hash, so repeated runs never double-process.
# Always exits 0 (never breaks a daemon hook).
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HOOK_DIR/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"
# Source the registry helpers (its CLI is guarded, so sourcing only defines funcs).
. "$HOOK_DIR/agent-registry.sh" 2>/dev/null || true
REGISTRY="$HOOK_DIR/agent-registry.sh"

STATE_FILE="$STATE_DIR/agent-messages.json"
PENDING_FILE="$STATE_DIR/agent-authz-pending.json"
WORKITEMS_DIR="$STATE_DIR/agent-workitems"
QUARANTINE_DIR="$STATE_DIR/agent-quarantine"
SIF_GUARD="$HOOK_DIR/sif-guard.sh"
LOCK="$STATE_FILE.classify.lock"
mkdir -p "$WORKITEMS_DIR" "$QUARANTINE_DIR" 2>/dev/null || true

# --- Resolve owner identity (to keep owner messages out of the agent pipeline) ---
CONFIG_FILE="${CLAUDE_PROJECT_DIR:-}"
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE/.claude/agent/config.json" ]; then
  CONFIG_FILE="$CONFIG_FILE/.claude/agent/config.json"
else
  CONFIG_FILE="$HOOK_DIR/../agent/config.json"
fi
OWNER_NPUB=""; OWNER_NAMETAG=""
if [ -f "$CONFIG_FILE" ]; then
  OWNER_NPUB=$(jq -r '.owner_npub // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
  OWNER_NAMETAG=$(jq -r '.owner_nametag // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
fi

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Rebuild the owner-facing pending-authorization surface from the registry (source
# of truth). Called at the end of every run so /authorize-agent + /deny-agent take
# effect immediately (the pending entry disappears from the Stop gate).
rebuild_pending_surface() {
  local items count tmp
  items="$(bash "$REGISTRY" list pending 2>/dev/null || echo '[]')"
  [ -n "$items" ] || items='[]'
  tmp="$PENDING_FILE.tmp.$$"
  if jq -n --argjson items "$items" --arg now "$(now_iso)" \
       '{count: ($items|length), pending: $items, updated_at: $now}' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$PENDING_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

# Enqueue a work item for an authorized sender (deterministic id ⇒ no duplicates).
enqueue_workitem() {  # args: from ts body type group name npub caps_json [skill]
  local from="$1" ts="$2" body="$3" type="$4" group="$5" name="$6" npub="$7" caps="$8" skill="${9:-}"
  local id wf
  id="$(printf '%s|%s|%s' "$from" "$ts" "$body" | sha1sum 2>/dev/null | cut -c1-16)"
  [ -n "$id" ] || return 0
  wf="$WORKITEMS_DIR/$id.json"
  [ -f "$wf" ] && return 0   # already queued (or already processed & left in place)
  jq -nc --arg id "$id" --arg from "$from" --arg npub "$npub" --arg name "$name" \
     --argjson caps "$caps" --arg type "$type" --arg group "$group" \
     --arg body "$body" --arg ts "$ts" --arg skill "$skill" --arg now "$(now_iso)" \
     '{id:$id, status:"queued", from_pubkey:$from, did:("did:nostr:"+$from), npub:$npub,
       unicityName:$name, capabilities:$caps, requestedSkill:$skill, type:$type,
       group:$group, body:$body, receivedAt:$ts, classifiedAt:$now}' > "$wf.tmp.$$" 2>/dev/null \
     && mv "$wf.tmp.$$" "$wf" 2>/dev/null || rm -f "$wf.tmp.$$" 2>/dev/null || true
}

# Quarantine an authorized message the content-guard (SIF) flagged: it is NOT dispatched.
# Recorded for owner review; deterministic id ⇒ no duplicates.
quarantine_message() {  # args: from ts body type group name npub sif_verdict_json
  local from="$1" ts="$2" body="$3" type="$4" group="$5" name="$6" npub="$7" sif="$8"
  local id qf
  id="$(printf '%s|%s|%s' "$from" "$ts" "$body" | sha1sum 2>/dev/null | cut -c1-16)"
  [ -n "$id" ] || return 0
  qf="$QUARANTINE_DIR/$id.json"
  [ -f "$qf" ] && return 0
  echo "$sif" | jq -e . >/dev/null 2>&1 || sif='{}'
  jq -nc --arg id "$id" --arg from "$from" --arg npub "$npub" --arg name "$name" \
     --arg type "$type" --arg group "$group" --arg body "$body" --arg ts "$ts" \
     --argjson sif "$sif" --arg now "$(now_iso)" \
     '{id:$id, status:"quarantined", from_pubkey:$from, did:("did:nostr:"+$from), npub:$npub,
       unicityName:$name, type:$type, group:$group, body:$body, receivedAt:$ts,
       quarantinedAt:$now, sif:$sif}' > "$qf.tmp.$$" 2>/dev/null \
     && mv "$qf.tmp.$$" "$qf" 2>/dev/null || rm -f "$qf.tmp.$$" 2>/dev/null || true
}

# Nothing to scan yet — still refresh the surface (reflects registry edits) and exit.
if [ ! -f "$STATE_FILE" ]; then
  rebuild_pending_surface
  exit 0
fi

UNCLASSIFIED="$(jq '[.messages[]? | select(.authz == null)] | length' "$STATE_FILE" 2>/dev/null || echo 0)"
if ! [ "$UNCLASSIFIED" -gt 0 ] 2>/dev/null; then
  rebuild_pending_surface
  exit 0
fi

TOTAL="$(jq '.messages | length' "$STATE_FILE" 2>/dev/null || echo 0)"
STAMPS='[]'   # [{from, ts, body, authz}] — applied to the file under lock at the end.

i=0
while [ "$i" -lt "$TOTAL" ]; do
  MSG="$(jq -c ".messages[$i]" "$STATE_FILE" 2>/dev/null)"
  i=$((i+1))
  [ -n "$MSG" ] || continue
  [ "$(echo "$MSG" | jq -r '.authz // "null"')" = "null" ] || continue

  FROM="$(echo "$MSG" | jq -r '.from // ""')"
  FROMNAME="$(echo "$MSG" | jq -r '.from_name // ""')"
  BODY="$(echo "$MSG" | jq -r '.body // ""')"
  TS="$(echo "$MSG" | jq -r '.timestamp // ""')"
  TYPE="$(echo "$MSG" | jq -r '.type // ""')"
  GROUP="$(echo "$MSG" | jq -r '.group.name // ""')"
  PRI="$(echo "$MSG" | jq -r '.priority // false')"

  # --- Optional A2A-over-Nostr envelope --------------------------------------
  # The interop direction is A2A schema carried over Nostr. If the body is a JSON
  # object, leniently pull a CLAIMED agent name, a requested skill (→ maps onto our
  # capability enum), and a human-readable message. Plain-text bodies fall through.
  # The claimed name is display/intent only — NEVER an identity (that is the pubkey).
  CLAIMED_NAME="$FROMNAME"
  REQ_SKILL=""
  DISPLAY_BODY="$BODY"
  if echo "$BODY" | jq -e 'type=="object"' >/dev/null 2>&1; then
    ENV_NAME="$(echo "$BODY" | jq -r '(.from // .agentCard.name // .agent.name // .name // "") | tostring' 2>/dev/null)"
    REQ_SKILL="$(echo "$BODY" | jq -r '(.skill // .capability // .skillId // .method // "") | tostring' 2>/dev/null)"
    ENV_MSG="$(echo "$BODY" | jq -r '(.message.text // .message // .task.text // .task // .text // "") | if type=="object" then tojson else tostring end' 2>/dev/null)"
    [ "$REQ_SKILL" = "null" ] && REQ_SKILL=""
    { [ -z "$CLAIMED_NAME" ] && [ -n "$ENV_NAME" ] && [ "$ENV_NAME" != "null" ]; } && CLAIMED_NAME="$ENV_NAME"
    { [ -n "$ENV_MSG" ] && [ "$ENV_MSG" != "null" ]; } && DISPLAY_BODY="$ENV_MSG"
  fi

  AUTHZJSON=""

  # --- Owner: never enters the agent-authorization pipeline ---
  if [ "$PRI" = "true" ] \
     || { [ -n "$OWNER_NPUB" ] && [ "$FROM" = "$OWNER_NPUB" ]; } \
     || { [ -n "$OWNER_NAMETAG" ] && [ "$FROMNAME" = "$OWNER_NAMETAG" ]; }; then
    AUTHZJSON='{"role":"owner","status":"authorized","classified":true}'
  else
    [ -n "$FROM" ] || FROM="unknown"
    ST="$(bash "$REGISTRY" status "$FROM" 2>/dev/null || echo unknown)"
    case "$ST" in
      authorized)
        ENTRY="$(bash "$REGISTRY" get "$FROM" 2>/dev/null || echo '{}')"
        NAME="$(echo "$ENTRY" | jq -r '.unicityName // ""')"
        NPUB="$(echo "$ENTRY" | jq -r '.npub // ""')"
        CAPS="$(echo "$ENTRY" | jq -c '.capabilities // []')"
        # Content-guard (SIF) BEFORE dispatch — mirror the concierge backend's fail-closed
        # ingestion guard. A flagged (or fail-closed guard-error) body is QUARANTINED and
        # never dispatched; a clean body is queued for the capability-scoped processor.
        SIF_Q=0
        if [ -f "$SIF_GUARD" ]; then
          # NB: sif-guard exits 10 on quarantine (0 on pass). Capture stdout via $() —
          # which ignores the exit code — and do NOT chain `|| echo` (a non-zero exit is
          # the quarantine signal, not a failure, and would corrupt the captured JSON).
          SIF_OUT="$(printf '%s' "$DISPLAY_BODY" | bash "$SIF_GUARD" check --direction inbound --principal "$FROM" --source agent-comms 2>/dev/null)"
          [ -n "$SIF_OUT" ] || SIF_OUT='{}'
          [ "$(echo "$SIF_OUT" | jq -r '.decision // "pass"' 2>/dev/null)" = "quarantine" ] && SIF_Q=1
        fi
        if [ "$SIF_Q" = "1" ]; then
          quarantine_message "$FROM" "$TS" "$DISPLAY_BODY" "$TYPE" "$GROUP" "$NAME" "$NPUB" "$SIF_OUT"
        else
          enqueue_workitem "$FROM" "$TS" "$DISPLAY_BODY" "$TYPE" "$GROUP" "$NAME" "$NPUB" "$CAPS" "$REQ_SKILL"
        fi
        AUTHZJSON="$(jq -nc --arg name "$NAME" --argjson caps "$CAPS" --arg skill "$REQ_SKILL" --argjson q "$SIF_Q" \
          '{role:"agent", status:"authorized", unicityName:$name, capabilities:$caps, requestedSkill:$skill, sifQuarantined:($q==1), classified:true}')"
        ;;
      denied)
        AUTHZJSON='{"role":"agent","status":"denied","classified":true}'
        ;;
      *)  # pending | unknown | peer → queue for owner authorization, act on nothing
        # Impersonation guard: a message CLAIMING a name already tied to a DIFFERENT
        # pubkey is a possible impersonation. We surface the discrepancy to the owner and
        # keep it pending — the claimed name never grants anything; only the pubkey does.
        SUSPECT=""
        if [ -n "$CLAIMED_NAME" ]; then
          SUSPECT="$(bash "$REGISTRY" find-name "$CLAIMED_NAME" 2>/dev/null \
            | jq -r --arg me "$FROM" '[ .[] | select(.pubkey != $me) ] | (first.pubkey // "")' 2>/dev/null || echo "")"
        fi
        EXTRA=()
        [ -n "$REQ_SKILL" ] && EXTRA+=(--skill "$REQ_SKILL")
        [ -n "$SUSPECT" ] && EXTRA+=(--suspect-of "$SUSPECT")
        bash "$REGISTRY" upsert-pending --pubkey "$FROM" --name "$CLAIMED_NAME" \
          --intro "$DISPLAY_BODY" --type "$TYPE" --group "$GROUP" \
          ${EXTRA[@]+"${EXTRA[@]}"} >/dev/null 2>&1 || true
        NAME2="$(bash "$REGISTRY" get "$FROM" 2>/dev/null | jq -r '.unicityName // ""' 2>/dev/null || echo "")"
        AUTHZJSON="$(jq -nc --arg name "$NAME2" --arg suspect "$SUSPECT" \
          '{role:"agent", status:"pending", unicityName:$name, impersonationSuspect:($suspect!=""), classified:true}')"
        ;;
    esac
  fi

  STAMPS="$(echo "$STAMPS" | jq -c --arg from "$FROM" --arg ts "$TS" --arg body "$BODY" \
    --argjson authz "$AUTHZJSON" '. + [{from:$from, ts:$ts, body:$body, authz:$authz}]')"
done

# --- Apply authz stamps to the message file atomically (match by content, not index,
#     so a concurrent append by the daemon is never clobbered) ---
if [ "$(echo "$STAMPS" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
  (
    flock -w 5 9 2>/dev/null || true
    if [ -f "$STATE_FILE" ]; then
      TMP="$STATE_FILE.tmp.$$"
      if jq --argjson stamps "$STAMPS" '
        .messages |= map(
          . as $m
          | if ($m.authz != null) then $m
            else
              ([ $stamps[]
                 | select(.from == $m.from and .ts == $m.timestamp and .body == $m.body)
                 | .authz ] | first) as $a
              | if $a then ($m + {authz:$a}) else $m end
            end)
      ' "$STATE_FILE" > "$TMP" 2>/dev/null; then
        mv "$TMP" "$STATE_FILE"
      else
        rm -f "$TMP" 2>/dev/null || true
      fi
    fi
  ) 9>"$LOCK"
fi

rebuild_pending_surface
exit 0
