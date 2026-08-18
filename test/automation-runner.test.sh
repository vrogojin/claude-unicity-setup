#!/bin/bash
# automation-runner.test.sh — hermetic proof of the headless-runner contract
# (run-job.sh, §2.3) plus the SessionStart surfacing hooks (automation-report.sh
# §2.6, automation-catchup.sh §2.5). No network, no real `claude`: a mock claude
# binary on PATH is driven per-test (ok / fail / sleep) and its invocations are
# counted from a log; STATE_DIR is sandboxed; the clock is faked with marker-file
# mtimes and an ancient last-run.json.
#
# Run:  bash test/automation-runner.test.sh
set -uo pipefail

FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }
chk()  { if eval "$2"; then pass "$1"; else fail "$1 — [$2]"; fi; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_HOOKS="$REPO/claude_conf/hooks"
AUTO="$SRC_HOOKS/automation"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/auto-run.XXXXXX")"
export HOME="$TMP/home"; mkdir -p "$HOME"
PROJ="$TMP/proj"; mkdir -p "$PROJ/.claude/agent"
cp -r "$SRC_HOOKS" "$PROJ/.claude/hooks"
export CLAUDE_PROJECT_DIR="$PROJ"
STATE_DIR="$(. "$PROJ/.claude/hooks/state-dir.sh" 2>/dev/null && printf '%s' "$STATE_DIR")"
rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
trap 'rm -rf "$TMP" "$STATE_DIR"' EXIT

RJ="$PROJ/.claude/hooks/automation/run-job.sh"
REPORT="$PROJ/.claude/hooks/automation/automation-report.sh"
CATCHUP="$PROJ/.claude/hooks/automation/automation-catchup.sh"
LR() { printf '%s' "$STATE_DIR/automation/$1/last-run.json"; }

# mock claude on PATH: mode baked in at creation; logs one line per invocation.
mkdir -p "$TMP/bin"; export PATH="$TMP/bin:$PATH"
mk_claude() { # $1 = ok|fail|sleep
  cat > "$TMP/bin/claude" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/claude-calls.log"
case "$1" in
  ok)    exit 0 ;;
  fail)  exit 3 ;;
  sleep) sleep 10 ;;
esac
EOF
  chmod +x "$TMP/bin/claude"
}
cfg() { printf '%s' "$1" > "$PROJ/.claude/agent/config.json"; }

echo "== T0: scripts parse (bash -n) =="
for f in run-job.sh automation-report.sh automation-catchup.sh scheduler.sh; do
  chk "bash -n $f" "bash -n '$AUTO/$f'"
done

echo "== T1: config gate — disabled job writes no journal, exits 0 =="
mk_claude ok
cfg '{"agent_nametag":"x"}'
bash "$RJ" syncup >/dev/null 2>&1
chk "disabled job → exit 0" "[ $? -eq 0 ]"
chk "disabled job wrote no journal" "[ ! -e \"$(LR syncup)\" ]"

echo "== T2: global kill switch =="
cfg '{"automation":{"syncup":{"enabled":true}}}'
AUTOMATION_DISABLE=1 bash "$RJ" syncup >/dev/null 2>&1
chk "AUTOMATION_DISABLE=1 wrote no journal" "[ ! -e \"$(LR syncup)\" ]"

echo "== T3: enabled syncup completes + journal shape =="
: > "$TMP/claude-calls.log"
bash "$RJ" syncup >/dev/null 2>&1
chk "status completed"        "[ \"\$(jq -r .status \"$(LR syncup)\")\" = completed ]"
chk "reported:false"          "[ \"\$(jq -r .reported \"$(LR syncup)\")\" = false ]"
chk "exit_code 0"             "[ \"\$(jq -r .exit_code \"$(LR syncup)\")\" = 0 ]"
chk "job field = syncup"      "[ \"\$(jq -r .job \"$(LR syncup)\")\" = syncup ]"
chk "artifacts is an array"   "jq -e '.artifacts|type==\"array\"' \"$(LR syncup)\" >/dev/null"
chk "claude invoked exactly once" "[ \"\$(wc -l < \"$TMP/claude-calls.log\")\" -eq 1 ]"
chk "launched the /syncup skill"  "grep -q '/syncup' \"$TMP/claude-calls.log\""
chk "passed --max-turns"          "grep -q -- '--max-turns' \"$TMP/claude-calls.log\""

echo "== T4: overlap lock → skipped_overlap =="
exec 8>"$STATE_DIR/automation/syncup.lock"; flock -n 8
bash "$RJ" syncup >/dev/null 2>&1
chk "held lock → skipped_overlap" "[ \"\$(jq -r .status \"$(LR syncup)\")\" = skipped_overlap ]"
exec 8>&-

echo "== T5: wall-clock timeout =="
mk_claude sleep
AUTOMATION_WALL_OVERRIDE=1s bash "$RJ" syncup >/dev/null 2>&1
chk "timeout status"        "[ \"\$(jq -r .status \"$(LR syncup)\")\" = timeout ]"
chk "timeout exit_code 124" "[ \"\$(jq -r .exit_code \"$(LR syncup)\")\" = 124 ]"

echo "== T6: failure + retry-once semantics =="
mk_claude fail
: > "$TMP/claude-calls.log"
cfg '{"automation":{"syncup":{"enabled":true,"retry_once":true}}}'
bash "$RJ" syncup >/dev/null 2>&1
chk "failed job → status failed"                 "[ \"\$(jq -r .status \"$(LR syncup)\")\" = failed ]"
chk "retry_once=true → claude ran twice"         "[ \"\$(wc -l < \"$TMP/claude-calls.log\")\" -eq 2 ]"
: > "$TMP/claude-calls.log"
cfg '{"automation":{"housekeeping":{"enabled":true,"retry_once":false,"max_turns":10}}}'
bash "$RJ" housekeeping >/dev/null 2>&1
chk "retry_once=false → claude ran once (no restart at 7 AM)" "[ \"\$(wc -l < \"$TMP/claude-calls.log\")\" -eq 1 ]"

echo "== T7: journals older than 14 days are reaped =="
mk_claude ok
cfg '{"automation":{"syncup":{"enabled":true}}}'
mkdir -p "$STATE_DIR/automation/syncup"
OLDJ="$STATE_DIR/automation/syncup/run-ancient.json"
echo '{"reported":true}' > "$OLDJ"; touch -d '30 days ago' "$OLDJ"
bash "$RJ" syncup >/dev/null 2>&1
chk "journal >14d reaped on next run" "[ ! -e \"$OLDJ\" ]"

echo "== T8: automation-report.sh surfaces + marks reported =="
OUT="$(echo '{}' | bash "$REPORT")"
chk "report emits SessionStart additionalContext" "echo \"\$OUT\" | jq -e '.hookSpecificOutput.hookEventName==\"SessionStart\"' >/dev/null"
chk "report mentions the syncup job"               "echo \"\$OUT\" | jq -r .hookSpecificOutput.additionalContext | grep -q syncup"
LEFT="$(find "$STATE_DIR/automation" -name 'run-*.json' -exec jq -r '.reported' {} \; 2>/dev/null | grep -c false || true)"
chk "all journals now marked reported:true"        "[ \"\$LEFT\" -eq 0 ]"
OUT2="$(echo '{}' | bash "$REPORT")"
chk "report idempotent (nothing unreported → empty)" "[ -z \"\$OUT2\" ]"

echo "== T9: automation-catchup.sh missed-run fallback =="
cfg '{"automation":{"syncup":{"enabled":true}}}'
printf '{"job":"syncup","status":"completed","started_at":"2020-01-01T00:00:00Z"}' > "$(LR syncup)"
rm -f "$STATE_DIR/automation/syncup/.catchup-cooldown"
OUT="$(echo '{}' | AUTOMATION_CATCHUP_APPLY=0 bash "$CATCHUP")"
chk "catchup surfaces stale syncup"        "echo \"\$OUT\" | jq -r .hookSpecificOutput.additionalContext | grep -q 'syncup missed'"
chk "catchup wrote a cooldown marker"      "[ -e \"$STATE_DIR/automation/syncup/.catchup-cooldown\" ]"
OUT2="$(echo '{}' | AUTOMATION_CATCHUP_APPLY=0 bash "$CATCHUP")"
chk "catchup cooldown suppresses re-fire"  "[ -z \"\$OUT2\" ]"
# a fresh last-run (native catch-up already ran) → no catch-up even without cooldown
rm -f "$STATE_DIR/automation/syncup/.catchup-cooldown"
printf '{"job":"syncup","status":"completed","started_at":"%s"}' "$(date -u +%FT%TZ)" > "$(LR syncup)"
OUT3="$(echo '{}' | AUTOMATION_CATCHUP_APPLY=0 bash "$CATCHUP")"
chk "fresh last-run → no catch-up fired"   "[ -z \"\$OUT3\" ]"

echo
if [ "$FAIL" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit "$FAIL"
