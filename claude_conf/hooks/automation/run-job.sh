#!/bin/bash
# run-job.sh <job> — the headless-runner contract for every scheduled automation
# job (design §2.3). The scheduler NEVER invokes `claude` directly; it invokes
# this wrapper, and this wrapper is the single failure/observability channel.
#
# Contract (in order):
#   1. Resolve project dir (baked into the installed timer/task at install time —
#      at 3 AM there is no CLAUDE_PROJECT_DIR); source state-dir.sh + notify.sh.
#   2. Config gate: .automation.<job>.enabled must be true, else exit 0 SILENTLY
#      (disabling in config takes effect without touching the scheduler). The
#      AUTOMATION_DISABLE=1 env kills every job here.
#   3. Overlap lock: flock -n held for the whole run; if held → journal
#      skipped_overlap + exit 0 (a slow job never stacks on itself).
#   4. Journal each run under $STATE_DIR/automation/<job>/run-<utc>.json and keep
#      last-run.json atomically current; reap journals older than 14 days.
#   5. Export the outage-resilience env (watchdog + retries + idle timeouts,
#      mirroring settings.json) so a job launched outside a configured dir still
#      rides out 429/529 storms; set AUTOMATION_JOB + a conservative PATH.
#   6. Execute under a hard wall-clock `timeout` + `--max-turns`. The prompt is a
#      one-liner invoking the job's SKILL (/syncup, /housekeeping) so interactive
#      and scheduled invocations are the SAME code path.
#   7. On failed/timeout → notify.sh (critical) with the journal path; ONE retry
#      only if retry_once (crashes only — the watchdog already absorbs API
#      outages INSIDE the run). Never loop-retry.
#   8. Exit 0 ALWAYS (a backend that sees repeated non-zero may disable the unit;
#      our journal + notify is the failure channel, not the scheduler's).
#
# lifecycle (F2) is event-driven, not scheduled — only syncup/housekeeping run here.
set -uo pipefail

RJ_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
# automation/ sits one level below .claude/hooks; state-dir.sh keys STATE_DIR on
# the PROJECT root (its own ../..). Source the PARENT copy so our key matches
# every other hook in the repo (a nested copy would key on the wrong dir).
RJ_HOOKS_PARENT="$(cd "$RJ_HOOK_DIR/.." 2>/dev/null && pwd || echo .)"
. "$RJ_HOOKS_PARENT/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"
. "$RJ_HOOKS_PARENT/notify.sh" 2>/dev/null || notify() { :; }

_rj_log() { echo "[run-job] $*" >&2; }

JOB="${1:-}"
case "$JOB" in
  syncup|housekeeping) ;;
  "") _rj_log "usage: run-job.sh <syncup|housekeeping>"; exit 2 ;;
  *)  _rj_log "unknown / non-schedulable job: $JOB (lifecycle is event-driven)"; exit 2 ;;
esac

# --- 1. project dir + config ---------------------------------------------------
PROJ="${CLAUDE_PROJECT_DIR:-}"
[ -n "$PROJ" ] || PROJ="$(cd "$RJ_HOOK_DIR/../../.." 2>/dev/null && pwd || echo "")"
CONFIG="$PROJ/.claude/agent/config.json"

# --- 2. config gate (+ global kill switch) ------------------------------------
if [ "${AUTOMATION_DISABLE:-0}" = "1" ]; then
  _rj_log "AUTOMATION_DISABLE=1 — all jobs disabled; not running $JOB"
  exit 0
fi
_cfg() { jq -r "$1" "$CONFIG" 2>/dev/null; }
if [ ! -f "$CONFIG" ]; then
  _rj_log "no config at $CONFIG — not a configured project; exiting"
  exit 0
fi
if [ "$(_cfg ".automation.\"$JOB\".enabled")" != "true" ]; then
  _rj_log "$JOB is not enabled (.automation.$JOB.enabled != true) — exiting"
  exit 0
fi

# Bounded params with the §2.7 defaults when unset/null.
MAX_WALL="$(_cfg ".automation.\"$JOB\".max_wall_minutes")"
case "$MAX_WALL" in ""|null) MAX_WALL=$([ "$JOB" = housekeeping ] && echo 240 || echo 45) ;; esac
MAX_TURNS="$(_cfg ".automation.\"$JOB\".max_turns")"
case "$MAX_TURNS" in ""|null) MAX_TURNS=$([ "$JOB" = housekeeping ] && echo 300 || echo 80) ;; esac
RETRY_ONCE="$(_cfg ".automation.\"$JOB\".retry_once")"
case "$RETRY_ONCE" in true) RETRY_ONCE=true ;; *) RETRY_ONCE=false ;; esac

# --- state layout + journal helpers -------------------------------------------
AUTO_DIR="$STATE_DIR/automation"
JOB_DIR="$AUTO_DIR/$JOB"
LOCK="$AUTO_DIR/$JOB.lock"
mkdir -p "$JOB_DIR" 2>/dev/null || true

# reap journals older than 14 days at the start of every run (§2.3.4)
find "$JOB_DIR" -maxdepth 1 -name 'run-*.json' -mtime +14 -delete 2>/dev/null || true

# PID-qualify the stamp: `date` is 1-second resolution, so two fires in the same
# clock second (catch-up + a manual `scheduler.sh run`, or two terminals) would
# otherwise share one filename and clobber each other's journal. flock serializes
# EXECUTION, but the skipped_overlap record is written by the fire that LOST the
# lock — a distinct process — so its journal must not collide with the winner's.
STAMP="$(date -u +%Y%m%dT%H%M%S)Z-$$"
JOURNAL="$JOB_DIR/run-$STAMP.json"
LASTRUN="$JOB_DIR/last-run.json"
STARTED_AT="$(date -u +%FT%TZ)"

# _write_journal <status> <exit_code|null> <summary> [artifacts_json]
_write_journal() {
  local status="$1" ec="$2" summ="$3" arts="${4:-[]}"
  local finished="null"
  case "$status" in running) finished="null" ;; *) finished="\"$(date -u +%FT%TZ)\"" ;; esac
  if jq -n --arg job "$JOB" --arg started "$STARTED_AT" --argjson pid "$$" \
       --arg status "$status" --argjson finished "$finished" \
       --argjson ec "${ec:-null}" --arg summary "$summ" --argjson artifacts "$arts" \
       '{job:$job, started_at:$started, pid:$pid, status:$status,
         finished_at:$finished, exit_code:$ec, summary:$summary,
         artifacts:$artifacts, reported:false}' \
       > "$JOURNAL.tmp" 2>/dev/null; then
    mv "$JOURNAL.tmp" "$JOURNAL"
    # per-PID temp so two processes' last-run writes never share a tmp (atomic mv).
    cp "$JOURNAL" "$LASTRUN.tmp.$$" 2>/dev/null && mv "$LASTRUN.tmp.$$" "$LASTRUN"
  else
    rm -f "$JOURNAL.tmp"
    _rj_log "warn: could not write journal $JOURNAL"
  fi
}

# --- 3. overlap lock (held for the whole run; released on process death) ------
exec 9>"$LOCK" 2>/dev/null || { _rj_log "cannot open lock $LOCK — exiting"; exit 0; }
if ! flock -n 9; then
  _write_journal skipped_overlap null "another $JOB run holds the lock — skipped"
  _rj_log "$JOB already running (lock held) — skipping this fire"
  exit 0
fi

# Resolve the claude binary to an ABSOLUTE path BEFORE we touch PATH — so a
# user's version-managed claude (asdf/nvm-style, or a test-injected mock) is the
# one that runs, not whatever a reconstructed PATH happens to find first.
CLAUDE_BIN="${AUTOMATION_CLAUDE_BIN:-claude}"
CLAUDE_RESOLVED="$(command -v "$CLAUDE_BIN" 2>/dev/null || printf '%s' "$CLAUDE_BIN")"

# --- 5. outage-resilience env (mirror settings.json; keep any inherited value) -
export CLAUDE_CODE_RETRY_WATCHDOG="${CLAUDE_CODE_RETRY_WATCHDOG:-1}"
export CLAUDE_CODE_MAX_RETRIES="${CLAUDE_CODE_MAX_RETRIES:-300}"
export API_TIMEOUT_MS="${API_TIMEOUT_MS:-1200000}"
export API_FORCE_IDLE_TIMEOUT="${API_FORCE_IDLE_TIMEOUT:-1}"
export CLAUDE_STREAM_IDLE_TIMEOUT_MS="${CLAUDE_STREAM_IDLE_TIMEOUT_MS:-1200000}"
export CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS="${CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS:-1200000}"
export AUTOMATION_JOB="$JOB"
export CLAUDE_PROJECT_DIR="$PROJ"
# APPEND the standard dirs (don't prepend): guarantees git/jq/etc. resolve at 3 AM
# under a bare cron/systemd PATH, without demoting the caller's own PATH entries.
export PATH="${PATH:-}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- 6. job → skill prompt + per-job flags ------------------------------------
# All real logic lives in the skill; scheduled == interactive code path. The
# housekeeping worktree/post-phase (Group D) extends this path; here it launches
# generically in the project dir. Why housekeeping alone MAY carry acceptEdits:
# Group D runs it in a disposable, secret-free worktree on a branch only the
# wrapper can publish — that isolation does not exist yet, so until D lands the
# acceptEdits flag is opt-in via AUTOMATION_HK_ACCEPT_EDITS=1 (default off) so an
# early enable can't autonomously edit the live checkout.
EXTRA=()
case "$JOB" in
  syncup)       PROMPT="/syncup" ;;
  housekeeping) PROMPT="/housekeeping"
                [ "${AUTOMATION_HK_ACCEPT_EDITS:-0}" = "1" ] && EXTRA=(--permission-mode acceptEdits) ;;
esac

# Wall cap: minutes → `timeout` duration; AUTOMATION_WALL_OVERRIDE lets tests
# force a tiny cap (e.g. "2s") against a mock claude that sleeps.
WALL="${AUTOMATION_WALL_OVERRIDE:-${MAX_WALL}m}"
# SIGKILL grace after the wall SIGTERM (see _run_once); tunable for tests.
KILL_AFTER="${AUTOMATION_KILL_AFTER:-30s}"
SESSION_LOG="$JOB_DIR/last-session.log"

# `-k 30s`: if the child ignores the SIGTERM `timeout` sends at the wall cap,
# SIGKILL it 30 s later. Without this a SIGTERM-ignoring session would wedge past
# the cap forever — holding the flock (so every later fire skips) and leaving the
# journal stuck at 'running'; the hard kill is what makes the runaway cap and
# "flock released by death" actually hold.
_run_once() {
  if [ "${#EXTRA[@]}" -gt 0 ]; then
    timeout -k "$KILL_AFTER" "$WALL" "$CLAUDE_RESOLVED" -p "$PROMPT" --max-turns "$MAX_TURNS" "${EXTRA[@]}" >"$SESSION_LOG" 2>&1
  else
    timeout -k "$KILL_AFTER" "$WALL" "$CLAUDE_RESOLVED" -p "$PROMPT" --max-turns "$MAX_TURNS" >"$SESSION_LOG" 2>&1
  fi
}

_write_journal running null "launched $PROMPT (wall=$WALL, max_turns=$MAX_TURNS)"
_rj_log "starting $JOB: $CLAUDE_BIN -p '$PROMPT' --max-turns $MAX_TURNS (wall=$WALL)"

# --- execute with at most one wrapper-level retry (CRASH recovery only) --------
# Per §2.3.7 a retry is for crashes, NEVER for a timeout: the watchdog already
# absorbs API outages INSIDE the run, so a run that hit the wall cap has already
# spent its whole window — retrying would launch a SECOND full-length session
# past the job's window (e.g. syncup's 45 min again past 08:00). So we retry only
# when STATUS=failed (nonzero AND not 124/137); a timeout is terminal.
ATTEMPT=1 STATUS="" RC=0
while [ "$ATTEMPT" -le 2 ]; do
  _run_once; RC=$?
  if [ "$RC" -eq 0 ]; then STATUS=completed; break; fi
  if [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ]; then STATUS=timeout; else STATUS=failed; fi
  if [ "$STATUS" = "failed" ] && [ "$RETRY_ONCE" = "true" ] && [ "$ATTEMPT" -lt 2 ]; then
    _rj_log "$JOB crashed (rc=$RC) — one retry permitted (retry_once=true)"
    ATTEMPT=$((ATTEMPT + 1)); continue
  fi
  break
done

# --- 7. outcome: journal + notify on failure ----------------------------------
SUMMARY="$PROMPT finished: $STATUS (rc=$RC, attempts=$ATTEMPT)"
# Forward-compat: a job's model hand-off may drop an artifacts.json (PR urls /
# report path — Group D). Consume it into the journal if present + valid.
ARTS="[]"
if [ -f "$JOB_DIR/artifacts.json" ] && jq -e 'type=="array"' "$JOB_DIR/artifacts.json" >/dev/null 2>&1; then
  ARTS="$(cat "$JOB_DIR/artifacts.json")"
  rm -f "$JOB_DIR/artifacts.json"
fi
_write_journal "$STATUS" "$RC" "$SUMMARY" "$ARTS"

if [ "$STATUS" != "completed" ]; then
  notify "Automation: $JOB $STATUS" "$SUMMARY — journal: $JOURNAL" critical
  _rj_log "$SUMMARY (journal: $JOURNAL)"
else
  _rj_log "$SUMMARY"
fi

# --- 8. exit 0 always ---------------------------------------------------------
exit 0
