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

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
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
    cp "$JOURNAL" "$LASTRUN.tmp" 2>/dev/null && mv "$LASTRUN.tmp" "$LASTRUN"
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
# Never let a git/gh op block on a credential prompt at 3 AM — it would hang while
# holding the flock below and wedge every future run.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -oBatchMode=yes}"
# APPEND the standard dirs (don't prepend): guarantees git/jq/etc. resolve at 3 AM
# under a bare cron/systemd PATH, without demoting the caller's own PATH entries.
export PATH="${PATH:-}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- 6. job → skill prompt + per-job flags ------------------------------------
# All real logic lives in the skill; scheduled == interactive code path. The
# housekeeping worktree/post-phase (Group D) extends this path.
#
# acceptEdits SEAM (Group D handoff): housekeeping runs with acceptEdits — but the
# flag is set ONLY by the §6b worktree-engagement block below, i.e. ONLY when the
# session's cwd is the disposable, secret-free sweep worktree on a sweep/* branch
# the wrapper alone can publish. It is NEVER set here for the bare-launch path, so
# acceptEdits can never touch the LIVE checkout. (The pre-D AUTOMATION_HK_ACCEPT_EDITS
# env placeholder is intentionally gone now that the isolating worktree exists —
# keeping it would have been the one way to grant acceptEdits in the live tree.)
EXTRA=()
case "$JOB" in
  syncup)       PROMPT="/syncup" ;;
  housekeeping) PROMPT="/housekeeping" ;;   # acceptEdits set in §6b, worktree-only
esac

# Wall cap: minutes → `timeout` duration; AUTOMATION_WALL_OVERRIDE lets tests
# force a tiny cap (e.g. "2s") against a mock claude that sleeps.
WALL="${AUTOMATION_WALL_OVERRIDE:-${MAX_WALL}m}"
SESSION_LOG="$JOB_DIR/last-session.log"

# --- 6b. housekeeping: run the session in a disposable worktree off origin/main
# (Group D §5.2/§5.3). The sweep NEVER edits the live checkout. When
# sweep-worktree.sh is present AND origin/main resolves, create the worktree, set
# cwd = worktree and turn acceptEdits ON — this is the ONLY place acceptEdits is
# granted, and it is safe precisely because of the isolation established here:
# secret-free worktree (no .env/.secrets/agent), a sweep/* branch only the wrapper
# can publish, and the PreToolUse gates (branch-guard, pre-commit) still live.
# Then hand off to the deterministic post-phase (push + PR + secret-scan; the model
# never pushes). Absent the machinery or origin/main → fall back to a bare in-place
# launch WITHOUT acceptEdits (keeps Group A's contract + tests intact); the
# /housekeeping skill then sees it is not on a sweep/* branch and self-aborts, so
# the live checkout is never edited.
RUN_CWD=""; SWEEP_WT=""; SUMMARY_EXTRA=""
SWEEP_WT_SH="$RJ_HOOK_DIR/sweep-worktree.sh"
SWEEP_POST_SH="$RJ_HOOK_DIR/sweep-post.sh"
if [ "$JOB" = housekeeping ] && [ -x "$SWEEP_WT_SH" ] \
   && git -C "$PROJ" rev-parse --verify -q origin/main >/dev/null 2>&1; then
  SWEEP_WT="$(AUTOMATION_STATE_DIR="$STATE_DIR" bash "$SWEEP_WT_SH" create "$PROJ" 2>>"$SESSION_LOG")"
  RC_WT=$?
  if [ "$RC_WT" -eq 3 ]; then
    _write_journal skipped_worktree_exists null "a prior sweep worktree still exists — skipped tonight (surface, don't stack)"
    # notify so the crash the collision is surfacing is actually visible (a silent
    # skip could repeat for up to 7 nights until the sweep-dir prune clears it).
    notify "Automation: housekeeping skipped" "a prior sweep worktree still exists — investigate/clean it; journal: $JOURNAL" normal
    _rj_log "housekeeping: sweep worktree collision — skipping this fire"
    exit 0
  elif [ "$RC_WT" -ne 0 ] || [ -z "$SWEEP_WT" ] || [ ! -d "$SWEEP_WT" ]; then
    _write_journal failed "$RC_WT" "could not create sweep worktree (rc=$RC_WT)"
    notify "Automation: housekeeping failed" "sweep worktree creation failed (rc=$RC_WT) — journal: $JOURNAL" critical
    exit 0
  fi
  RUN_CWD="$SWEEP_WT"
  EXTRA=(--permission-mode acceptEdits)          # safe ONLY here (§5.3)
  export SWEEP_HANDOFF_DIR="$JOB_DIR/handoff"
  rm -rf "$SWEEP_HANDOFF_DIR" 2>/dev/null; mkdir -p "$SWEEP_HANDOFF_DIR" 2>/dev/null || true
  _rj_log "housekeeping: sweep worktree $SWEEP_WT (cwd), acceptEdits ON"
fi

_run_once() {
  if [ -n "$RUN_CWD" ]; then
    if [ "${#EXTRA[@]}" -gt 0 ]; then
      ( cd "$RUN_CWD" && timeout "$WALL" "$CLAUDE_RESOLVED" -p "$PROMPT" --max-turns "$MAX_TURNS" "${EXTRA[@]}" ) >"$SESSION_LOG" 2>&1
    else
      ( cd "$RUN_CWD" && timeout "$WALL" "$CLAUDE_RESOLVED" -p "$PROMPT" --max-turns "$MAX_TURNS" ) >"$SESSION_LOG" 2>&1
    fi
  elif [ "${#EXTRA[@]}" -gt 0 ]; then
    timeout "$WALL" "$CLAUDE_RESOLVED" -p "$PROMPT" --max-turns "$MAX_TURNS" "${EXTRA[@]}" >"$SESSION_LOG" 2>&1
  else
    timeout "$WALL" "$CLAUDE_RESOLVED" -p "$PROMPT" --max-turns "$MAX_TURNS" >"$SESSION_LOG" 2>&1
  fi
}

_write_journal running null "launched $PROMPT (wall=$WALL, max_turns=$MAX_TURNS)"
_rj_log "starting $JOB: $CLAUDE_BIN -p '$PROMPT' --max-turns $MAX_TURNS (wall=$WALL)"

# --- execute with at most one wrapper-level retry (crash recovery only) --------
ATTEMPT=1 STATUS="" RC=0
while [ "$ATTEMPT" -le 2 ]; do
  _run_once; RC=$?
  if [ "$RC" -eq 0 ]; then STATUS=completed; break; fi
  if [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ]; then STATUS=timeout; else STATUS=failed; fi
  if [ "$RETRY_ONCE" = "true" ] && [ "$ATTEMPT" -lt 2 ]; then
    _rj_log "$JOB $STATUS (rc=$RC) — one retry permitted (retry_once=true)"
    ATTEMPT=$((ATTEMPT + 1)); continue
  fi
  break
done

# --- 6c. housekeeping post-phase: deterministic green-check/secret-scan/diff-cap/
# push/PR/morning-report/cleanup (Group D §5.4 post-phase + §5.6). The MODEL never
# pushes — this wrapper does, and only after every gate passes. Runs ONLY on a
# completed session; a timed-out/crashed session deliberately LEAVES the worktree
# so tomorrow's run collision-skips and SURFACES it (§5.2 collide, §6 row 3).
if [ -n "$SWEEP_WT" ] && [ -x "$SWEEP_POST_SH" ]; then
  if [ "$STATUS" = completed ]; then
    AUTOMATION_STATE_DIR="$STATE_DIR" SWEEP_HANDOFF_DIR="${SWEEP_HANDOFF_DIR:-$JOB_DIR/handoff}" \
      bash "$SWEEP_POST_SH" "$SWEEP_WT" "$PROJ" >>"$SESSION_LOG" 2>&1
    PRC=$?
    case "$PRC" in
      0)  SUMMARY_EXTRA="PR opened" ;;
      10) SUMMARY_EXTRA="nothing shipped" ;;
      11) STATUS=failed; SUMMARY_EXTRA="hand-off anomaly (nothing pushed, worktree left)" ;;
      20) STATUS=failed; SUMMARY_EXTRA="aborted: red tests" ;;
      21) STATUS=failed; SUMMARY_EXTRA="aborted: secret detected" ;;
      30) STATUS=failed; SUMMARY_EXTRA="push/PR/diff-cap failed" ;;
      *)  STATUS=failed; SUMMARY_EXTRA="post-phase rc=$PRC" ;;
    esac
    _rj_log "housekeeping post-phase rc=$PRC ($SUMMARY_EXTRA)"
  else
    _rj_log "housekeeping session $STATUS — leaving worktree $SWEEP_WT for surfacing (no post-phase)"
  fi
fi

# --- 7. outcome: journal + notify on failure ----------------------------------
SUMMARY="$PROMPT finished: $STATUS (rc=$RC, attempts=$ATTEMPT)${SUMMARY_EXTRA:+ — $SUMMARY_EXTRA}"
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
