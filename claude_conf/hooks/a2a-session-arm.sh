#!/bin/bash
# a2a-session-arm.sh — SessionStart NUDGE: make a freshly-started session ACT on the
# authorized A2A queues (BOTH the DM/work-item queue AND the coordination queue), not just
# receive them.
#
# THE GAP IT CLOSES. The A2A pipeline already RECEIVES + QUEUES autonomously:
#   • daemon-session.sh   (SessionStart) holds the live relay subscription (RECEIVE).
#   • classify-inbound.sh authorizes (DEFAULT-DENY, via agent-registry.sh) + SIF-checks +
#     QUEUES: authorized 1:1 requests → agent-workitems/*.json; coordination verbs →
#     agent-consult-events/*.json (consults) + agent-team-events/*.json (team) (QUEUE).
#   • check-diagnostics.sh (Stop) BLOCKS idle while any authorized item is `queued`
#     — work-items → /process-agent-requests, consults/team → /coordinator-advise.
# What is missing is the IN-SESSION proactive lever: a hook CANNOT itself spawn the
# capability-scoped processor subagent (only the model can, via the skills), so a busy
# session would leave queued peer requests untouched until it tried to Stop. The consult
# queue is the one that bit in the field: it is serviced by /coordinator-advise, NOT
# /process-agent-requests, so a DM-only drain left consults sitting. This hook covers BOTH.
#
# TWO LEVERS, both zero-idle-cost:
#   (i)  DRAIN-ONCE — if anything is queued at SessionStart, nudge the session to run
#        /process-agent-requests (DMs) AND /coordinator-advise (consults) + /team-work now.
#   (ii) ARM AN EVENT-DRIVEN WATCHER — nudge the session to arm a persistent Monitor over
#        a2a-queue-watch.sh, which wakes the session ONLY when a NEW authorized item appears.
#        This is deliberately NOT an unconditional `/loop` interval that runs a skill every N
#        minutes regardless of queue state — that burns tokens + clutters the console while
#        idle. The watcher costs nothing while the queue is quiet.
#
# IT NUDGES ONLY. It never dispatches, never authorizes, never widens scope. DEFAULT-DENY and
# the capability-scoped processor remain the sole executors; destructive/outward asks
# (rebuild-reload-service, review-merge-pr) stay REQUEST-ONLY (owner confirms). It reads ONLY
# queue COUNTS + a heartbeat from $STATE_DIR — never message bodies, never the registry's
# authz decisions, never .env / .secrets / identity.json.
#
# SessionStart hooks cannot block; this always exits 0. Fail-open + quiet: any missing
# dependency (no framework, no STATE_DIR) → silent no-op.
#
# Env overrides:
#   A2A_SESSION_ARM_DISABLE=1        turn this hook off entirely
#   A2A_SESSION_ARM_WATCH=0          do NOT arm the event-driven watcher (default: arm it)
#   A2A_SESSION_ARM_WATCH_STALE=20   seconds before a watcher heartbeat is "stale" → re-arm
#   A2A_QUEUE_WATCH_INTERVAL=3       watcher poll seconds (used by a2a-queue-watch.sh)
set -uo pipefail

[ "${A2A_SESSION_ARM_DISABLE:-0}" = "1" ] && exit 0
# The headless cron drain servicer sets A2A_DAEMON_SESSION_SKIP=1; it must NOT be nudged (it
# IS the drain) — that would recurse. Same skip contract as daemon-session.sh.
[ "${A2A_DAEMON_SESSION_SKIP:-0}" = "1" ] && exit 0

ARM_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$ARM_HOOK_DIR/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"

# --- Read the SessionStart payload (stdin JSON: {session_id, source, cwd}) ---
ARM_STDIN=""
if [ ! -t 0 ]; then ARM_STDIN="$(cat 2>/dev/null || true)"; fi
_arm_field() { printf '%s' "$ARM_STDIN" | jq -r "$1 // \"\"" 2>/dev/null || echo ""; }

# Project dir: env first (always set for hooks), else the payload cwd, else derive.
PROJ="${CLAUDE_PROJECT_DIR:-}"
[ -n "$PROJ" ] || PROJ="$(_arm_field '.cwd')"
[ -n "$PROJ" ] || PROJ="$(cd "$ARM_HOOK_DIR/../.." 2>/dev/null && pwd || echo .)"

# Only nudge where the A2A framework is actually installed (mirror agent-comms-check.sh).
[ -f "$PROJ/.claude/agent/config.json" ] || exit 0

# Per-session debounce: arm each distinct session ONCE. SessionStart also fires on
# resume/clear/compact of the SAME session — do not re-inject the nudge every time.
# If session_id is ever absent the fallback is per-INVOCATION, so debounce is best-effort then.
SID="$(_arm_field '.session_id')"; [ -n "$SID" ] || SID="anon-$$"
SID_SAFE="$(printf '%s' "$SID" | tr -c 'A-Za-z0-9._-' '_')"
ARM_MARK_DIR="$STATE_DIR/agent-session-arm"
mkdir -p "$ARM_MARK_DIR" 2>/dev/null || true
find "$ARM_MARK_DIR" -maxdepth 1 -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null || true   # bounded
# Atomic once-per-session claim — mkdir can't race the way test-then-write can.
mkdir "$ARM_MARK_DIR/$SID_SAFE.d" 2>/dev/null || exit 0

# --- Best-effort: classify any leftover inbound so counts are fresh (idempotent, bounded).
if [ -f "$ARM_HOOK_DIR/classify-inbound.sh" ]; then
  timeout 6 bash "$ARM_HOOK_DIR/classify-inbound.sh" >/dev/null 2>&1 || true
fi

# --- Count queued AUTHORIZED items (COUNTS ONLY — never bodies). ---
# Only status=="queued" is counted; done/skipped/quarantined are ignored. classify-inbound
# only ever enqueues items for peers the registry marks `authorized`, so a queued item is by
# construction an authorized peer's request (DEFAULT-DENY is enforced upstream, not here).
_count_queued() {  # <dir>
  local dir="$1" n=0 f st
  [ -d "$dir" ] || { echo 0; return; }
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    st="$(jq -r '.status // "queued"' "$f" 2>/dev/null)"; [ "$st" = "queued" ] || continue
    n=$((n+1))
  done
  echo "$n"
}
WI="$(_count_queued "$STATE_DIR/agent-workitems")"
# No kind filter — mirror check-diagnostics' consult gate, which counts EVERY queued event in
# this dir (consult.request / conflict.open / split.propose / area.claim / peer.announce …).
CE="$(_count_queued "$STATE_DIR/agent-consult-events")"
TE="$(_count_queued "$STATE_DIR/agent-team-events")"
# Open consult THREADS tracked by remote-coord (beyond the per-event queue). Best-effort +
# bounded; 0 if the lib is absent or slow. NOTE: this covers the QUEUED INBOUND coordination
# sources (consult/team events + open consults). The Stop-gate ADDITIONALLY gates DERIVED
# coordination state (who's-on-this / splits / conflicts / unapplied commitments); those are
# advisory/TTL-dismissable and are intentionally NOT re-counted here (each is a separate
# remote-coord subprocess, too costly for every SessionStart) — the Stop-gate is their backstop.
RC_OPEN=0
if [ -f "$ARM_HOOK_DIR/remote-coord.sh" ]; then
  RC_OPEN="$(timeout 4 bash "$ARM_HOOK_DIR/remote-coord.sh" consult-list open 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
  case "$RC_OPEN" in ''|*[!0-9]*) RC_OPEN=0;; esac
fi
COORD=$(( CE + TE + RC_OPEN ))

# --- Should THIS session arm the event-driven watcher? ---
# Normally exactly ONE watcher runs per repo: it refreshes a heartbeat every tick, and a
# session only arms a new one when no live heartbeat is fresh. (If two sessions start within
# the stale window they may both arm briefly — harmless: the watcher's per-id claim still
# wakes only one session per new item.)
WATCH_ARM=0
if [ "${A2A_SESSION_ARM_WATCH:-1}" != "0" ] && [ -f "$ARM_HOOK_DIR/a2a-queue-watch.sh" ]; then
  STALE="${A2A_SESSION_ARM_WATCH_STALE:-20}"; case "$STALE" in ''|*[!0-9]*) STALE=20;; esac
  HB="$STATE_DIR/a2a-queue-watch.heartbeat"; FRESH=0
  if [ -f "$HB" ]; then
    HBT="$(cat "$HB" 2>/dev/null)"; case "$HBT" in ''|*[!0-9]*) HBT=0;; esac
    [ $(( $(date -u +%s) - HBT )) -lt "$STALE" ] 2>/dev/null && FRESH=1
  fi
  [ "$FRESH" = "0" ] && WATCH_ARM=1
fi

# Nothing queued and no watcher to arm → stay silent (Stop-gate is still the backstop).
if [ "$WI" -eq 0 ] 2>/dev/null && [ "$COORD" -eq 0 ] 2>/dev/null && [ "$WATCH_ARM" -eq 0 ] 2>/dev/null; then
  exit 0
fi

# --- Build the nudge (additionalContext the session reads and acts on). ---
LINES=""
_add() { LINES="${LINES}${LINES:+\n}$1"; }

_add "A2A AUTO-PROCESS (unattended peer servicing). This session has the A2A pipeline configured. Authorized-peer requests are received + queued automatically; you are the DISPATCHER a hook cannot be. Cover BOTH queues — DMs AND coordination (consults)."
if [ "$WI" -gt 0 ] 2>/dev/null; then
  _add "• ${WI} authorized 1:1 agent request(s) QUEUED now → run /process-agent-requests (each handed to a capability-scoped processor)."
fi
if [ "$COORD" -gt 0 ] 2>/dev/null; then
  _add "• ${COORD} coordination item(s) QUEUED (consults/claims/splits/conflicts + team events) → run /coordinator-advise, and /team-work for team events/invites. Do NOT let consults sit — they are serviced by /coordinator-advise, NOT /process-agent-requests."
fi
if [ "$WATCH_ARM" = "1" ]; then
  _add "• ARM THE EVENT-DRIVEN WATCHER so you are woken ONLY when a NEW authorized item appears (no idle polling): use the Monitor tool, persistent:true, command \"bash $ARM_HOOK_DIR/a2a-queue-watch.sh\", description \"A2A queue: new authorized items\". Each emitted line names the queue + the skill to run — on a WORK line run /process-agent-requests, on a CONSULT line run /coordinator-advise, on a TEAM line run /team-work. Do NOT set up an unconditional /loop that runs a skill on a timer regardless of queue state — the watcher already fires only on real arrivals."
fi
_add "SAFETY (do not weaken): DEFAULT-DENY — only authorized peers, only their granted capabilities, are ever dispatched, re-verified at dispatch. The capability-scoped processor is the ONLY executor and refuses out-of-scope asks. 'rebuild-reload-service' and 'review-merge-pr' (and anything destructive/outward) are REQUEST-ONLY: PROPOSE to the owner and STOP — never auto-execute. Never touch .env/.secrets/identity/registry."

jq -n --arg ctx "$(printf '%b' "$LINES")" \
  '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$ctx}}' 2>/dev/null || true
exit 0
