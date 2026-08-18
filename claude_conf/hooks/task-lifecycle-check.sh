#!/bin/bash
# task-lifecycle-check.sh — F2 task-lifecycle detector (C2, design §4). Two events,
# one hook, one deterministic state machine at $STATE_DIR/task-lifecycle.json.
#
# Claude Code has no task events, so we synthesize them (design §4.1):
#
#   UserPromptSubmit  → START-DETECT. If the prompt passes the SHARED classifier
#       (lib/task-classifier.sh — the same intent+keyword logic recall uses), open
#       a task record keyed by its task_id and inject a ONE-TIME advisory nudge to
#       run /task-start. A record already tracked (or dismissed <24 h ago) stays
#       quiet — the nudge fires once per task_id.
#
#   PostToolUse(Bash) → BIND + PR-DETECT (async, HEAD-keyed like roadmap-sync).
#       When HEAD moves onto a feature branch and an open UNBOUND task exists, bind
#       the branch to it. When a bound branch acquires a PR (or is merged), stamp
#       the record so the Stop gate (#15 in check-diagnostics.sh) can nudge
#       /task-complete. Nothing here writes tickets, closes issues, or reasons
#       about duplicates — those need a skill (§4.3 boundary). Hooks classify,
#       track, and nudge; only /task-start and /task-complete act.
#
# NEVER blocks (both events are non-blocking; enforcement is the Stop gate). Always
# exits 0. All state writes are flock-guarded read-modify-write with tmp+mv.
# Records in terminal states (complete/dismissed) are reaped after 14 days.
#
# Env:
#   TASK_LIFECYCLE_DISABLE=1   turn the hook off entirely.
#   Escape hatch for the gate:  rm -f /tmp/claude/*/task-lifecycle.json
set -uo pipefail

[ "${TASK_LIFECYCLE_DISABLE:-0}" = "1" ] && exit 0

TL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$TL_DIR/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"
. "$TL_DIR/lib/task-classifier.sh" 2>/dev/null || exit 0

STATE_FILE="$STATE_DIR/task-lifecycle.json"
HEAD_MARK="$STATE_DIR/task-lifecycle-head"
NOTIFIED="$STATE_DIR/task-lifecycle-notified"
LOCK="$STATE_FILE.lock"
mkdir -p "$STATE_DIR" 2>/dev/null || true

NOW="$(date -u +%FT%TZ)"
NOW_TS="$(date +%s)"

INPUT="$(cat 2>/dev/null || echo '{}')"
EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null)"
# Fall back to shape sniffing if the event name is absent: a .prompt field means
# UserPromptSubmit; anything else on this hook is a PostToolUse.
if [ -z "$EVENT" ]; then
  if printf '%s' "$INPUT" | jq -e '.prompt' >/dev/null 2>&1; then EVENT="UserPromptSubmit"; else EVENT="PostToolUse"; fi
fi

# Read the current state (or an empty machine). Emitted on stdout.
_tl_read() {
  if [ -f "$STATE_FILE" ]; then jq -c '.' "$STATE_FILE" 2>/dev/null || echo '{"tasks":[]}'
  else echo '{"tasks":[]}'; fi
}

# Write state atomically under flock. Reads new JSON from stdin.
_tl_write() {
  local new; new="$(cat)"
  printf '%s' "$new" | jq -e '.' >/dev/null 2>&1 || return 1
  exec 7>"$LOCK" 2>/dev/null || return 1
  flock 7 2>/dev/null || true
  printf '%s' "$new" > "$STATE_FILE.tmp" 2>/dev/null && mv "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null
  local rc=$?
  flock -u 7 2>/dev/null || true
  return $rc
}

# Reap terminal (complete|dismissed) records older than 14 days. Operates on a
# JSON string arg, prints the reaped JSON.
_tl_reap() {
  printf '%s' "$1" | jq --arg now "$NOW" '
    def age($t): (($now|fromdateiso8601) - (($t // $now)|fromdateiso8601));
    .tasks |= map(select(
      (.status != "complete" and .status != "dismissed")
      or (age(.completed_at // .started_at) < (14*86400))
    ))' 2>/dev/null || printf '%s' "$1"
}

# ════════════════════════════════ START-DETECT ════════════════════════════════
if [ "$EVENT" = "UserPromptSubmit" ]; then
  PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)"
  [ -n "$PROMPT" ] || exit 0
  tc_is_task "$PROMPT" || exit 0

  KEYWORDS="$(tc_keywords "$PROMPT")"
  TASK_ID="$(tc_task_id "$KEYWORDS")"
  [ -n "$TASK_ID" ] || exit 0
  TITLE="$(printf '%s' "$PROMPT" | tr '\n' ' ' | cut -c1-80)"
  KW_JSON="$(printf '%s' "$KEYWORDS" | sed '/^$/d' | jq -R . 2>/dev/null | jq -s -c . 2>/dev/null)"
  [ -n "$KW_JSON" ] || KW_JSON='[]'

  STATE="$(_tl_read)"
  STATE="$(_tl_reap "$STATE")"

  # Existing record for this task_id?
  REC="$(printf '%s' "$STATE" | jq -c --arg id "$TASK_ID" '.tasks[] | select(.task_id==$id)' 2>/dev/null | head -1)"
  if [ -n "$REC" ]; then
    ST="$(printf '%s' "$REC" | jq -r '.status // "open"' 2>/dev/null)"
    if [ "$ST" = "dismissed" ]; then
      # Suppress re-prompting for these keywords for 24 h after a dismissal.
      DIS="$(printf '%s' "$REC" | jq -r '.completed_at // .started_at // ""' 2>/dev/null)"
      DTS=0; [ -n "$DIS" ] && DTS="$(date -d "$DIS" +%s 2>/dev/null || echo 0)"
      if [ $((NOW_TS - DTS)) -lt 86400 ] 2>/dev/null; then exit 0; fi
      # Older than 24 h → allow re-open below by treating as new.
    else
      # Already tracked and live → nudge exactly once (already nudged on open).
      exit 0
    fi
  fi

  # Upsert: replace any existing record for this id with a fresh open one.
  NEW="$(printf '%s' "$STATE" | jq -c --arg id "$TASK_ID" --arg t "$TITLE" \
        --argjson kw "$KW_JSON" --arg now "$NOW" '
        .tasks = ([ .tasks[] | select(.task_id != $id) ]
          + [ {task_id:$id, title_guess:$t, keywords:$kw, status:"open",
               branch:null, ticket:null, pr:null, pr_state:null,
               started_at:$now, completed_at:null, nudged_at:$now} ])' 2>/dev/null)"
  [ -n "$NEW" ] && printf '%s' "$NEW" | _tl_write

  KW_HINT="$(printf '%s' "$KEYWORDS" | sed '/^$/d' | head -3 | tr '\n' ' ' | sed 's/ $//')"
  CTX="TASK-LIFECYCLE (advisory): this prompt reads as a new task. Run /task-start to (1) judge whether it is really a task, (2) recall prior work on it (/recall-prior-work $KW_HINT), (3) if prior art exists, build ON TOP of it rather than replicate, and (4) find or open its tracking ticket. Skip if this is a question or a trivial tweak."
  jq -n --arg ctx "$CTX" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$ctx}}' 2>/dev/null
  exit 0
fi

# ═══════════════════════════ BIND + PR-DETECT (PostToolUse) ════════════════════
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

HEAD_SHA="$(git rev-parse HEAD 2>/dev/null)"
[ -n "$HEAD_SHA" ] || exit 0

# HEAD-move dedup: the full evaluation (git + gh) only runs when HEAD moves — cheap
# on the overwhelming majority of Bash calls (same trick as roadmap-sync-check.sh).
LAST_HEAD=""; [ -f "$HEAD_MARK" ] && LAST_HEAD="$(cat "$HEAD_MARK" 2>/dev/null)"
[ "$LAST_HEAD" = "$HEAD_SHA" ] && exit 0
printf '%s' "$HEAD_SHA" > "$HEAD_MARK" 2>/dev/null || true

# Only tasks currently in flight matter.
[ -f "$STATE_FILE" ] || exit 0
STATE="$(_tl_read)"; STATE="$(_tl_reap "$STATE")"
HAS_LIVE="$(printf '%s' "$STATE" | jq -r '[.tasks[] | select(.status=="open" or .status=="ticketed")] | length' 2>/dev/null)"
[ "${HAS_LIVE:-0}" -gt 0 ] 2>/dev/null || { printf '%s' "$STATE" | _tl_write; exit 0; }

# Base ref + current branch.
BASE_REF=""
for ref in main master; do git rev-parse --verify "$ref" >/dev/null 2>&1 && { BASE_REF="$ref"; break; }; done
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"

CHANGED=false

# --- BIND: on a feature branch with commits, bind the newest unbound live task ---
if [ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] && [ "$BRANCH" != "$BASE_REF" ]; then
  # Confirm the branch actually carries commits vs the base (real work, not just a
  # checkout) — mirrors roadmap-sync's three-dot scoping.
  HAS_COMMITS=1
  if [ -n "$BASE_REF" ]; then
    CNT="$(git rev-list --count "$BASE_REF..HEAD" 2>/dev/null || echo 0)"
    [ "${CNT:-0}" -gt 0 ] 2>/dev/null || HAS_COMMITS=0
  fi
  if [ "$HAS_COMMITS" = "1" ]; then
    # Is this branch already bound to some task?
    BOUND="$(printf '%s' "$STATE" | jq -r --arg b "$BRANCH" '[.tasks[] | select(.branch==$b)] | length' 2>/dev/null)"
    if [ "${BOUND:-0}" -eq 0 ] 2>/dev/null; then
      NEW="$(printf '%s' "$STATE" | jq -c --arg b "$BRANCH" --arg now "$NOW" '
        ( [ .tasks[] | select((.status=="open" or .status=="ticketed") and (.branch==null)) ]
          | sort_by(.started_at) | last | .task_id ) as $pick
        | if $pick == null then .
          else .tasks |= map(if .task_id==$pick then .branch=$b else . end) end' 2>/dev/null)"
      if [ -n "$NEW" ] && [ "$NEW" != "$STATE" ]; then STATE="$NEW"; CHANGED=true; fi
    fi
  fi
fi

# --- PR-DETECT: a bound live task whose branch has a PR (open or merged) --------
if command -v gh >/dev/null 2>&1; then
  # Every live task with a bound branch we haven't already resolved a PR for.
  while IFS= read -r tb; do
    [ -n "$tb" ] || continue
    PRJSON="$(gh pr view "$tb" --json number,state 2>/dev/null)"
    PNUM="$(printf '%s' "$PRJSON" | jq -r '.number // empty' 2>/dev/null)"
    PSTATE="$(printf '%s' "$PRJSON" | jq -r '.state // empty' 2>/dev/null)"
    [ -n "$PNUM" ] || continue
    NEW="$(printf '%s' "$STATE" | jq -c --arg b "$tb" --argjson n "$PNUM" --arg s "$PSTATE" '
      .tasks |= map(if .branch==$b and (.status=="open" or .status=="ticketed")
                    then .pr=$n | .pr_state=$s else . end)' 2>/dev/null)"
    if [ -n "$NEW" ] && [ "$NEW" != "$STATE" ]; then STATE="$NEW"; CHANGED=true; fi
  done <<EOF
$(printf '%s' "$STATE" | jq -r '.tasks[] | select((.status=="open" or .status=="ticketed") and .branch!=null and (.pr==null)) | .branch' 2>/dev/null)
EOF
fi

printf '%s' "$STATE" | _tl_write

# Notify once per HEAD when a shipped-but-unclosed task first appears (advisory;
# the real enforcement is Stop gate #15). Keyed on HEAD so we nudge only on change.
if [ "$CHANGED" = "true" ]; then
  PENDING="$(printf '%s' "$STATE" | jq -r '[.tasks[] | select((.status=="open" or .status=="ticketed") and .pr!=null)] | length' 2>/dev/null)"
  if [ "${PENDING:-0}" -gt 0 ] 2>/dev/null; then
    PREV=""; [ -f "$NOTIFIED" ] && PREV="$(cat "$NOTIFIED" 2>/dev/null)"
    if [ "$PREV" != "$HEAD_SHA" ] && [ -f "$TL_DIR/notify.sh" ]; then
      . "$TL_DIR/notify.sh" 2>/dev/null || true
      notify "Unicity: Task ready to close out" \
        "A tracked task shipped a PR. Run /task-complete to update its ticket, board, and ROADMAP." "normal" 2>/dev/null || true
      printf '%s' "$HEAD_SHA" > "$NOTIFIED" 2>/dev/null || true
    fi
  fi
fi

exit 0
