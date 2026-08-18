#!/bin/bash
# scheduler.sh — portable scheduler for Claude automation jobs (design §2.2, OD-2).
#
# One thin abstraction over three NATIVE backends, chosen by a platform probe:
#   • systemd --user timers (Linux)   — Persistent=true gives catch-up after
#                                        downtime; needs enable-linger to fire
#                                        while logged out.
#   • Windows Task Scheduler (schtasks, callable from Git Bash).
#   • cron (fallback; no catch-up → automation-catchup.sh covers a missed run).
#
# Commands:
#   scheduler.sh install <job> [--force]   (re)register from config; idempotent
#   scheduler.sh uninstall <job>
#   scheduler.sh status [<job>]            registered? next run? linger? last run?
#   scheduler.sh run <job>                 manual fire (delegates to run-job.sh)
#
# The scheduler NEVER enables a job itself — it registers only what config already
# marks enabled (.automation.<job>.enabled). Schedule time is .automation.<job>.time
# (local HH:MM). lifecycle (F2) is event-driven and NOT schedulable here.
#
# Test seams (all default to real behavior):
#   AUTOMATION_SCHED_BACKEND   force systemd|schtasks|cron|none (skip the probe)
#   AUTOMATION_SCHED_APPLY=0   write unit/cron artifacts but DON'T call the OS
#                              (systemctl/schtasks/enable) — for hermetic tests
#   AUTOMATION_SYSTEMD_DIR     override ~/.config/systemd/user
#   CRONTAB_CMD                override the `crontab` binary
#   AUTOMATION_SKIP_CLAUDE_CHECK / AUTOMATION_SKIP_GH_CHECK  skip those preflights
set -uo pipefail

SC_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
SC_HOOKS_PARENT="$(cd "$SC_HOOK_DIR/.." 2>/dev/null && pwd || echo .)"
. "$SC_HOOKS_PARENT/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"

RUN_JOB="$SC_HOOK_DIR/run-job.sh"

_sc_log() { echo "[scheduler] $*" >&2; }
_red()    { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
_grn()    { printf '\033[1;32m%s\033[0m\n' "$*" >&2; }

# Project dir: automation/ is one level below .claude/hooks → ../../.. = project root.
PROJ="${CLAUDE_PROJECT_DIR:-}"
[ -n "$PROJ" ] || PROJ="$(cd "$SC_HOOK_DIR/../../.." 2>/dev/null && pwd || echo "")"
CONFIG="$PROJ/.claude/agent/config.json"

_sc_is_job() { case "$1" in syncup|housekeeping) return 0 ;; *) return 1 ;; esac; }

# Stable per-repo id: human-ish basename + short path hash (disambiguates several
# repos on one host that all schedule 03:00).
_slug() {
  local base h
  base="$(basename "$PROJ" 2>/dev/null)"
  # sanitize AFTER the command-sub strips basename's trailing newline (otherwise
  # tr would turn that newline into a stray trailing '-').
  base="$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '-')"
  h="$(printf '%s' "$PROJ" | sha1sum 2>/dev/null | cut -c1-8)"
  printf '%s-%s' "${base:-repo}" "${h:-00000000}"
}
_unit()        { printf 'claude-%s-%s' "$(_slug)" "$1"; }             # systemd unit base
_taskname()    { printf 'ClaudeUnicity\\%s-%s' "$(_slug)" "$1"; }      # schtasks task name
_cron_marker() { printf '# claude-automation:%s:%s' "$(_slug)" "$1"; } # cron delimiter

_cfg()         { jq -r "$1" "$CONFIG" 2>/dev/null; }
_job_enabled() { [ "$(_cfg ".automation.\"$1\".enabled")" = "true" ]; }
_job_time()    { local t; t="$(_cfg ".automation.\"$1\".time")"; case "$t" in ""|null) t="03:00" ;; esac; printf '%s' "$t"; }

_systemd_dir() { printf '%s' "${AUTOMATION_SYSTEMD_DIR:-$HOME/.config/systemd/user}"; }
_crontab()     { "${CRONTAB_CMD:-crontab}" "$@"; }
_apply()       { [ "${AUTOMATION_SCHED_APPLY:-1}" = "1" ]; }

# --- backend probe (Windows first, then Linux-native, then fallback) ----------
_backend() {
  if [ -n "${AUTOMATION_SCHED_BACKEND:-}" ]; then printf '%s' "$AUTOMATION_SCHED_BACKEND"; return; fi
  if command -v schtasks.exe >/dev/null 2>&1; then printf 'schtasks'; return; fi
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    printf 'systemd'; return
  fi
  if command -v crontab >/dev/null 2>&1; then printf 'cron'; return; fi
  printf 'none'
}

# --- 2.4 install-time preflight (loud, exact remediation; NOT at 3 AM) --------
# Sets PF_OK=0 (all good) or 1 (issues printed above). $1 = the job's schedule
# time (optional) — validated so a malformed value ("0700", "7am") is rejected
# loudly here rather than accepted-but-inert by systemd/schtasks until 3 AM.
_preflight() {
  local rc=0 sched_time="${1:-}"
  command -v jq >/dev/null 2>&1 || { _red "  MISSING: jq"; rc=1; }
  [ -f "$CONFIG" ] || { _red "  MISSING: $CONFIG — run setup.sh in this project first"; rc=1; }
  if [ -n "$sched_time" ] && ! printf '%s' "$sched_time" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$'; then
    _red "  INVALID time '$sched_time' — must be 24h HH:MM (e.g. 03:00). Fix .automation.<job>.time"; rc=1
  fi
  if [ "${AUTOMATION_SKIP_CLAUDE_CHECK:-0}" != "1" ]; then
    if command -v claude >/dev/null 2>&1; then
      if ! claude -p 'ok' --max-turns 1 >/dev/null 2>&1; then
        _red "  claude present but auth smoke FAILED — log in (run: claude), or pass --skip-claude-check"; rc=1
      fi
    else
      _red "  MISSING: claude on PATH — install the Claude Code CLI"; rc=1
    fi
  fi
  if [ "${AUTOMATION_SKIP_GH_CHECK:-0}" != "1" ]; then
    if command -v gh >/dev/null 2>&1; then
      gh auth status >/dev/null 2>&1 || { _red "  gh present but NOT authenticated — run: gh auth login"; rc=1; }
    else
      _red "  MISSING: gh CLI — install it and run: gh auth login"; rc=1
    fi
  fi
  case "$(_backend)" in
    systemd)
      local linger; linger="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo "")"
      if [ "$linger" != "yes" ]; then
        _red "  LINGER OFF — user timers will NOT fire while you are logged out."
        _red "    fix:  loginctl enable-linger $USER"; rc=1
      fi ;;
    schtasks)
      command -v bash >/dev/null 2>&1 || { _red "  cannot resolve bash path for the schtasks action"; rc=1; } ;;
    none)
      _red "  NO scheduler backend (no systemctl --user, schtasks.exe, or crontab)"; rc=1 ;;
  esac
  PF_OK=$rc
}

# --- systemd backend ----------------------------------------------------------
_install_systemd() {
  local job="$1" hh="$2" mm="$3" dir unit
  dir="$(_systemd_dir)"; mkdir -p "$dir" 2>/dev/null || true
  unit="$(_unit "$job")"
  # Quote the project path in Environment= and the exec path in ExecStart= so a
  # repo path with a space survives (systemd honors double-quotes in both).
  cat > "$dir/$unit.service" <<EOF
[Unit]
Description=Claude automation job '$job' for $PROJ

[Service]
Type=oneshot
Environment="CLAUDE_PROJECT_DIR=$PROJ"
ExecStart="$RUN_JOB" $job
EOF
  cat > "$dir/$unit.timer" <<EOF
[Unit]
Description=Timer for Claude automation '$job' ($PROJ)

[Timer]
OnCalendar=*-*-* $hh:$mm:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
  if _apply; then
    systemctl --user daemon-reload 2>/dev/null || true
    # Capture the enable rc: a green "installed" line while enable silently
    # failed (no --user manager, linger off) is a lie the operator only discovers
    # at 3 AM. On failure, downgrade the message and return non-zero.
    if ! systemctl --user enable --now "$unit.timer" >/dev/null 2>&1; then
      _red "systemd timer $unit.timer written but enable FAILED (--user manager down? linger off?)"
      _red "  the unit files are in place; fix the user manager, then: systemctl --user enable --now $unit.timer"
      return 1
    fi
  fi
  _grn "installed systemd timer $unit.timer → daily $hh:$mm (Persistent catch-up on)"
}
_uninstall_systemd() {
  local job="$1" dir unit
  dir="$(_systemd_dir)"; unit="$(_unit "$job")"
  _apply && systemctl --user disable --now "$unit.timer" >/dev/null 2>&1 || true
  rm -f "$dir/$unit.timer" "$dir/$unit.service"
  _apply && systemctl --user daemon-reload 2>/dev/null || true
  _grn "removed systemd timer $unit"
}

# --- schtasks backend ---------------------------------------------------------
_install_schtasks() {
  local job="$1" hh="$2" mm="$3" tn bash_exe tr
  tn="$(_taskname "$job")"
  bash_exe="$(command -v bash)"
  tr="\"$bash_exe\" -lc \"CLAUDE_PROJECT_DIR='$PROJ' '$RUN_JOB' $job\""
  if _apply; then
    schtasks.exe //Create //TN "$tn" //TR "$tr" //SC DAILY //ST "$hh:$mm" //F >/dev/null 2>&1 \
      || _sc_log "warn: schtasks create failed for $tn"
  fi
  _grn "installed schtasks '$tn' → daily $hh:$mm"
  _sc_log "note: for catch-up, enable 'run task as soon as possible after a missed start' on the task"
}
_uninstall_schtasks() {
  local job="$1" tn; tn="$(_taskname "$job")"
  _apply && schtasks.exe //Delete //TN "$tn" //F >/dev/null 2>&1 || true
  _grn "removed schtasks '$tn'"
}

# --- cron backend (marker-delimited line: reinstall REPLACES, never appends) ---
_install_cron() {
  local job="$1" hh="$2" mm="$3" marker line current
  marker="$(_cron_marker "$job")"
  line="$mm $hh * * * env CLAUDE_PROJECT_DIR='$PROJ' '$RUN_JOB' $job $marker"
  current="$(_crontab -l 2>/dev/null | grep -vF "$marker" || true)"
  if printf '%s\n%s\n' "$current" "$line" | sed '/^[[:space:]]*$/d' | _crontab - 2>/dev/null; then
    _grn "installed cron entry → daily $hh:$mm ($marker)"
    _sc_log "note: cron has no catch-up; a missed run is recovered by automation-catchup.sh"
  else
    _red "cron install failed for $job"; return 1
  fi
}
_uninstall_cron() {
  local job="$1" marker current; marker="$(_cron_marker "$job")"
  current="$(_crontab -l 2>/dev/null | grep -vF "$marker" || true)"
  printf '%s\n' "$current" | sed '/^[[:space:]]*$/d' | _crontab - 2>/dev/null || true
  _grn "removed cron entry ($marker)"
}

# --- commands -----------------------------------------------------------------
# Persist which backend currently owns a job's registration, so a backend switch
# between installs (host moved, probe changed) removes the OLD entry instead of
# leaving two schedulers firing the same job.
_backend_state() { printf '%s/automation/%s.backend' "$STATE_DIR" "$1"; }
_uninstall_backend() { # $1=job $2=backend  (targeted, quiet)
  case "$2" in
    systemd)  _uninstall_systemd  "$1" >/dev/null 2>&1 || true ;;
    schtasks) _uninstall_schtasks "$1" >/dev/null 2>&1 || true ;;
    cron)     _uninstall_cron     "$1" >/dev/null 2>&1 || true ;;
  esac
}

_install() {
  local job="${1:-}" force="${2:-}"
  _sc_is_job "$job" || { _red "not a schedulable job: '$job' (use syncup|housekeeping)"; return 2; }
  if ! _job_enabled "$job"; then
    _sc_log "$job is disabled in config (.automation.$job.enabled=false) — nothing to install."
    _sc_log "  to enable: set that flag true in $CONFIG, then re-run: scheduler.sh install $job"
    return 0
  fi
  local t hh mm; t="$(_job_time "$job")"; hh="${t%%:*}"; mm="${t##*:}"
  PF_OK=0; _preflight "$t"
  if [ "${PF_OK:-0}" != "0" ] && [ "$force" != "--force" ]; then
    _red "Preflight FAILED (see above). Fix the items, or re-run with --force to install anyway."
    return 1
  fi
  local chosen prev sf; chosen="$(_backend)"
  sf="$(_backend_state "$job")"
  prev="$(cat "$sf" 2>/dev/null || echo "")"
  # Reconcile: if a DIFFERENT backend previously owned this job, remove its entry
  # first so we don't end up double-fired by two schedulers.
  if [ -n "$prev" ] && [ "$prev" != "$chosen" ]; then
    _sc_log "backend switched ($prev → $chosen) — removing the stale $prev registration for $job"
    _uninstall_backend "$job" "$prev"
  fi
  local rc=0
  case "$chosen" in
    systemd)  _install_systemd  "$job" "$hh" "$mm" || rc=$? ;;
    schtasks) _install_schtasks "$job" "$hh" "$mm" || rc=$? ;;
    cron)     _install_cron     "$job" "$hh" "$mm" || rc=$? ;;
    *) _red "No scheduler backend available."; return 1 ;;
  esac
  # Record the active backend only on a successful install.
  if [ "$rc" -eq 0 ]; then
    mkdir -p "$(dirname "$sf")" 2>/dev/null || true
    printf '%s\n' "$chosen" > "$sf" 2>/dev/null || true
  fi
  return "$rc"
}

_uninstall() {
  local job="${1:-}"
  _sc_is_job "$job" || { _red "not a schedulable job: '$job'"; return 2; }
  case "$(_backend)" in
    systemd)  _uninstall_systemd  "$job" ;;
    schtasks) _uninstall_schtasks "$job" ;;
    cron)     _uninstall_cron     "$job" ;;
    *) _sc_log "no backend — nothing to uninstall" ;;
  esac
  rm -f "$(_backend_state "$job")" 2>/dev/null || true
}

_status_job() {
  local job="$1" en be lr
  en="$(_job_enabled "$job" && echo enabled || echo disabled)"
  be="$(_backend)"
  printf 'job=%-12s config=%-8s time=%-5s backend=%s\n' "$job" "$en" "$(_job_time "$job")" "$be"
  case "$be" in
    systemd)
      local unit; unit="$(_unit "$job")"
      if _apply; then
        systemctl --user list-timers --all 2>/dev/null | grep -F "$unit" \
          || echo "  (timer not registered)"
        echo "  linger=$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo '?')"
      else
        [ -f "$(_systemd_dir)/$unit.timer" ] && echo "  unit file present ($(_systemd_dir)/$unit.timer)" \
          || echo "  (no unit file)"
      fi ;;
    cron)     _crontab -l 2>/dev/null | grep -F "$(_cron_marker "$job")" || echo "  (no cron entry)" ;;
    schtasks) _apply && { schtasks.exe //Query //TN "$(_taskname "$job")" 2>/dev/null || echo "  (no task)"; } ;;
  esac
  lr="$STATE_DIR/automation/$job/last-run.json"
  if [ -f "$lr" ]; then
    echo "  last-run: $(jq -r '"\(.status) @ \(.finished_at // .started_at)"' "$lr" 2>/dev/null)"
  else
    echo "  last-run: never"
  fi
}
_status() {
  if [ -n "${1:-}" ]; then _status_job "$1"; else
    for j in syncup housekeeping; do _status_job "$j"; done
  fi
}

CMD="${1:-}"; shift 2>/dev/null || true
case "$CMD" in
  install)   _install "${1:-}" "${2:-}" ;;
  uninstall) _uninstall "${1:-}" ;;
  status)    _status "${1:-}" ;;
  run)
    _sc_is_job "${1:-}" || { _sc_log "usage: scheduler.sh run <syncup|housekeeping>"; exit 2; }
    exec "$RUN_JOB" "$1" ;;
  *) echo "usage: scheduler.sh {install|uninstall|status|run} <job> [--force]" >&2; exit 2 ;;
esac
