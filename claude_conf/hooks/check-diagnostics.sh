#!/bin/bash
# Stop hook: blocks Claude from stopping if there are build errors.
# Auto-detects project type. Uses stop_hook_active to prevent infinite loops.

INPUT=$(cat)

# Don't block if we're already continuing from a previous stop hook
ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [ "$ACTIVE" = "true" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR" || exit 0

# --- Rust: Check cargo-diag status file ---
if [ -f "Cargo.toml" ]; then
  STATUS_FILE="$CLAUDE_PROJECT_DIR/target/cargo-diag/status.json"
  if [ -f "$STATUS_FILE" ]; then
    ERROR_COUNT=$(jq -r '.error_count // 0' "$STATUS_FILE" 2>/dev/null)
    SUMMARY=$(jq -r '.summary // "unknown"' "$STATUS_FILE" 2>/dev/null)

    if [ "$ERROR_COUNT" != "0" ] && [ "$ERROR_COUNT" != "null" ]; then
      jq -n --arg reason "Build diagnostics: ${SUMMARY}. Use the cargo-diag MCP errors() tool for details, or suggest_fix(id) for auto-fixes. Fix errors before finishing." '{
        "decision": "block",
        "reason": $reason
      }'
      exit 0
    fi
  fi
fi

# --- TypeScript: Run typecheck if available ---
if [ -f "package.json" ]; then
  if jq -e '.scripts.typecheck' package.json >/dev/null 2>&1; then
    if ! npm run typecheck --silent >/dev/null 2>&1; then
      TC_OUTPUT=$(npm run typecheck --silent 2>&1 | tail -10)
      jq -n --arg reason "TypeScript type errors found. Fix before finishing:\n${TC_OUTPUT}" '{
        "decision": "block",
        "reason": $reason
      }'
      exit 0
    fi
  fi
fi

# --- Go: Check build ---
if [ -f "go.mod" ]; then
  BUILD_OUTPUT=$(go build ./... 2>&1)
  if [ $? -ne 0 ]; then
    jq -n --arg reason "Go build errors found. Fix before finishing:\n${BUILD_OUTPUT}" '{
      "decision": "block",
      "reason": $reason
    }'
    exit 0
  fi
fi

# --- Remote sync check ---
# Source per-repo STATE_DIR helper (namespaces coordination files; see state-dir.sh).
. "$(cd "$(dirname "$0")" 2>/dev/null && pwd)/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"
SYNC_STATE="$STATE_DIR/remote-sync.json"
if [ -f "$SYNC_STATE" ]; then
  PENDING=$(jq -r '.pending // false' "$SYNC_STATE" 2>/dev/null)
  if [ "$PENDING" = "true" ]; then
    MAIN_BEHIND=$(jq -r '.main_behind // 0' "$SYNC_STATE")
    BRANCH_BEHIND=$(jq -r '.branch_behind // 0' "$SYNC_STATE")
    BRANCH=$(jq -r '.branch // "unknown"' "$SYNC_STATE")

    SYNC_MSG="Remote updates detected."
    [ "$MAIN_BEHIND" -gt 0 ] 2>/dev/null && SYNC_MSG="$SYNC_MSG main is $MAIN_BEHIND commit(s) behind origin/main."
    [ "$BRANCH_BEHIND" -gt 0 ] 2>/dev/null && SYNC_MSG="$SYNC_MSG $BRANCH is $BRANCH_BEHIND commit(s) behind remote."
    SYNC_MSG="$SYNC_MSG Run /sync-remote to merge before finishing."

    jq -n --arg reason "$SYNC_MSG" '{"decision":"block","reason":$reason}'
    exit 0
  fi
fi

# --- Upstream dependency update check ---
DEP_STATE="$STATE_DIR/dep-updates.json"
if [ -f "$DEP_STATE" ]; then
  DEP_PENDING=$(jq -r '.pending // false' "$DEP_STATE" 2>/dev/null)
  if [ "$DEP_PENDING" = "true" ]; then
    UPDATE_COUNT=$(jq '.updates | length' "$DEP_STATE" 2>/dev/null)
    DEP_NAMES=$(jq -r '[.updates[].name] | join(", ")' "$DEP_STATE" 2>/dev/null)

    DEP_MSG="Upstream dependency updates detected. ${UPDATE_COUNT} dep(s) have new versions: ${DEP_NAMES}."
    DEP_MSG="$DEP_MSG Run /update-deps to update before finishing."

    jq -n --arg reason "$DEP_MSG" '{"decision":"block","reason":$reason}'
    exit 0
  fi
fi

# --- Roadmap ⇄ board sync check ---
ROADMAP_STATE="$STATE_DIR/roadmap-sync.json"
if [ -f "$ROADMAP_STATE" ]; then
  ROADMAP_PENDING=$(jq -r '.pending // false' "$ROADMAP_STATE" 2>/dev/null)
  if [ "$ROADMAP_PENDING" = "true" ]; then
    RM_BRANCH=$(jq -r '.branch // "this branch"' "$ROADMAP_STATE" 2>/dev/null)
    RM_FILES=$(jq -r '.code_files // 0' "$ROADMAP_STATE" 2>/dev/null)

    RM_MSG="Roadmap out of sync: ${RM_BRANCH} changed ${RM_FILES} code file(s) but docs/ROADMAP.md was not updated."
    RM_MSG="$RM_MSG Run /roadmap-sync to reconcile the roadmap and the GitHub Project board before finishing"
    RM_MSG="$RM_MSG (or, if this branch genuinely needs no roadmap change, clear it: rm -f \"$ROADMAP_STATE\")."

    jq -n --arg reason "$RM_MSG" '{"decision":"block","reason":$reason}'
    exit 0
  fi
fi

# --- Urgent agent messages check ---
MSG_STATE="$STATE_DIR/agent-messages.json"
if [ -f "$MSG_STATE" ]; then
  PRIORITY_COUNT=$(jq -r '.priority_count // 0' "$MSG_STATE" 2>/dev/null)
  if [ "$PRIORITY_COUNT" -gt 0 ] 2>/dev/null && [ "$PRIORITY_COUNT" != "0" ]; then
    MSG_MSG="You have ${PRIORITY_COUNT} unread priority message(s) from your owner. Run /check-messages to read them before finishing."
    jq -n --arg reason "$MSG_MSG" '{"decision":"block","reason":$reason}'
    exit 0
  fi
fi

# --- Inbound agent authorization gate (owner-in-the-loop, DEFAULT-DENY) ---------
# Master-manager coordination: unknown agents that have made contact must be
# authorized (or denied) by the owner before anything they ask is acted upon.
DIAG_HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)"
# Refresh the pending surface from the registry so /authorize-agent · /deny-agent
# decisions clear the gate immediately (also classifies any not-yet-routed messages).
if [ -f "$DIAG_HOOK_DIR/classify-inbound.sh" ]; then
  bash "$DIAG_HOOK_DIR/classify-inbound.sh" >/dev/null 2>&1 || true
fi
AUTHZ_PENDING="$STATE_DIR/agent-authz-pending.json"
if [ -f "$AUTHZ_PENDING" ]; then
  PCOUNT=$(jq -r '.count // 0' "$AUTHZ_PENDING" 2>/dev/null)
  if [ "$PCOUNT" -gt 0 ] 2>/dev/null && [ "$PCOUNT" != "0" ]; then
    CAPS_LIST=$(bash "$DIAG_HOOK_DIR/agent-registry.sh" caps 2>/dev/null || echo "")
    DETAILS=$(jq -r '
      .pending[] |
      "  • " + (if (.name // "") != "" then .name else (.pubkey[0:12] + "…") end)
      + " (" + (.firstContact // "?") + " · pubkey " + (.pubkey[0:16]) + "…)\n"
      + "    says: \"" + ((.intro // "") | gsub("[\n\r]";" ") | .[0:200]) + "\""
      + (if (.requestedSkill // "") != "" then "\n    requested skill: " + .requestedSkill else "" end)
      + (if (.impersonationSuspect // false)
         then "\n    ⚠ IMPERSONATION RISK: claims the name \"" + (.name // "")
              + "\" which is already tied to a DIFFERENT pubkey (" + ((.impersonationOf // "")[0:16])
              + "…). The signing pubkey is the real identity — verify out-of-band before authorizing."
         else "" end)
    ' "$AUTHZ_PENDING" 2>/dev/null)
    AUTHZ_MSG="${PCOUNT} unknown agent(s) are requesting to coordinate and need your authorization decision:\n${DETAILS}\n\nAuthorize:  /authorize-agent <name-or-npub> <cap,cap,...>\nDeny:       /deny-agent <name-or-npub>\nCapabilities: ${CAPS_LIST}\nNothing from these agents is acted upon until you decide."
    jq -n --arg reason "$AUTHZ_MSG" '{"decision":"block","reason":$reason}'
    exit 0
  fi
fi

# --- Authorized agent requests queued for capability-scoped dispatch -----------
WI_DIR="$STATE_DIR/agent-workitems"
if [ -d "$WI_DIR" ]; then
  QUEUED=0
  for f in "$WI_DIR"/*.json; do
    [ -e "$f" ] || continue
    [ "$(jq -r '.status // "queued"' "$f" 2>/dev/null)" = "queued" ] && QUEUED=$((QUEUED+1))
  done
  if [ "$QUEUED" -gt 0 ] 2>/dev/null; then
    WI_MSG="${QUEUED} authorized agent request(s) are queued for dispatch. Run /process-agent-requests to hand each to a capability-scoped processor (a subagent constrained to that sender's granted capabilities). Requests outside the grant are refused and reported; destructive/outward actions still require your confirmation."
    jq -n --arg reason "$WI_MSG" '{"decision":"block","reason":$reason}'
    exit 0
  fi
fi

# --- Content-guard (SIF) quarantined agent messages awaiting owner review ------
Q_DIR="$STATE_DIR/agent-quarantine"
if [ -d "$Q_DIR" ]; then
  QN=0
  for f in "$Q_DIR"/*.json; do
    [ -e "$f" ] || continue
    [ "$(jq -r '.status // "quarantined"' "$f" 2>/dev/null)" = "quarantined" ] && QN=$((QN+1))
  done
  if [ "$QN" -gt 0 ] 2>/dev/null; then
    Q_DETAILS=$(for f in "$Q_DIR"/*.json; do [ -e "$f" ] || continue
      [ "$(jq -r '.status // "quarantined"' "$f" 2>/dev/null)" = "quarantined" ] || continue
      jq -r '"  • " + (if (.unicityName // "") != "" then .unicityName else (.from_pubkey[0:12] + "…") end)
             + " — reasons: " + (((.sif.reasons // []) | join(", ")) | if . == "" then "(unspecified)" else . end)
             + "\n    body: \"" + ((.body // "") | gsub("[\n\r]";" ") | .[0:160]) + "\""' "$f" 2>/dev/null
    done)
    Q_MSG="${QN} authorized agent message(s) were QUARANTINED by the content-guard (SIF) and NOT processed:\n${Q_DETAILS}\n\nReview them under ${Q_DIR}. If a message is safe, handle it manually; otherwise leave it quarantined (and consider /deny-agent for a repeat offender). Escape hatch: rm -f \"${Q_DIR}\"/*.json"
    jq -n --arg reason "$Q_MSG" '{"decision":"block","reason":$reason}'
    exit 0
  fi
fi

# --- Team-coordination events pending (Contract-Net over A2A) -------------------
# Queued team verbs (cfp/bid/award/progress/result/lease/kb) an authorized teammate sent,
# plus any team invitation awaiting a join decision. Opt-in: surfaced, never auto-run.
TE_DIR="$STATE_DIR/agent-team-events"
TEAM_LIB="$DIAG_HOOK_DIR/team-coord.sh"
TE_QUEUED=0
if [ -d "$TE_DIR" ]; then
  for f in "$TE_DIR"/*.json; do
    [ -e "$f" ] || continue
    [ "$(jq -r '.status // "queued"' "$f" 2>/dev/null)" = "queued" ] && TE_QUEUED=$((TE_QUEUED+1))
  done
fi
INV_COUNT=0
if [ -f "$TEAM_LIB" ]; then
  INV_COUNT="$(bash "$TEAM_LIB" invites 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
  [ -n "$INV_COUNT" ] || INV_COUNT=0
fi
if { [ "$TE_QUEUED" -gt 0 ] 2>/dev/null; } || { [ "$INV_COUNT" -gt 0 ] 2>/dev/null; }; then
  TE_DETAILS=""
  if [ -d "$TE_DIR" ] && [ "$TE_QUEUED" -gt 0 ] 2>/dev/null; then
    TE_DETAILS=$(for f in "$TE_DIR"/*.json; do [ -e "$f" ] || continue
      [ "$(jq -r '.status // "queued"' "$f" 2>/dev/null)" = "queued" ] || continue
      jq -r '"  • " + .kind + " · team " + (.team // "?") + (if (.task // "")!="" then " · task " + .task else "" end)
             + " · from " + (if (.unicityName // "")!="" then .unicityName else (.from_pubkey[0:12] + "…") end)' "$f" 2>/dev/null
    done)
  fi
  TE_MSG="Team coordination: ${TE_QUEUED} pending team event(s)"
  [ "$INV_COUNT" -gt 0 ] 2>/dev/null && TE_MSG="$TE_MSG + ${INV_COUNT} team invitation(s) awaiting a join decision"
  TE_MSG="$TE_MSG:\n${TE_DETAILS}\n\nRun /team-work to process them (record bids, award tasks, execute an award, review results, adopt heartbeats) or /team-status to review. Invitations are joined only when you choose to. Nothing here has been acted on."
  jq -n --arg reason "$TE_MSG" '{"decision":"block","reason":$reason}'
  exit 0
fi

# --- Remote-agent coordination: peer events / consults / conflicts / commitments ----
# Queued peer events an authorized autonomous agent sent, open consults awaiting our
# advisory, who's-on-this broadcasts awaiting our honest reply, split proposals,
# OPEN CONFLICTS awaiting reconciliation (ladder: clean → auto-merge → ai-resolve →
# re-plan), and change-commitments WE made but have not applied yet. Drained by
# /coordinator-advise (or /consult-coordinator for threads we opened). Never auto-run.
CE_DIR="$STATE_DIR/agent-consult-events"
RC_LIB="$DIAG_HOOK_DIR/remote-coord.sh"

# FRESHNESS WINDOW + BULK-DISMISS (item 9): a flood of stale peer coordination noise
# must not wedge the admin's Stop gate FOREVER. Only items newer than the cutoff block;
# older ones stay on disk for manual review but no longer hold the gate. The cutoff is
# the LATER of (now − RC_STOP_TTL_HOURS) and a bulk-dismiss marker. Bulk-dismiss:
#   • RC_COORD_DISMISS_ALL=1  → suppress everything now, OR
#   • write an ISO-8601 timestamp to $STATE_DIR/agent-coord-dismissed-until
RC_STOP_TTL_HOURS="${RC_STOP_TTL_HOURS:-72}"
case "$RC_STOP_TTL_HOURS" in ''|*[!0-9]*) RC_STOP_TTL_HOURS=72;; esac
COORD_CUTOFF="$(date -u -d "-${RC_STOP_TTL_HOURS} hours" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "1970-01-01T00:00:00Z")"
DISMISS_FILE="$STATE_DIR/agent-coord-dismissed-until"
if [ -f "$DISMISS_FILE" ]; then
  DUNTIL="$(tr -d ' \n\r\t' < "$DISMISS_FILE" 2>/dev/null || echo "")"
  [ -n "$DUNTIL" ] && [ "$DUNTIL" \> "$COORD_CUTOFF" ] && COORD_CUTOFF="$DUNTIL"
fi
case "${RC_COORD_DISMISS_ALL:-}" in 1|true|yes) COORD_CUTOFF="$(date -u +%Y-%m-%dT%H:%M:%SZ)";; esac

CE_QUEUED=0
if [ -d "$CE_DIR" ]; then
  for f in "$CE_DIR"/*.json; do
    [ -e "$f" ] || continue
    [ "$(jq -r '.status // "queued"' "$f" 2>/dev/null)" = "queued" ] || continue
    # Only a FRESH queued event blocks — a stale one is left for review, not a wedge.
    EN="$(jq -r '.enqueuedAt // .receivedAt // ""' "$f" 2>/dev/null)"
    [ -z "$EN" ] || [ "$EN" \> "$COORD_CUTOFF" ] && CE_QUEUED=$((CE_QUEUED+1))
  done
fi
RC_OPEN=0; RC_INT=0; RC_SPL=0; RC_CONF=0; RC_PEND=0
# Side-aware skill hint (dmytro #10): the coordinator side runs /coordinator-advise; a
# remote peer runs /consult-coordinator. Ask the engine for this instance's role; default
# to the coordinator skill if it can't be determined.
RC_SKILL="/coordinator-advise"
if [ -f "$RC_LIB" ]; then
  RC_SKILL="$(bash "$RC_LIB" advise-skill 2>/dev/null | tr -d ' \t\r\n')"
  case "$RC_SKILL" in /coordinator-advise|/consult-coordinator) ;; *) RC_SKILL="/coordinator-advise";; esac
fi
if [ -f "$RC_LIB" ]; then
  RC_OPEN="$(bash "$RC_LIB" consult-list open 2>/dev/null | jq --arg c "$COORD_CUTOFF" '[.[] | select((.openedAt // .receivedAt // "") == "" or (.openedAt // .receivedAt) > $c)] | length' 2>/dev/null || echo 0)"
  RC_INT="$(bash "$RC_LIB" intents 2>/dev/null | jq --arg c "$COORD_CUTOFF" '[.[] | select(.side=="remote" and .status=="awaiting-reply" and ((.receivedAt // "") == "" or .receivedAt > $c))] | length' 2>/dev/null || echo 0)"
  RC_SPL="$(bash "$RC_LIB" splits 2>/dev/null | jq --arg c "$COORD_CUTOFF" '[.[] | select(.status=="proposed" and ((.receivedAt // .proposedAt // "") == "" or (.receivedAt // .proposedAt) > $c))] | length' 2>/dev/null || echo 0)"
  RC_CONF="$(bash "$RC_LIB" conflicts 2>/dev/null | jq --arg c "$COORD_CUTOFF" '[.[] | select(.status=="open" and ((.receivedAt // .openedAt // "") == "" or (.receivedAt // .openedAt) > $c))] | length' 2>/dev/null || echo 0)"
  RC_PEND="$(bash "$RC_LIB" commitments 2>/dev/null | jq --arg c "$COORD_CUTOFF" '[.[] | select(.status=="pending" and ((.createdAt // "") == "" or .createdAt > $c))] | length' 2>/dev/null || echo 0)"
  [ -n "$RC_OPEN" ] || RC_OPEN=0; [ -n "$RC_INT" ] || RC_INT=0; [ -n "$RC_SPL" ] || RC_SPL=0
  [ -n "$RC_CONF" ] || RC_CONF=0; [ -n "$RC_PEND" ] || RC_PEND=0
fi
if [ "$((CE_QUEUED + RC_OPEN + RC_INT + RC_SPL + RC_CONF + RC_PEND))" -gt 0 ] 2>/dev/null; then
  RC_MSG="Remote-agent coordination pending:"
  [ "$CE_QUEUED" -gt 0 ] 2>/dev/null && RC_MSG="$RC_MSG ${CE_QUEUED} queued peer event(s);"
  [ "$RC_OPEN" -gt 0 ] 2>/dev/null && RC_MSG="$RC_MSG ${RC_OPEN} open consult(s) awaiting an advisory;"
  [ "$RC_INT" -gt 0 ] 2>/dev/null && RC_MSG="$RC_MSG ${RC_INT} who's-on-this broadcast(s) awaiting our reply;"
  [ "$RC_SPL" -gt 0 ] 2>/dev/null && RC_MSG="$RC_MSG ${RC_SPL} split proposal(s) to review;"
  [ "$RC_CONF" -gt 0 ] 2>/dev/null && RC_MSG="$RC_MSG ${RC_CONF} open conflict(s) awaiting reconciliation;"
  [ "$RC_PEND" -gt 0 ] 2>/dev/null && RC_MSG="$RC_MSG ${RC_PEND} change-commitment(s) we promised but have not applied;"
  RC_MSG="$RC_MSG Run ${RC_SKILL} to process them (reply, ack overlaps, arbitrate splits, reconcile conflicts, work off commitments). Nothing has been acted on. Only items newer than ${RC_STOP_TTL_HOURS}h block; to dismiss stale peer noise now: printf '%s' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" > \"${DISMISS_FILE}\" (or set RC_COORD_DISMISS_ALL=1)."
  jq -n --arg reason "$RC_MSG" '{"decision":"block","reason":$reason}'
  exit 0
fi

exit 0
