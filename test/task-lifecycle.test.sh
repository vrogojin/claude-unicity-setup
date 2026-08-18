#!/bin/bash
# task-lifecycle.test.sh — hermetic proof of F2 (Group C). No network, no real gh:
# a mock `gh` on PATH is driven from fixture files and its calls are logged; a
# scratch git repo backs the branch-bind / PR-detect / gate paths; STATE_DIR is
# sandboxed. Covers:
#   T1  classifier PARITY — the factored lib vs the pre-refactor inline pipeline,
#       across a corpus (proves the C1 refactor is behavior-preserving).
#   T2  start-detect state machine — open, nudge-once, dismiss-suppression.
#   T3  branch-bind (PostToolUse) — newest unbound open task binds the branch.
#   T4  PR-detect — a bound branch with a PR stamps the record.
#   T5  ticketer dedup — an existing marker match comments instead of re-creating.
#   T6  ticketer cap — refuses beyond max_new_tickets_per_day with exit 3.
#   T7  gate #15 — blocks on a shipped-unclosed task, clears when complete / trivial.
#
# Run:  bash test/task-lifecycle.test.sh
#
# shellcheck disable=SC2034  # OUT*/D*/CAP* are consumed inside chk "..." eval strings
# shellcheck disable=SC1090  # sourcing the classifier lib by resolved path is intentional
set -uo pipefail

FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }
chk()  { if eval "$2"; then pass "$1"; else fail "$1 — [$2]"; fi; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_HOOKS="$REPO/claude_conf/hooks"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tasklc.XXXXXX")"
export HOME="$TMP/home"; mkdir -p "$HOME"
PROJ="$TMP/proj"; mkdir -p "$PROJ/.claude/agent"
cp -r "$SRC_HOOKS" "$PROJ/.claude/hooks"
export CLAUDE_PROJECT_DIR="$PROJ"
STATE_DIR="$(. "$PROJ/.claude/hooks/state-dir.sh" 2>/dev/null && printf '%s' "$STATE_DIR")"
rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
trap 'rm -rf "$TMP" "$STATE_DIR"' EXIT

HOOK="$PROJ/.claude/hooks/task-lifecycle-check.sh"
DIAG="$PROJ/.claude/hooks/check-diagnostics.sh"
TICKETER="$PROJ/.claude/hooks/ticketer.sh"
LIB="$PROJ/.claude/hooks/lib/task-classifier.sh"
TL="$STATE_DIR/task-lifecycle.json"
cfg() { printf '%s' "$1" > "$PROJ/.claude/agent/config.json"; }
cfg '{"automation":{"lifecycle":{"enabled":true,"ticket_mode":"auto","max_new_tickets_per_day":3}}}'

# ── mock gh on PATH, driven by fixtures under $TMP/gh ──────────────────────────
mkdir -p "$TMP/bin" "$TMP/gh"; export PATH="$TMP/bin:$PATH"
echo '[]' > "$TMP/gh/issue-list.json"
echo '1' > "$TMP/gh/next-issue"
cat > "$TMP/bin/gh" <<'GHEOF'
#!/bin/bash
GHD="$TMPGHD"
echo "$*" >> "$GHD/calls.log"
sub="$1 ${2:-}"
case "$sub" in
  "issue list")
    cat "$GHD/issue-list.json" ;;
  "issue create")
    n="$(cat "$GHD/next-issue" 2>/dev/null || echo 1)"
    echo $((n+1)) > "$GHD/next-issue"
    echo "https://github.com/o/r/issues/$n" ;;
  "issue comment") exit 0 ;;
  "issue close")   exit 0 ;;
  "issue view")
    # gh issue view <n> --json id -q .id
    echo "I_kwFAKE$3" ;;
  "repo view")
    # any --json .../-q variant: emit the one field callers ask for
    case "$*" in
      *nameWithOwner*) echo "o/r" ;;
      *owner*)         echo "o" ;;
      *name*)          echo "r" ;;
      *)               echo "o/r" ;;
    esac ;;
  "pr view")
    br="$3"; f="$GHD/pr-$br.json"
    [ -f "$f" ] && { cat "$f"; exit 0; } || exit 1 ;;
  "api")
    # graphql / rest: succeed quietly (board is best-effort in these tests)
    exit 0 ;;
  *) exit 0 ;;
esac
GHEOF
sed -i "s#\$TMPGHD#$TMP/gh#" "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"

echo "== T0: scripts parse (bash -n) =="
for f in task-lifecycle-check.sh ticketer.sh check-diagnostics.sh recall-prior-work.sh lib/task-classifier.sh; do
  chk "bash -n $f" "bash -n '$PROJ/.claude/hooks/$f'"
done

# ── T1: classifier parity ─────────────────────────────────────────────────────
# Oracle = the EXACT pre-refactor pipeline recall-prior-work.sh shipped inline.
echo "== T1: classifier parity (factored lib == old inline pipeline) =="
. "$LIB"
oracle_intent() {
  case "$1" in /*) return 1;; esac
  [ "${#1}" -ge 20 ] || return 1
  echo "$1" | grep -qiE '\b(implement|build|add|create|fix|wire|integrate|support|introduce|rework|refactor|feature|bug)\b' || return 1
}
O_STOP='the|this|that|with|from|into|when|then|than|them|they|there|should|would|could|please|need|needs|want|wants|make|makes|have|does|will|about|also|just|like|some|more|only|very|it|its|our|your|their|and|for|not|but|can|now|new|use|using|been|were|what|which|where|how|why|all|each|via|per|still|implement|build|add|create|fix|wire|integrate|support|introduce|rework|refactor|feature|bug'
oracle_kw() { echo "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' '\n' | grep -E '^.{4,}$' | grep -vwE "$O_STOP" | awk '!seen[$0]++' | head -6; }
oracle_hash() { printf '%s' "$1" | sha1sum | cut -c1-16; }

CORPUS=(
  "add a dark mode toggle to the settings screen"
  "implement the reverse geocoding address enrichment for get_location"
  "fix the consent grant-on-use fail-closed regression"
  "refactor the aggregator storage layer into smaller modules"
  "what time is it in Tokyo right now"
  "/roadmap-sync please"
  "add x"
  "Build the WEBHOOK Retry-Queue with exponential-backoff!!"
  "wire up Stripe billing and the subscription cancel flow"
  "support NIP-17 gift-wrapped messages in the transport"
  "just tweak the color"
  "integrate the compute sandbox behind COMPUTE_ENABLED flag"
)
PARITY_OK=1
for p in "${CORPUS[@]}"; do
  oi=0; oracle_intent "$p" && oi=1
  ni=0; tc_intent_ok "$p" && ni=1
  [ "$oi" = "$ni" ] || { PARITY_OK=0; echo "    intent mismatch: [$p] old=$oi new=$ni"; }
  ok="$(oracle_kw "$p")"; nk="$(tc_keywords "$p")"
  [ "$ok" = "$nk" ] || { PARITY_OK=0; echo "    kw mismatch: [$p]"; diff <(printf '%s' "$ok") <(printf '%s' "$nk") | sed 's/^/      /'; }
  oh="$(oracle_hash "$ok")"; nh="$(tc_task_id "$nk")"
  [ "$oh" = "$nh" ] || { PARITY_OK=0; echo "    hash mismatch: [$p] old=$oh new=$nh"; }
done
chk "classifier parity across ${#CORPUS[@]} prompts" "[ $PARITY_OK -eq 1 ]"

# ── T2: start-detect state machine ────────────────────────────────────────────
echo "== T2: start-detect — open / nudge-once / dismiss-suppression =="
rm -f "$TL"
P='{"hook_event_name":"UserPromptSubmit","prompt":"add a dark mode toggle to the settings screen"}'
OUT1="$(printf '%s' "$P" | bash "$HOOK")"
chk "first task prompt emits a /task-start nudge" "printf '%s' \"\$OUT1\" | grep -q task-start"
chk "state records one open task" "[ \"\$(jq -r '[.tasks[]|select(.status==\"open\")]|length' \"$TL\")\" = 1 ]"
TID="$(jq -r '.tasks[0].task_id' "$TL")"
OUT2="$(printf '%s' "$P" | bash "$HOOK")"
chk "same prompt again is silent (nudge once per task_id)" "[ -z \"\$OUT2\" ]"
# Non-task prompt: no record, no output.
OUTQ="$(printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"what time is it in Tokyo"}' | bash "$HOOK")"
chk "question prompt emits nothing" "[ -z \"\$OUTQ\" ]"
chk "question prompt added no task" "[ \"\$(jq -r '.tasks|length' \"$TL\")\" = 1 ]"
# Dismiss the task, then re-prompt within 24h → suppressed.
jq -c --arg id "$TID" --arg now "$(date -u +%FT%TZ)" '.tasks|=map(if .task_id==$id then .status="dismissed"|.completed_at=$now else . end)' "$TL" > "$TL.x" && mv "$TL.x" "$TL"
OUT3="$(printf '%s' "$P" | bash "$HOOK")"
chk "dismissed <24h suppresses re-nudge" "[ -z \"\$OUT3\" ]"

# ── scratch git repo for T3/T4 ────────────────────────────────────────────────
git -C "$PROJ" init -q 2>/dev/null
git -C "$PROJ" config user.email t@t.t; git -C "$PROJ" config user.name t
git -C "$PROJ" add -A >/dev/null 2>&1; git -C "$PROJ" commit -qm init >/dev/null 2>&1
git -C "$PROJ" branch -M main >/dev/null 2>&1
POST='{"hook_event_name":"PostToolUse","tool_name":"Bash"}'

echo "== T3: branch-bind — newest unbound open task binds the feature branch =="
# Fresh open task, on a feature branch with a commit.
printf '{"tasks":[{"task_id":"aaa","title_guess":"t","keywords":["x"],"status":"open","branch":null,"ticket":null,"pr":null,"pr_state":null,"started_at":"2020-01-01T00:00:00Z","completed_at":null}]}' > "$TL"
git -C "$PROJ" checkout -q -b feat/darkmode 2>/dev/null
echo change > "$PROJ/f1.txt"; git -C "$PROJ" add -A >/dev/null 2>&1; git -C "$PROJ" commit -qm work >/dev/null 2>&1
rm -f "$STATE_DIR/task-lifecycle-head"
printf '%s' "$POST" | bash "$HOOK" >/dev/null 2>&1
chk "open task bound to feat/darkmode" "[ \"\$(jq -r '.tasks[0].branch' \"$TL\")\" = feat/darkmode ]"

echo "== T4: PR-detect — a bound branch with a PR stamps the record =="
mkdir -p "$TMP/gh/pr-feat"   # branch name feat/darkmode → fixture pr-feat/darkmode.json
printf '{"number":42,"state":"OPEN"}' > "$TMP/gh/pr-feat/darkmode.json"
# HEAD must move for the hook to re-evaluate.
echo more > "$PROJ/f2.txt"; git -C "$PROJ" add -A >/dev/null 2>&1; git -C "$PROJ" commit -qm more >/dev/null 2>&1
printf '%s' "$POST" | bash "$HOOK" >/dev/null 2>&1
chk "PR #42 stamped on the bound task" "[ \"\$(jq -r '.tasks[0].pr' \"$TL\")\" = 42 ]"

# ── T5/T6: ticketer ───────────────────────────────────────────────────────────
echo "== T5: ticketer dedup — marker match comments, does not re-create =="
: > "$TMP/gh/calls.log"; echo '100' > "$TMP/gh/next-issue"
# An existing issue already carries the marker for task id ddd.
printf '[{"number":7,"title":"old","body":"blah <!-- unicity-task: ddd --> more","state":"open"}]' > "$TMP/gh/issue-list.json"
OUTC="$(bash "$TICKETER" create --title "New" --body "b" --task-id ddd)"; RCC=$?
chk "dedup returns the existing number (#7)" "[ \"\$OUTC\" = 7 ]"
chk "dedup exit 0" "[ $RCC -eq 0 ]"
chk "dedup did NOT call issue create" "! grep -q 'issue create' \"$TMP/gh/calls.log\""
chk "dedup DID call issue comment" "grep -q 'issue comment' \"$TMP/gh/calls.log\""

echo "== T6: ticketer daily cap — exit 3 beyond max_new_tickets_per_day =="
echo '[]' > "$TMP/gh/issue-list.json"      # no dedup matches → real creates
rm -f "$STATE_DIR/automation/tickets-created-"*
cfg '{"automation":{"lifecycle":{"enabled":true,"ticket_mode":"auto","max_new_tickets_per_day":2}}}'
r1=$(bash "$TICKETER" create --title A --body a --task-id t1 >/dev/null 2>&1; echo $?)
r2=$(bash "$TICKETER" create --title B --body b --task-id t2 >/dev/null 2>&1; echo $?)
r3=$(bash "$TICKETER" create --title C --body c --task-id t3 >/dev/null 2>&1; echo $?)
chk "first create under cap → exit 0" "[ $r1 -eq 0 ]"
chk "second create at cap edge → exit 0" "[ $r2 -eq 0 ]"
chk "third create over cap → exit 3" "[ $r3 -eq 3 ]"
CAPOUT="$(bash "$TICKETER" cap-status 2>/dev/null)"; CAPRC=$?
chk "cap-status reports 2/2 and exit 3" "[ \"\$CAPOUT\" = '2/2' ] && [ \$CAPRC -eq 3 ]"

# ── T7: gate #15 ──────────────────────────────────────────────────────────────
echo "== T7: gate #15 — blocks on shipped-unclosed, clears on complete/trivial =="
STOP='{"hook_event_name":"Stop","stop_hook_active":false}'
NOW="$(date -u +%FT%TZ)"
# Shipped (pr set) + open → must block.
printf '{"tasks":[{"task_id":"g1","title_guess":"dark mode","keywords":["x"],"status":"open","branch":"feat/darkmode","ticket":9,"pr":42,"pr_state":"OPEN","started_at":"%s","completed_at":null}]}' "$NOW" > "$TL"
D1="$(printf '%s' "$STOP" | bash "$DIAG" 2>/dev/null)"
chk "gate #15 blocks a shipped-unclosed task" "printf '%s' \"\$D1\" | jq -e '.decision==\"block\"' >/dev/null && printf '%s' \"\$D1\" | grep -q task-complete"
# Mark complete → no block.
jq -c '.tasks|=map(.status="complete"|.completed_at="'"$NOW"'")' "$TL" > "$TL.x" && mv "$TL.x" "$TL"
D2="$(printf '%s' "$STOP" | bash "$DIAG" 2>/dev/null)"
chk "completed task does not block" "! printf '%s' \"\$D2\" | grep -q task-complete"
# Open task WITHOUT a pr (not shipped yet) → must NOT block.
printf '{"tasks":[{"task_id":"g2","title_guess":"t","keywords":["x"],"status":"open","branch":"feat/x","ticket":null,"pr":null,"pr_state":null,"started_at":"%s","completed_at":null}]}' "$NOW" > "$TL"
D3="$(printf '%s' "$STOP" | bash "$DIAG" 2>/dev/null)"
chk "un-shipped task does not block (no wedge on in-flight work)" "! printf '%s' \"\$D3\" | grep -q task-complete"
# Stale shipped task (older than TTL) → must NOT block.
OLD="$(date -u -d '-100 hours' +%FT%TZ 2>/dev/null || echo 2000-01-01T00:00:00Z)"
printf '{"tasks":[{"task_id":"g3","title_guess":"t","keywords":["x"],"status":"open","branch":"feat/x","ticket":9,"pr":42,"pr_state":"OPEN","started_at":"%s","completed_at":null}]}' "$OLD" > "$TL"
D4="$(printf '%s' "$STOP" | bash "$DIAG" 2>/dev/null)"
chk "stale shipped task past TTL does not wedge" "! printf '%s' \"\$D4\" | grep -q task-complete"

echo
if [ "$FAIL" -eq 0 ]; then printf '\033[32mALL TASK-LIFECYCLE TESTS PASSED\033[0m\n'; else printf '\033[31mSOME TESTS FAILED\033[0m\n'; fi
exit $FAIL
