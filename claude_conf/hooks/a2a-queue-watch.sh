#!/bin/bash
# a2a-queue-watch.sh — EVENT-DRIVEN A2A queue watcher (armed via the Monitor tool, persistent).
#
# Emits ONE stdout line the moment a NEW authorized item is QUEUED — in the work-item queue
# (DMs → /process-agent-requests) OR the coordination queues (consults → /coordinator-advise,
# team events → /team-work). Silent the rest of the time, so a session is woken to dispatch
# ONLY when real work arrives: ZERO model cost while the queue is quiet, and NO unconditional
# interval that runs a skill regardless of queue state (the owner rejected that).
#
# WATCHES ONLY. It reports the queue + id (never message bodies, never the registry, never
# secrets) and never dispatches. DEFAULT-DENY holds upstream: classify-inbound only ever
# enqueues an item for an `authorized` peer, so a queued id is by construction an authorized
# request. The capability-scoped processor in the skill remains the sole executor.
#
# CHEAP IDLE PATH: a new arrival is detected by NEW FILENAME — classify-inbound creates each
# item file already `queued`, so the steady state is just three directory listings per tick;
# jq runs only when a file is genuinely new. CROSS-WATCHER DEDUP: many sessions may each arm a
# watcher; an atomic per-id claim (mkdir under a2a-queue-watch-notified/, keyed <scope>-<id> so
# a peer-supplied id in one queue cannot suppress a same-id item in another) guarantees a new
# id wakes EXACTLY ONE session, not all of them. A heartbeat file lets the SessionStart hook
# keep normally ONE watcher live (it only arms a new one when the heartbeat goes stale).
#
# Requires bash 4+ (associative array), as sibling hooks (serena-reaper.sh) already do.
set -uo pipefail

WATCH_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$WATCH_HOOK_DIR/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"

INTERVAL="${A2A_QUEUE_WATCH_INTERVAL:-3}"; case "$INTERVAL" in ''|0|*[!0-9]*) INTERVAL=3;; esac
WI_DIR="$STATE_DIR/agent-workitems"
CE_DIR="$STATE_DIR/agent-consult-events"
TE_DIR="$STATE_DIR/agent-team-events"
NOTIFIED="$STATE_DIR/a2a-queue-watch-notified"
HB="$STATE_DIR/a2a-queue-watch.heartbeat"
mkdir -p "$NOTIFIED" 2>/dev/null || true
find "$NOTIFIED" -maxdepth 1 -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null || true

declare -A SEEN   # filenames already examined by THIS process → jq only genuinely-new files

_is_queued() { [ -f "$1" ] && [ "$(jq -r '.status // "queued"' "$1" 2>/dev/null)" = "queued" ]; }

# Prime: mark everything currently present as seen WITHOUT emitting — the SessionStart
# drain-once nudge already covers the at-start backlog; the watcher reports only NEW arrivals.
_prime() {
  local d f
  for d in "$WI_DIR" "$CE_DIR" "$TE_DIR"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.json; do [ -e "$f" ] || continue; SEEN["$f"]=1; done
  done
}
_prime

_scan() {  # <dir> <scope> <label> <skill-hint>
  local d="$1" scope="$2" label="$3" hint="$4" f id
  [ -d "$d" ] || return 0
  for f in "$d"/*.json; do
    [ -e "$f" ] || continue
    [ -n "${SEEN["$f"]:-}" ] && continue   # already examined this process
    SEEN["$f"]=1
    _is_queued "$f" || continue            # only newly-QUEUED items
    id="$(basename "$f" .json)"
    # First watcher to claim the scope-keyed id emits; the rest stay quiet (one wake per id).
    if mkdir "$NOTIFIED/$scope-$id" 2>/dev/null; then
      printf 'A2A: new authorized %s queued (id %s) → run %s now\n' "$label" "$id" "$hint"
    fi
  done
}

TICK=0
while :; do
  date -u +%s > "$HB" 2>/dev/null || true   # heartbeat: proves a watcher is live (SessionStart reads this)
  _scan "$WI_DIR" "wi" "WORK request" "/process-agent-requests"
  _scan "$CE_DIR" "ce" "CONSULT"      "/coordinator-advise"
  _scan "$TE_DIR" "te" "TEAM event"   "/team-work"
  # Periodic housekeeping for a long-lived watcher (~every 300 ticks): reap old dedup claims
  # and drop SEEN entries whose file is gone, so neither grows without bound over days.
  TICK=$((TICK+1))
  if [ $(( TICK % 300 )) -eq 0 ]; then
    find "$NOTIFIED" -maxdepth 1 -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
    for k in "${!SEEN[@]}"; do [ -e "$k" ] || unset "SEEN[$k]"; done
  fi
  sleep "$INTERVAL"
done
