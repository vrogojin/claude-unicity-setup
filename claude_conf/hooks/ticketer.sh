#!/bin/bash
# ticketer.sh — the ONE place that touches GitHub for task tickets (C3, design §4.4).
# Deterministic shell, called by SKILLS (never by hooks directly). Shared library:
# F2 (/task-start, /task-complete), F1 (syncup bug-report path), and F3 (nightly
# sweep PRs) all file tickets THROUGH here, so marker-dedup, the `agent:auto`
# audit label, and the daily creation cap are GLOBAL across all three features and
# cannot be forgotten in any one caller.
#
# ─── CLI (stable interface B and D integrate against) ────────────────────────
#
#   ticketer.sh find    --task-id <id> | --keywords "a b c"
#       Search open+closed issues for an existing ticket. Marker match first
#       (exact, survives title edits), then keyword match (>= half the keywords
#       present in title/body). Prints matching issue number(s), one per line,
#       most-recent first.  Exit 0 = at least one match printed; 1 = none.
#
#   ticketer.sh create  --title T (--body-file F | --body S) --task-id <id> [--label L]
#       Idempotent create. FIRST runs `find --task-id`; on a hit it degrades to a
#       `comment` on the existing issue (no new issue, no cap spend) and prints
#       that number. Otherwise: enforces the daily cap; embeds the HTML marker
#       "<!-- unicity-task: <id> -->" in the body; creates the issue; attaches the
#       `agent:auto` label (+ any --label); bumps the day counter. Prints the new
#       issue number.
#       Exit 0 = created or deduped-to-comment; 3 = daily cap reached (nothing
#       created — caller should fall back to ONE digest, per §4.4); 2 = usage.
#
#   ticketer.sh comment <n> (--body-file F | --body S)
#       Post a progress comment. Exit 0 ok, 2 usage, 5 gh failure.
#
#   ticketer.sh board   <n> --status "In progress|Done|Paused|Backlog|In review"
#       Set the issue's Projects v2 Status via `gh api graphql` (the proven
#       pattern — NOT `gh issue edit` fields, NOT `gh project` which is absent in
#       some gh builds). Adds the issue to the board if needed (idempotent).
#       Best-effort: exit 0 ok; 4 = no board / no matching status / graphql
#       unreachable (the caller notes "board not updated" and carries on — a board
#       miss never fails task tracking). 2 usage.
#       Project discovery: env TICKETER_PROJECT_OWNER + TICKETER_PROJECT_NUMBER
#       pin it; else the repo owner's first projectV2 whose title contains the
#       repo name, else their first projectV2.
#
#   ticketer.sh cap-status
#       Print "<used>/<max>" for today. Exit 0 = under cap; 3 = at/over cap.
#
# ─── State / config ──────────────────────────────────────────────────────────
#   Daily counter:  $STATE_DIR/automation/tickets-created-<YYYY-MM-DD>  (integer)
#   Config (read-only): $CLAUDE_PROJECT_DIR/.claude/agent/config.json
#       .automation.lifecycle.max_new_tickets_per_day   (default 3)
#       .automation.lifecycle.ticket_mode               (propose|auto; informational
#            here — the propose/auto DECISION is the skill's, ticketer only enforces
#            the cap and dedup mechanically)
#   All counter writes are flock-guarded read-modify-write with tmp+mv (fail-closed).
#
# Env for tests:  gh is stubbed on PATH; TICKETER_TODAY overrides the date;
#   TICKETER_PROJECT_* pin the board; nothing here reaches the network on its own.
set -uo pipefail

TK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$TK_DIR/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"

_tk_err() { echo "[ticketer] $*" >&2; }
PROJ="${CLAUDE_PROJECT_DIR:-$(cd "$TK_DIR/../.." 2>/dev/null && pwd || echo .)}"
CONFIG="$PROJ/.claude/agent/config.json"
MARKER_PREFIX="<!-- unicity-task:"

_tk_cfg() { jq -r "$1" "$CONFIG" 2>/dev/null; }
_tk_max_per_day() {
  local m; m="$(_tk_cfg '.automation.lifecycle.max_new_tickets_per_day')"
  case "$m" in ''|null|*[!0-9]*) m=3 ;; esac
  printf '%s' "$m"
}
_tk_today() { printf '%s' "${TICKETER_TODAY:-$(date -u +%F)}"; }
_tk_counter_file() { printf '%s/automation/tickets-created-%s' "$STATE_DIR" "$(_tk_today)"; }
_tk_count_used() { local f; f="$(_tk_counter_file)"; [ -f "$f" ] && tr -dc '0-9' < "$f" 2>/dev/null || printf '0'; }

# Atomically bump today's counter under flock. Prints the new value.
_tk_count_bump() {
  local f lock cur new
  f="$(_tk_counter_file)"; mkdir -p "$(dirname "$f")" 2>/dev/null || true
  lock="$f.lock"
  exec 8>"$lock" 2>/dev/null || { _tk_err "cannot lock counter"; return 1; }
  flock 8 2>/dev/null || true
  cur="$( [ -f "$f" ] && tr -dc '0-9' < "$f" 2>/dev/null || printf '0' )"; [ -n "$cur" ] || cur=0
  new=$((cur + 1))
  printf '%s' "$new" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null || { _tk_err "counter write failed"; flock -u 8 2>/dev/null; return 1; }
  flock -u 8 2>/dev/null || true
  printf '%s' "$new"
}

# --- helpers to read a --flag value out of the remaining argv ---
# Usage: _tk_flag <name> "$@"   → prints the value of --name (empty if absent).
_tk_flag() {
  local want="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      "--$want") printf '%s' "${2:-}"; return 0 ;;
      "--$want="*) printf '%s' "${1#--$want=}"; return 0 ;;
    esac
    shift
  done
  return 0
}

# Resolve a body string from --body / --body-file (body-file wins if both given).
_tk_body() { # "$@"
  local bf b
  bf="$(_tk_flag body-file "$@")"
  if [ -n "$bf" ]; then
    [ -f "$bf" ] && cat "$bf" || { _tk_err "body-file not found: $bf"; return 1; }
    return 0
  fi
  b="$(_tk_flag body "$@")"
  printf '%s' "$b"
}

# gh presence gate — every subcommand needs it.
_tk_need_gh() { command -v gh >/dev/null 2>&1 || { _tk_err "gh not on PATH"; return 1; }; }

# ─── find ────────────────────────────────────────────────────────────────────
_tk_list_all() { # emits JSON array of {number,title,body,state}
  gh issue list --state all --limit 200 --json number,title,body,state 2>/dev/null || echo '[]'
}

_tk_find() {
  _tk_need_gh || return 2
  local task_id keywords
  task_id="$(_tk_flag task-id "$@")"
  keywords="$(_tk_flag keywords "$@")"
  [ -n "$task_id" ] || [ -n "$keywords" ] || { _tk_err "find needs --task-id or --keywords"; return 2; }

  local all; all="$(_tk_list_all)"
  local hits=""

  # 1. Marker match (exact) — the authoritative dedup key.
  if [ -n "$task_id" ]; then
    hits="$(printf '%s' "$all" | jq -r --arg m "unicity-task: $task_id" \
      '[.[] | select((.body // "") | contains($m))] | sort_by(.number) | reverse | .[].number' 2>/dev/null)"
  fi

  # 2. Keyword match (>= half present in title+body, case-insensitive), only if
  #    the marker found nothing — a marker hit is always preferred.
  if [ -z "$hits" ] && [ -n "$keywords" ]; then
    hits="$(printf '%s' "$all" | jq -r --arg kw "$keywords" '
      ($kw | ascii_downcase | split(" ") | map(select(length>0))) as $ks
      | ($ks | length) as $n
      | (if $n == 0 then 0 else (($n + 1) / 2 | floor) end) as $need
      | [ .[]
          | . as $i
          | (( ($i.title // "") + " " + ($i.body // "")) | ascii_downcase) as $hay
          | ($ks | map(select($hay | contains(.))) | length) as $got
          | select($need > 0 and $got >= $need)
        ] | sort_by(.number) | reverse | .[].number' 2>/dev/null)"
  fi

  [ -n "$hits" ] || return 1
  printf '%s\n' "$hits"
  return 0
}

# ─── label helpers (agent:auto audit label; gh label subcommand may be absent) ─
_tk_repo_slug() { gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null; }
_tk_ensure_label() { # <label>
  local slug; slug="$(_tk_repo_slug)"; [ -n "$slug" ] || return 0
  # Idempotent: create returns 422 if it already exists — swallow either way.
  gh api -X POST "repos/$slug/labels" -f "name=$1" -f "color=ededed" \
    -f "description=Created by an automation agent" >/dev/null 2>&1 || true
}
_tk_add_label() { # <issue> <label>
  local slug; slug="$(_tk_repo_slug)"; [ -n "$slug" ] || return 0
  gh api -X POST "repos/$slug/issues/$1/labels" -f "labels[]=$2" >/dev/null 2>&1 || true
}

# ─── comment ─────────────────────────────────────────────────────────────────
_tk_comment() {
  _tk_need_gh || return 2
  local num="${1:-}"; shift || true
  case "$num" in ''|*[!0-9]*) _tk_err "comment needs an issue number"; return 2 ;; esac
  local body; body="$(_tk_body "$@")" || return 2
  [ -n "$body" ] || { _tk_err "comment needs --body or --body-file"; return 2; }
  printf '%s' "$body" | gh issue comment "$num" --body-file - >/dev/null 2>&1 \
    || { _tk_err "gh issue comment #$num failed"; return 5; }
  printf '%s\n' "$num"
  return 0
}

# ─── create ──────────────────────────────────────────────────────────────────
_tk_create() {
  _tk_need_gh || return 2
  local title task_id extra_label
  title="$(_tk_flag title "$@")"
  task_id="$(_tk_flag task-id "$@")"
  extra_label="$(_tk_flag label "$@")"
  [ -n "$title" ] || { _tk_err "create needs --title"; return 2; }
  [ -n "$task_id" ] || { _tk_err "create needs --task-id"; return 2; }
  local body; body="$(_tk_body "$@")" || return 2

  # DEDUP: an existing marker match becomes a comment, never a second issue.
  local existing
  existing="$(_tk_find --task-id "$task_id" 2>/dev/null | head -1)"
  if [ -n "$existing" ]; then
    _tk_err "dedup: task $task_id already tracked by #$existing → commenting"
    local cbody
    cbody="$(printf '%s\n\n%s' "${body:-work continues}" "$MARKER_PREFIX $task_id -->")"
    printf '%s' "$cbody" | gh issue comment "$existing" --body-file - >/dev/null 2>&1 || true
    printf '%s\n' "$existing"
    return 0
  fi

  # CAP: refuse beyond the shared daily cap (distinct exit 3 → digest fallback).
  local used max; used="$(_tk_count_used)"; max="$(_tk_max_per_day)"
  if [ "$used" -ge "$max" ] 2>/dev/null; then
    _tk_err "daily cap reached ($used/$max) — not creating; caller should digest"
    return 3
  fi

  # Embed the marker so future find --task-id dedups even after a title edit.
  local full; full="$(printf '%s\n\n%s' "$body" "$MARKER_PREFIX $task_id -->")"
  local url num
  url="$(printf '%s' "$full" | gh issue create --title "$title" --body-file - 2>/dev/null | tail -1)"
  num="$(printf '%s' "$url" | grep -oE '[0-9]+$')"
  [ -n "$num" ] || { _tk_err "gh issue create failed (no issue number in output: '$url')"; return 5; }

  _tk_count_bump >/dev/null || true
  _tk_ensure_label "agent:auto"; _tk_add_label "$num" "agent:auto"
  if [ -n "$extra_label" ]; then _tk_ensure_label "$extra_label"; _tk_add_label "$num" "$extra_label"; fi

  printf '%s\n' "$num"
  return 0
}

# ─── board (Projects v2 via gh api graphql) ──────────────────────────────────
# Discover project id + Status field id + option id for the requested status,
# then add the issue and set the field. Any gap → return 4 (best-effort).
_tk_board() {
  _tk_need_gh || return 2
  local num="${1:-}"; shift || true
  case "$num" in ''|*[!0-9]*) _tk_err "board needs an issue number"; return 2 ;; esac
  local want; want="$(_tk_flag status "$@")"
  [ -n "$want" ] || { _tk_err "board needs --status"; return 2; }

  local owner repo owner_type
  owner="${TICKETER_PROJECT_OWNER:-$(gh repo view --json owner -q .owner.login 2>/dev/null)}"
  repo="$(gh repo view --json name -q .name 2>/dev/null)"
  [ -n "$owner" ] || { _tk_err "board: cannot resolve repo owner"; return 4; }

  # projectsV2 live under either organization{} or user{}; probe org first.
  local pnum="${TICKETER_PROJECT_NUMBER:-}"
  local proj_json=""
  for root in organization user; do
    proj_json="$(gh api graphql -f query="query(\$o:String!){ $root(login:\$o){ projectsV2(first:30){ nodes{ number title id } } } }" -f o="$owner" 2>/dev/null)"
    printf '%s' "$proj_json" | jq -e ".data.$root.projectsV2.nodes" >/dev/null 2>&1 && { owner_type="$root"; break; }
    proj_json=""
  done
  [ -n "$proj_json" ] || { _tk_err "board: no projectsV2 under $owner"; return 4; }

  local project_id
  if [ -n "$pnum" ]; then
    project_id="$(printf '%s' "$proj_json" | jq -r --argjson n "$pnum" ".data.$owner_type.projectsV2.nodes[] | select(.number==\$n) | .id" 2>/dev/null | head -1)"
  else
    # First project whose title contains the repo name, else the first project.
    project_id="$(printf '%s' "$proj_json" | jq -r --arg r "${repo:-}" '
      (.data | to_entries[0].value.projectsV2.nodes) as $ns
      | ( [ $ns[] | select(($r|length)>0 and ((.title|ascii_downcase)|contains($r|ascii_downcase))) ][0] // $ns[0] )
      | .id // empty' 2>/dev/null)"
  fi
  [ -n "$project_id" ] || { _tk_err "board: no project id resolved"; return 4; }

  # Status single-select field + its options.
  local field_json field_id
  field_json="$(gh api graphql -f query='query($p:ID!){ node(id:$p){ ... on ProjectV2 { field(name:"Status"){ ... on ProjectV2SingleSelectField { id options{ id name } } } } } }' -f p="$project_id" 2>/dev/null)"
  field_id="$(printf '%s' "$field_json" | jq -r '.data.node.field.id // empty' 2>/dev/null)"
  [ -n "$field_id" ] || { _tk_err "board: no Status field on project"; return 4; }

  # Match the requested status to an option: exact (ci) first, then a fuzzy map
  # for the three canonical asks (In progress / Done / Paused).
  local opt_id
  opt_id="$(printf '%s' "$field_json" | jq -r --arg w "$want" '
    .data.node.field.options as $o
    | ($w|ascii_downcase) as $wl
    | ( [ $o[] | select((.name|ascii_downcase)==$wl) ][0]
        // ( if ($wl|test("progress")) then [ $o[] | select((.name|ascii_downcase)|test("progress")) ][0]
             elif ($wl|test("done|complete|merged")) then [ $o[] | select((.name|ascii_downcase)|test("done|complete")) ][0]
             elif ($wl|test("paus|hold|review|block")) then [ $o[] | select((.name|ascii_downcase)|test("paus|hold|review|block")) ][0]
             elif ($wl|test("backlog|todo|open")) then [ $o[] | select((.name|ascii_downcase)|test("backlog|todo")) ][0]
             else null end ) )
    | .id // empty' 2>/dev/null)"
  [ -n "$opt_id" ] || { _tk_err "board: no Status option matches '$want'"; return 4; }

  # Content node id → add item (idempotent-ish) → set the field value.
  local cid item_id
  cid="$(gh issue view "$num" --json id -q .id 2>/dev/null)"
  [ -n "$cid" ] || { _tk_err "board: cannot resolve content id for #$num"; return 4; }
  item_id="$(gh api graphql -f query='mutation($p:ID!,$c:ID!){ addProjectV2ItemById(input:{projectId:$p contentId:$c}){ item{ id } } }' -f p="$project_id" -f c="$cid" --jq '.data.addProjectV2ItemById.item.id' 2>/dev/null)"
  [ -n "$item_id" ] || { _tk_err "board: addProjectV2ItemById failed for #$num"; return 4; }
  gh api graphql -f query='mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){ updateProjectV2ItemFieldValue(input:{projectId:$p itemId:$i fieldId:$f value:{singleSelectOptionId:$o}}){ projectV2Item{ id } } }' \
    -f p="$project_id" -f i="$item_id" -f f="$field_id" -f o="$opt_id" >/dev/null 2>&1 \
    || { _tk_err "board: updateProjectV2ItemFieldValue failed for #$num"; return 4; }
  return 0
}

# ─── cap-status ──────────────────────────────────────────────────────────────
_tk_cap_status() {
  local used max; used="$(_tk_count_used)"; max="$(_tk_max_per_day)"
  printf '%s/%s\n' "$used" "$max"
  [ "$used" -ge "$max" ] 2>/dev/null && return 3
  return 0
}

# ─── dispatch ────────────────────────────────────────────────────────────────
CMD="${1:-}"; shift 2>/dev/null || true
case "$CMD" in
  find)       _tk_find "$@" ;;
  create)     _tk_create "$@" ;;
  comment)    _tk_comment "$@" ;;
  board)      _tk_board "$@" ;;
  cap-status) _tk_cap_status ;;
  ''|-h|--help|help)
    sed -n '2,60p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  *) _tk_err "unknown command: $CMD (find|create|comment|board|cap-status)"; exit 2 ;;
esac
exit $?
