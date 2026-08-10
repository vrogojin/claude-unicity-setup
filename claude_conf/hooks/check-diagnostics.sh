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

exit 0
