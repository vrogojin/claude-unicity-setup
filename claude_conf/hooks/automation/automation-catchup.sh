#!/bin/bash
# automation-catchup.sh — SessionStart missed-run fallback (§2.5).
#
# The universal catch-up net under the native schedulers (cron has none; a
# systemd/schtasks timer can still miss while the host slept past its window).
# For each ENABLED schedulable job whose last run is older than its period + grace
# (default 26 h for a daily job):
#   • syncup      → fire it now in the background via run-job.sh (cheap,
#                   non-destructive, idempotent). run-job's own flock makes this a
#                   no-op if a native run is already in flight, and a fresh
#                   last-run (native catch-up already ran) keeps age < grace so we
#                   never double-fire.
#   • housekeeping→ do NOT auto-run mid-day (it competes with the human for CPU
#                   and the repo); only advise running it when convenient.
#
# Cooldown-marked (same pattern as remote-sync-check.sh) so it fires at most once
# per grace window. Advisory only; never blocks; always exits 0.
set -uo pipefail

AC_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
AC_HOOKS_PARENT="$(cd "$AC_HOOK_DIR/.." 2>/dev/null && pwd || echo .)"
. "$AC_HOOKS_PARENT/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"

[ -t 0 ] || cat >/dev/null 2>&1 || true
command -v jq >/dev/null 2>&1 || exit 0

PROJ="${CLAUDE_PROJECT_DIR:-}"
[ -n "$PROJ" ] || PROJ="$(cd "$AC_HOOK_DIR/../../.." 2>/dev/null && pwd || echo "")"
CONFIG="$PROJ/.claude/agent/config.json"
[ -f "$CONFIG" ] || exit 0
RUN_JOB="$AC_HOOK_DIR/run-job.sh"
AUTO="$STATE_DIR/automation"; mkdir -p "$AUTO" 2>/dev/null || true

GRACE_HOURS="${AUTOMATION_CATCHUP_GRACE_HOURS:-26}"
NOW="$(date +%s)"
_cfg() { jq -r "$1" "$CONFIG" 2>/dev/null; }

CTX=""
for job in syncup housekeeping; do
  [ "$(_cfg ".automation.\"$job\".enabled")" = "true" ] || continue

  last=0
  lr="$AUTO/$job/last-run.json"
  if [ -f "$lr" ]; then
    ts="$(jq -r '.started_at // empty' "$lr" 2>/dev/null)"
    [ -n "$ts" ] && last="$(date -d "$ts" +%s 2>/dev/null || echo 0)"
  fi
  age_h=$(( (NOW - last) / 3600 ))
  [ "$age_h" -ge "$GRACE_HOURS" ] || continue

  # cooldown: don't re-fire within a grace window (across a session burst)
  mkdir -p "$AUTO/$job" 2>/dev/null || true
  cd_marker="$AUTO/$job/.catchup-cooldown"
  if [ -f "$cd_marker" ]; then
    cd_ts="$(date -r "$cd_marker" +%s 2>/dev/null || echo 0)"
    cd_age_h=$(( (NOW - cd_ts) / 3600 ))
    [ "$cd_age_h" -ge "$GRACE_HOURS" ] || continue
  fi
  : > "$cd_marker" 2>/dev/null || true

  case "$job" in
    syncup)
      if [ "${AUTOMATION_CATCHUP_APPLY:-1}" = "1" ]; then
        ( setsid nohup env CLAUDE_PROJECT_DIR="$PROJ" "$RUN_JOB" syncup </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1
      fi
      CTX="${CTX}• syncup missed (last ~${age_h}h ago) — catching up now in the background."$'\n' ;;
    housekeeping)
      CTX="${CTX}• nightly sweep missed (last ~${age_h}h ago); run \`scheduler.sh run housekeeping\` when convenient (not auto-run mid-day)."$'\n' ;;
  esac
done

[ -n "$CTX" ] || exit 0
jq -n --arg ctx "Scheduled automation — catch-up:"$'\n'"$CTX" \
  '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$ctx}}' 2>/dev/null || true
exit 0
