#!/bin/bash
# daemon-session.sh — session lifecycle for the A2A message daemon.
#
# The problem it fixes: the sphere-daemon is inbound-DEAF unless something starts it, and it
# ran in the FOREGROUND so a bare `… &` died with the launching shell. Nothing supervised it,
# so a fresh session was silently deaf — it missed ticket redeems and consults (had to be done
# by hand). This hook makes the daemon turnkey:
#
#   SessionStart → `daemon-session.sh start`
#       Ensure ONE daemon is live for this repo. If already running (a prior session left it),
#       do NOT start a second — adopt it (per owner: optionally restart to pick up fresh config
#       via A2A_DAEMON_RESTART_ON_START=1, else leave it). Otherwise start it self-DETACHED
#       (setsid + nohup + stdio redirect) so it survives the launching shell, with a logfile.
#
#   SessionEnd → `daemon-session.sh stop`
#       Decrement the live-session refcount. Only the LAST session out stops the daemon — a
#       concurrent session in the same repo still needs it. Crashed sessions (no SessionEnd)
#       are reaped by a TTL so the daemon can't be pinned alive forever.
#
# Refcount = one file per live session under $STATE_DIR/daemon-sessions/. The daemon's OWN
# pidfile (/tmp/claude/<key>/sphere-daemon.pid) and start/stop/status commands remain the
# source of truth for the process itself; this script only decides WHEN to start/stop it.
#
# Never blocks a session (SessionStart/SessionEnd can't block anyway) and always exits 0.
set -uo pipefail

DS_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
# team-coord.sh provides _tc_sphere_helper (the helper→daemon resolver); source-guarded.
. "$DS_HOOK_DIR/team-coord.sh" 2>/dev/null || true

A2A_SESSION_TTL_HOURS="${A2A_SESSION_TTL_HOURS:-24}"   # reap session marks older than this (crashed sessions)
A2A_DAEMON_RESTART_ON_START="${A2A_DAEMON_RESTART_ON_START:-0}"  # 1 = restart an already-running daemon to pick up fresh config

_ds_log() { echo "[daemon-session] $*" >&2; }

# Read the hook's stdin JSON once (SessionStart/SessionEnd deliver {session_id, cwd, ...}).
# CLAUDE_SESSION_ID does NOT exist as an env var — session_id comes from stdin.
DS_STDIN=""
if [ ! -t 0 ]; then DS_STDIN="$(cat 2>/dev/null || true)"; fi
_ds_field() { printf '%s' "$DS_STDIN" | jq -r "$1 // \"\"" 2>/dev/null || echo ""; }

# Project dir: env first (always set for hooks), else the hook payload cwd, else derive.
_ds_project() {
  local p="${CLAUDE_PROJECT_DIR:-}"
  [ -n "$p" ] || p="$(_ds_field '.cwd')"
  [ -n "$p" ] || p="$(cd "$DS_HOOK_DIR/../.." 2>/dev/null && pwd || echo .)"
  printf '%s' "$p"
}
# A stable session key: the runtime session_id, or a fallback tied to this shell if absent
# (manual `a2a daemon start` via A2A_FORCE has no session_id — synthesize one).
_ds_session_id() {
  local s; s="$(_ds_field '.session_id')"
  [ -n "$s" ] || s="${A2A_SESSION_ID:-}"
  [ -n "$s" ] || s="manual-$$"
  # sanitize to a safe filename component
  printf '%s' "$s" | tr -c 'A-Za-z0-9._-' '_'
}
# Resolve helper → daemon script + the clone's node_modules (for the spawned helper's sdk).
_ds_helper() { local h=""; type _tc_sphere_helper >/dev/null 2>&1 && h="$(_tc_sphere_helper)"; printf '%s' "$h"; }
_ds_daemon() { local h; h="$(_ds_helper)"; [ -n "$h" ] && printf '%s/sphere-daemon.mjs' "$(dirname "$h")"; }
_ds_nodepath() { local h; h="$(_ds_helper)"; [ -n "$h" ] && printf '%s/node_modules:%s' "$(cd "$(dirname "$h")/.." 2>/dev/null && pwd)" "${NODE_PATH:-}"; }

_ds_state_dir() {
  local sd=""; . "$DS_HOOK_DIR/state-dir.sh" 2>/dev/null && sd="${STATE_DIR:-}"
  printf '%s' "${sd:-/tmp/claude}"
}
_ds_sessions_dir() { printf '%s/daemon-sessions' "$(_ds_state_dir)"; }

# Reap session marks older than the TTL (crashed sessions that never fired SessionEnd), so a
# dead session can't pin the daemon alive forever. Returns nothing.
_ds_reap_stale() {
  local d; d="$(_ds_sessions_dir)"
  [ -d "$d" ] || return 0
  find "$d" -type f -name '*.mark' -mmin +"$(( A2A_SESSION_TTL_HOURS * 60 ))" -delete 2>/dev/null || true
}
_ds_live_count() {
  local d; d="$(_ds_sessions_dir)"
  [ -d "$d" ] || { echo 0; return; }
  find "$d" -type f -name '*.mark' 2>/dev/null | wc -l | tr -d ' '
}

# Is a daemon currently running for this project? (Uses the daemon's own status → pidfile.)
_ds_daemon_running() {
  local daemon proj; daemon="$(_ds_daemon)"; proj="$(_ds_project)"
  [ -n "$daemon" ] || return 1
  node "$daemon" status --project "$proj" 2>/dev/null | grep -qi 'is running'
}

# Start the daemon self-detached so it OUTLIVES this hook and the launching shell.
_ds_spawn_detached() {
  local daemon proj np logf
  daemon="$(_ds_daemon)"; proj="$(_ds_project)"; np="$(_ds_nodepath)"
  logf="$(_ds_state_dir)/sphere-daemon.log"
  [ -n "$daemon" ] || { _ds_log "daemon script unresolved (helper not found) — cannot start"; return 1; }
  # setsid → new session (immune to the shell's SIGHUP); nohup defensive; stdio fully detached;
  # `&` background; the subshell returns immediately. The daemon writes its own pidfile and
  # refuses a double-start, so a race between two sessions leaves exactly one daemon.
  ( setsid nohup env NODE_PATH="$np" node "$daemon" start --project "$proj" --live \
      </dev/null >>"$logf" 2>&1 & ) >/dev/null 2>&1
  _ds_log "started detached daemon for $proj (log: $logf)"
}

ds_start() {
  local proj; proj="$(_ds_project)"
  # Only manage the daemon where the framework is actually installed.
  [ -f "$proj/.claude/agent/daemon.json" ] || { _ds_log "no .claude/agent/daemon.json in $proj — framework not installed here; skipping"; return 0; }
  local sdir; sdir="$(_ds_sessions_dir)"; mkdir -p "$sdir" 2>/dev/null || true
  _ds_reap_stale
  # Record THIS session as live (idempotent).
  local sid; sid="$(_ds_session_id)"
  : > "$sdir/$sid.mark" 2>/dev/null || true

  # Serialize the check-then-start so two concurrent SessionStarts don't both spawn.
  local lock; lock="$(_ds_state_dir)/daemon-session.lock"
  (
    flock -w 5 9 2>/dev/null || true
    if _ds_daemon_running; then
      if [ "$A2A_DAEMON_RESTART_ON_START" = "1" ]; then
        _ds_log "daemon already running — restarting to pick up fresh config (A2A_DAEMON_RESTART_ON_START=1)"
        local daemon; daemon="$(_ds_daemon)"; node "$daemon" stop --project "$proj" >/dev/null 2>&1 || true
        sleep 1; _ds_spawn_detached
      else
        _ds_log "daemon already running for $proj — adopting it (session $sid registered)"
      fi
    else
      _ds_spawn_detached
    fi
  ) 9>"$lock"
  return 0
}

ds_stop() {
  local proj; proj="$(_ds_project)"
  local sdir; sdir="$(_ds_sessions_dir)"
  local sid; sid="$(_ds_session_id)"
  # Drop THIS session's mark, then reap any stale ones.
  rm -f "$sdir/$sid.mark" 2>/dev/null || true
  _ds_reap_stale
  local live; live="$(_ds_live_count)"
  if [ "${live:-0}" -gt 0 ] 2>/dev/null; then
    _ds_log "session $sid ended; $live live session(s) remain → leaving daemon running"
    return 0
  fi
  # Last one out → stop the daemon.
  local daemon; daemon="$(_ds_daemon)"
  if [ -n "$daemon" ]; then
    node "$daemon" stop --project "$proj" >/dev/null 2>&1 || true
    _ds_log "last session out → stopped daemon for $proj"
  fi
  return 0
}

case "${1:-start}" in
  start) ds_start;;
  stop)  ds_stop;;
  status)
    proj="$(_ds_project)"; daemon="$(_ds_daemon)"
    echo "live sessions: $(_ds_live_count)"
    [ -n "$daemon" ] && node "$daemon" status --project "$proj" || echo "daemon script unresolved"
    ;;
  *) echo "usage: daemon-session.sh {start|stop|status}" >&2;;
esac
exit 0
