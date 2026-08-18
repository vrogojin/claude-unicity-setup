#!/bin/bash
# sweep-scope.sh <repo> — deterministic commit-grouping for the nightly sweep
# (design §5.4 step 1). Emits candidate THEMES over the scope window as JSON on
# stdout; the /housekeeping skill picks ≤ max_items of them and does the final
# semantic grouping. This helper only supplies the raw material — it never
# decides what to change.
#
# Scope floor = the recorded last-sweep.sha (marker) .. origin/main, additionally
# capped to scope_days of look-back (whichever floor is *more recent* wins, so a
# long-idle repo still only sweeps the last scope_days). A theme is a top-level
# path prefix (with a light subsystem split for deep monorepo dirs). Each theme
# carries its commits, files, a size proxy, and whether recent code landed with
# ZERO test delta (the sweep favors those — §5.4 step 1 ordering).
#
# Overrides (tests): AUTOMATION_STATE_DIR, SWEEP_MAIN_REF (default origin/main),
# SWEEP_DATE (unused here but kept for parity).
set -uo pipefail

SS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
SS_HOOKS_PARENT="$(cd "$SS_DIR/.." 2>/dev/null && pwd || echo .)"
if [ -n "${AUTOMATION_STATE_DIR:-}" ]; then
  STATE_DIR="$AUTOMATION_STATE_DIR"
else
  . "$SS_HOOKS_PARENT/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"
fi

MAIN_REF="${SWEEP_MAIN_REF:-origin/main}"
HK_DIR="$STATE_DIR/automation/housekeeping"

REPO="${1:-}"
[ -n "$REPO" ] || { echo "[sweep-scope] usage: sweep-scope.sh <repo>" >&2; exit 2; }
REPO="$(cd "$REPO" 2>/dev/null && pwd || echo "")"
if [ -z "$REPO" ] || ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "[sweep-scope] not a git repo: ${1:-}" >&2; exit 1
fi

CONFIG="$REPO/.claude/agent/config.json"
_cfg() { jq -r "$1" "$CONFIG" 2>/dev/null; }
SCOPE_DAYS="$(_cfg '.automation.housekeeping.scope_days')"; case "$SCOPE_DAYS" in ""|null) SCOPE_DAYS=7 ;; esac
MAX_ITEMS="$(_cfg '.automation.housekeeping.max_items')";  case "$MAX_ITEMS"  in ""|null) MAX_ITEMS=3 ;; esac

git -C "$REPO" rev-parse --verify -q "$MAIN_REF" >/dev/null 2>&1 \
  || { echo "[sweep-scope] $MAIN_REF does not resolve" >&2; exit 1; }
TO_SHA="$(git -C "$REPO" rev-parse "$MAIN_REF" 2>/dev/null)"

# Range floor: marker sha (if it is an ancestor of MAIN_REF), else the whole
# window. scope_days is ALWAYS enforced as a hard ceiling via --since.
MARKER_SHA="$(jq -r '.sha // empty' "$HK_DIR/last-sweep.json" 2>/dev/null || true)"
FROM_DESC=""
RANGE_ARGS=()
if [ -n "$MARKER_SHA" ] && git -C "$REPO" merge-base --is-ancestor "$MARKER_SHA" "$TO_SHA" 2>/dev/null; then
  RANGE_ARGS=("$MARKER_SHA..$TO_SHA"); FROM_DESC="$MARKER_SHA"
else
  RANGE_ARGS=("$TO_SHA"); FROM_DESC="(scope_days window)"
fi
SINCE="${SCOPE_DAYS} days ago"

# Collect commits (sha \x1f subject) within range AND within scope_days.
mapfile -t COMMITS < <(git -C "$REPO" log --no-merges --since="$SINCE" \
  --pretty=format:'%H%x1f%s' "${RANGE_ARGS[@]}" 2>/dev/null)

# Map a changed path to a theme: first path component, but split one level deeper
# for common monorepo roots so "backend" doesn't swallow everything.
_theme_of() {
  case "$1" in
    */*)
      local top="${1%%/*}" rest="${1#*/}"
      case "$top" in
        backend|capsules|packages|apps|services|crates|src|lib)
          printf '%s/%s' "$top" "${rest%%/*}" ;;
        *) printf '%s' "$top" ;;
      esac ;;
    *) printf '%s' "$1" ;;   # top-level file
  esac
}
_is_test_path() {
  case "$1" in
    */test/*|*/tests/*|*/__tests__/*|*.test.*|*_test.*|test_*.*|*.spec.*|*Test.java) return 0 ;;
    *) return 1 ;;
  esac
}

# Build the themes as a JSON object keyed by theme, then sort by our preference.
TMP="$(mktemp 2>/dev/null || echo "/tmp/sweep-scope.$$")"
trap 'rm -f "$TMP" "$TMP.themes"' EXIT
: > "$TMP.themes"

declare -A T_COMMITS T_FILES T_TESTDELTA T_SIZE
US=$'\x1f'; NL=$'\n'
for line in "${COMMITS[@]}"; do
  [ -n "$line" ] || continue
  sha="${line%%"$US"*}"; subj="${line#*"$US"}"
  # per-commit file list + numstat size
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    th="$(_theme_of "$f")"
    T_FILES["$th"]="${T_FILES[$th]:-}${f}${NL}"
    if _is_test_path "$f"; then T_TESTDELTA["$th"]=1; else T_TESTDELTA["$th"]="${T_TESTDELTA[$th]:-0}"; fi
    T_COMMITS["$th"]="${T_COMMITS[$th]:-}${sha}${US}${subj}${NL}"
  done < <(git -C "$REPO" diff-tree --no-commit-id --name-only -r --root "$sha" 2>/dev/null | sort -u)
  # size proxy = added+deleted lines per theme
  while IFS=$'\t' read -r add del f; do
    [ -n "${f:-}" ] || continue
    [ "$add" = "-" ] && add=0; [ "$del" = "-" ] && del=0
    th="$(_theme_of "$f")"
    T_SIZE["$th"]=$(( ${T_SIZE[$th]:-0} + add + del ))
  done < <(git -C "$REPO" diff-tree --no-commit-id --numstat -r --root "$sha" 2>/dev/null)
done

# Emit JSON. dedup commit+file lists; has_test_delta true iff a test path moved.
{
  printf '{'
  printf '"range":{"from":%s,"to":%s},' "$(jq -Rn --arg v "$FROM_DESC" '$v')" "$(jq -Rn --arg v "$TO_SHA" '$v')"
  printf '"scope_days":%s,"max_items":%s,"themes":[' "$SCOPE_DAYS" "$MAX_ITEMS"
  first=1
  # preference order: code-with-no-test-delta first, then by size desc.
  for th in "${!T_FILES[@]}"; do
    td=0; [ "${T_TESTDELTA[$th]:-0}" = "1" ] && td=1
    printf '%s\t%s\t%s\n' "$td" "${T_SIZE[$th]:-0}" "$th"
  done | sort -t$'\t' -k1,1n -k2,2nr | while IFS=$'\t' read -r td size th; do
    [ -n "$th" ] || continue
    files_json="$(printf '%s' "${T_FILES[$th]}" | sort -u | sed '/^$/d' | jq -R . | jq -s .)"
    commits_json="$(printf '%s' "${T_COMMITS[$th]}" | sed '/^$/d' | sort -u \
      | jq -R 'split("\u001f") | {sha: .[0], subject: (.[1] // "")}' | jq -s .)"
    hasdelta=$([ "$td" = "1" ] && echo true || echo false)
    [ "$first" = "1" ] || printf ','
    first=0
    jq -cn --arg theme "$th" --argjson commits "${commits_json:-[]}" \
       --argjson files "${files_json:-[]}" --argjson size "${size:-0}" \
       --argjson hasdelta "$hasdelta" \
       '{theme:$theme, commits:$commits, files:$files, size:$size, has_test_delta:$hasdelta}'
  done
  printf ']}'
} 2>/dev/null

echo
exit 0
