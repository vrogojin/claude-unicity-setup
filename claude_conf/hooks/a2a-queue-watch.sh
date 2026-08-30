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
# CHEAP + PORTABLE: a new arrival is detected by an ATOMIC per-item claim under a `seen/`
# marker dir (`mkdir` — the first watcher to create $scope-$id examines it; the rest skip).
# The scope prefix (wi-/ce-/te-) means a peer-supplied id in one queue cannot suppress a
# same-id item in another. This is filesystem-only (no bash-4 associative array → runs under
# stock macOS bash 3.2) and BOUNDED — old claims are reaped by mtime. CROSS-WATCHER: many
# sessions may each arm a watcher; the atomic claim guarantees a new id wakes EXACTLY ONE.
# A heartbeat file lets the SessionStart hook keep normally ONE watcher live (it re-arms only
# when the heartbeat goes stale).
set -uo pipefail

WATCH_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$WATCH_HOOK_DIR/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"

INTERVAL="${A2A_QUEUE_WATCH_INTERVAL:-3}"; case "$INTERVAL" in ''|0|*[!0-9]*) INTERVAL=3;; esac
WI_DIR="$STATE_DIR/agent-workitems"
CE_DIR="$STATE_DIR/agent-consult-events"
TE_DIR="$STATE_DIR/agent-team-events"
SEENDIR="$STATE_DIR/a2a-queue-watch-seen"   # atomic per-item claim: created = examined
HB="$STATE_DIR/a2a-queue-watch.heartbeat"
mkdir -p "$SEENDIR" 2>/dev/null || true
find "$SEENDIR" -maxdepth 1 -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null || true

# Queue table: "dir|scope|label|skill-hint". Indexed array (bash 3.2 safe); label may contain
# spaces, hint has no '|', so a single IFS='|' split is unambiguous.
QUEUES=(
  "$WI_DIR|wi|WORK request|/process-agent-requests"
  "$CE_DIR|ce|CONSULT|/coordinator-advise"
  "$TE_DIR|te|TEAM event|/team-work"
)

_is_queued() { [ -f "$1" ] && [ "$(jq -r '.status // "queued"' "$1" 2>/dev/null)" = "queued" ]; }

# Prime: claim everything currently present WITHOUT emitting — the SessionStart drain-once
# nudge already covers the at-start backlog; the watcher reports only NEW arrivals.
_prime() {
  local q dir scope label hint f id
  for q in "${QUEUES[@]}"; do
    IFS='|' read -r dir scope label hint <<< "$q"
    [ -d "$dir" ] || continue
    for f in "$dir"/*.json; do [ -e "$f" ] || continue
      id="$(basename "$f" .json)"
      mkdir "$SEENDIR/$scope-$id" 2>/dev/null || true
    done
  done
}
_prime

_scan() {
  local q dir scope label hint f id
  for q in "${QUEUES[@]}"; do
    IFS='|' read -r dir scope label hint <<< "$q"
    [ -d "$dir" ] || continue
    for f in "$dir"/*.json; do [ -e "$f" ] || continue
      id="$(basename "$f" .json)"
      # Atomic claim: if we cannot create the marker, this id was already examined (by us on a
      # prior tick, by prime, or by another watcher) → skip. First claimer of a NEW id proceeds.
      mkdir "$SEENDIR/$scope-$id" 2>/dev/null || continue
      # classify-inbound writes item files atomically (tmp+rename) already `queued`, so a first
      # sighting that is NOT queued is a done/other file we simply never emit for.
      _is_queued "$f" || continue
      printf 'A2A: new authorized %s queued (id %s) → run %s now\n' "$label" "$id" "$hint"
    done
  done
}

TICK=0
while :; do
  date -u +%s > "$HB" 2>/dev/null || true   # heartbeat: proves a watcher is live (SessionStart reads this)
  _scan
  # Periodic housekeeping for a long-lived watcher (~every 300 ticks): reap old claim markers
  # so the seen/ tree cannot grow without bound over days.
  TICK=$((TICK+1))
  if [ $(( TICK % 300 )) -eq 0 ]; then
    find "$SEENDIR" -maxdepth 1 -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
  fi
  sleep "$INTERVAL"
done
