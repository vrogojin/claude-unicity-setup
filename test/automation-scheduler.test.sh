#!/bin/bash
# automation-scheduler.test.sh — hermetic proof of scheduler.sh (§2.2) across all
# three backends without touching the host scheduler:
#   • cron      via a mock `crontab` (CRONTAB_CMD) backed by a plain file
#   • systemd   with AUTOMATION_SCHED_APPLY=0 + a sandboxed AUTOMATION_SYSTEMD_DIR
#               (unit files are written; systemctl is NOT called)
#   • schtasks  via a mock schtasks.exe on PATH (args logged)
# Plus: disabled-job no-op, install idempotency, uninstall, install-time preflight
# gating (--force bypass), and `run` delegating to run-job.sh.
#
# Run:  bash test/automation-scheduler.test.sh
set -uo pipefail

FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }
chk()  { if eval "$2"; then pass "$1"; else fail "$1 — [$2]"; fi; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_HOOKS="$REPO/claude_conf/hooks"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/auto-sched.XXXXXX")"
export HOME="$TMP/home"; mkdir -p "$HOME"
PROJ="$TMP/proj"; mkdir -p "$PROJ/.claude/agent"
cp -r "$SRC_HOOKS" "$PROJ/.claude/hooks"
export CLAUDE_PROJECT_DIR="$PROJ"
STATE_DIR="$(. "$PROJ/.claude/hooks/state-dir.sh" 2>/dev/null && printf '%s' "$STATE_DIR")"
rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
trap 'rm -rf "$TMP" "$STATE_DIR"' EXIT

SCHED="$PROJ/.claude/hooks/automation/scheduler.sh"

# Mock-binary dir goes FIRST on PATH from the start, so PATH-resolved mocks
# (schtasks.exe, gh, claude) shadow any real host binary in every section.
mkdir -p "$TMP/bin"; export PATH="$TMP/bin:$PATH"

# both schedulable jobs enabled; distinct times to prove the time flows through.
cat > "$PROJ/.claude/agent/config.json" <<'EOF'
{"role":"peer","automation":{
  "syncup":{"enabled":true,"time":"07:00"},
  "housekeeping":{"enabled":false,"time":"03:00"}
}}
EOF

# Preflight is not the unit under test in the backend cases → skip the external
# claude/gh probes there. Preflight itself is exercised in its own section.
export AUTOMATION_SKIP_CLAUDE_CHECK=1 AUTOMATION_SKIP_GH_CHECK=1

echo "== CRON backend =="
CRONSTORE="$TMP/crontab.txt"; : > "$CRONSTORE"
cat > "$TMP/bin/mockcron" <<EOF
#!/bin/bash
case "\${1:-}" in
  -l) cat "$CRONSTORE" 2>/dev/null ;;
  -)  cat > "$CRONSTORE" ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/mockcron"
export CRONTAB_CMD="$TMP/bin/mockcron"
CRON_ENV=(env AUTOMATION_SCHED_BACKEND=cron)

"${CRON_ENV[@]}" bash "$SCHED" install syncup --force >/dev/null 2>&1
chk "cron install wrote a marker line"        "grep -q 'claude-automation:.*:syncup' '$CRONSTORE'"
chk "cron line schedules 07:00 (min hr)"      "grep -Eq '^00 07 ' '$CRONSTORE'"
chk "cron line invokes run-job.sh syncup"     "grep -q 'run-job.sh. syncup' '$CRONSTORE'"
"${CRON_ENV[@]}" bash "$SCHED" install syncup --force >/dev/null 2>&1
chk "cron install idempotent (exactly one line)" "[ \"\$(grep -c 'claude-automation' '$CRONSTORE')\" -eq 1 ]"
"${CRON_ENV[@]}" bash "$SCHED" install housekeeping >/dev/null 2>&1
chk "disabled job is a no-op (no housekeeping line)" "! grep -q ':housekeeping' '$CRONSTORE'"
"${CRON_ENV[@]}" bash "$SCHED" uninstall syncup >/dev/null 2>&1
chk "cron uninstall removed the line"         "! grep -q 'claude-automation' '$CRONSTORE'"

echo "== SYSTEMD backend (file-gen only, APPLY=0) =="
SDIR="$TMP/systemd"
SD_ENV=(env AUTOMATION_SCHED_BACKEND=systemd AUTOMATION_SCHED_APPLY=0 AUTOMATION_SYSTEMD_DIR="$SDIR")
"${SD_ENV[@]}" bash "$SCHED" install syncup --force >/dev/null 2>&1
TIMER="$(ls "$SDIR"/*.timer 2>/dev/null | head -1)"
SERVICE="$(ls "$SDIR"/*.service 2>/dev/null | head -1)"
chk "systemd wrote a .timer"                  "[ -n \"$TIMER\" ] && [ -f \"$TIMER\" ]"
chk "systemd wrote a .service"                "[ -n \"$SERVICE\" ] && [ -f \"$SERVICE\" ]"
chk "OnCalendar reflects 07:00"               "grep -q 'OnCalendar=\\*-\\*-\\* 07:00:00' \"$TIMER\""
chk "Persistent=true (catch-up after downtime)" "grep -q 'Persistent=true' \"$TIMER\""
chk "RandomizedDelaySec set (no thundering herd)" "grep -q 'RandomizedDelaySec=' \"$TIMER\""
chk "ExecStart runs run-job.sh syncup"        "grep -q 'run-job.sh syncup' \"$SERVICE\""
chk "unit bakes CLAUDE_PROJECT_DIR (no env at 3 AM)" "grep -q \"Environment=CLAUDE_PROJECT_DIR=$PROJ\" \"$SERVICE\""
N1="$(ls "$SDIR" | wc -l)"
"${SD_ENV[@]}" bash "$SCHED" install syncup --force >/dev/null 2>&1
chk "systemd reinstall idempotent (still 2 files, rewrite not append)" "[ \"\$(ls '$SDIR' | wc -l)\" -eq \"$N1\" ]"
"${SD_ENV[@]}" bash "$SCHED" uninstall syncup >/dev/null 2>&1
chk "systemd uninstall removed both unit files" "[ -z \"\$(ls '$SDIR' 2>/dev/null)\" ]"

echo "== SCHTASKS backend (mock schtasks.exe) =="
SCHTASKLOG="$TMP/schtasks.log"; : > "$SCHTASKLOG"
cat > "$TMP/bin/schtasks.exe" <<EOF
#!/bin/bash
echo "\$*" >> "$SCHTASKLOG"
exit 0
EOF
chmod +x "$TMP/bin/schtasks.exe"
env AUTOMATION_SCHED_BACKEND=schtasks bash "$SCHED" install syncup --force >/dev/null 2>&1
chk "schtasks //Create called"      "grep -q '//Create' '$SCHTASKLOG'"
chk "schtasks scheduled //ST 07:00" "grep -q '//ST 07:00' '$SCHTASKLOG'"
chk "schtasks task name namespaced" "grep -q 'ClaudeUnicity' '$SCHTASKLOG'"

echo "== PREFLIGHT gating =="
# Force a failing gh (auth), keep claude skipped, cron backend: install without
# --force must FAIL; with --force must proceed.
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
[ "$1" = "auth" ] && exit 1
exit 0
EOF
chmod +x "$TMP/bin/gh"
: > "$CRONSTORE"
env AUTOMATION_SCHED_BACKEND=cron AUTOMATION_SKIP_CLAUDE_CHECK=1 AUTOMATION_SKIP_GH_CHECK=0 \
  bash "$SCHED" install syncup >/dev/null 2>&1
chk "preflight FAIL (gh unauth) blocks install w/o --force" "[ $? -ne 0 ] && ! grep -q claude-automation '$CRONSTORE'"
env AUTOMATION_SCHED_BACKEND=cron AUTOMATION_SKIP_CLAUDE_CHECK=1 AUTOMATION_SKIP_GH_CHECK=0 \
  bash "$SCHED" install syncup --force >/dev/null 2>&1
chk "--force installs despite preflight failure" "grep -q claude-automation '$CRONSTORE'"

echo "== status + run delegation =="
SOUT="$(env AUTOMATION_SCHED_BACKEND=cron bash "$SCHED" status syncup 2>&1 || true)"
chk "status reports the job line" 'echo "$SOUT" | grep -q "job=syncup"'
# `run` delegates to run-job.sh: enabled config + a mock claude → completed journal
cat > "$TMP/bin/claude" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMP/bin/claude"
env AUTOMATION_SCHED_BACKEND=cron bash "$SCHED" run syncup >/dev/null 2>&1
chk "scheduler run → run-job journals a completed run" \
  "[ \"\$(jq -r .status \"$STATE_DIR/automation/syncup/last-run.json\" 2>/dev/null)\" = completed ]"

echo
if [ "$FAIL" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit "$FAIL"
