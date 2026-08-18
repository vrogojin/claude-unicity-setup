#!/bin/bash
# sweep-post.sh <worktree> <repo> [session-log] — the DETERMINISTIC post-phase of
# the nightly housekeeping sweep (design §5.4 wrapper post-phase + §5.6 report).
#
# This is the safety spine of F3: the MODEL never pushes and never opens a PR —
# THIS wrapper does, and only after every gate passes. In order:
#   1. branch guard      — refuse anything that isn't sweep/<date> (never main).
#   2. shipped themes     — map commits→theme via the `Sweep-Theme:` trailer.
#   3. FINAL green check   — build+test autodetect; red ⇒ ABORT, no PR (§5.4.5).
#   4. SECRET-SCAN the diff — private-key blocks / AKIA / ghp_ / bearer / nsec /
#                             .env|.secrets|agent additions ⇒ ABORT + CRITICAL
#                             alert, no push (§6 row 9). NON-NEGOTIABLE.
#   5. diff-cap            — over max_diff_lines ⇒ drop the LARGEST theme (revert,
#                            never truncate a hunk) and journal it (§5.4).
#   6. push sweep/* only   — the wrapper refuses to push any other ref (§6 row 5).
#   7. gh pr create        — ≤ max_prs, label sweep:auto.
#   8. morning-review report (§5.6): wrapper computes ALL numbers; the model only
#                            supplied what/why + residual-risk at hand-off. A
#                            missing model one-liner renders as the branch name,
#                            NEVER invented prose. Delivered on 3 channels:
#                            dated file (source of truth) → PR-body prepend →
#                            notify / SessionStart / owner-DM.
#   9. F2 registration     — best-effort via Group C's ticketer.sh (stubbed if
#                            absent); artifacts.json for the runner journal.
#  10. marker + worktree destroy.
#
# The night shipping NOTHING still emits a ❌ report — silence is
# indistinguishable from failure and is not allowed (§5.6).
#
# Exit codes (consumed by run-job.sh): 0 PR opened · 10 nothing shipped ·
# 20 aborted:red-tests · 21 aborted:secret · 30 push/PR failed.
#
# Test overrides: AUTOMATION_STATE_DIR, SWEEP_DATE, SWEEP_MAIN_REF,
# SWEEP_HANDOFF_DIR, SWEEP_TEST_CMD (force the green check: `true`/`false`/cmd),
# SWEEP_GH_BIN (mock gh), SWEEP_SKIP_PUSH=1 (skip the real git push), SWEEP_DATE.
set -uo pipefail

SP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
SP_HOOKS_PARENT="$(cd "$SP_DIR/.." 2>/dev/null && pwd || echo .)"
if [ -n "${AUTOMATION_STATE_DIR:-}" ]; then
  STATE_DIR="$AUTOMATION_STATE_DIR"
else
  . "$SP_HOOKS_PARENT/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"
fi
. "$SP_HOOKS_PARENT/notify.sh" 2>/dev/null || notify() { :; }

_sp_log() { echo "[sweep-post] $*" >&2; }

WT="${1:-}"; REPO="${2:-}"   # ($3 session-log is accepted for call-site parity but unused here)
[ -n "$WT" ] && [ -d "$WT" ]     || { _sp_log "usage: sweep-post.sh <worktree> <repo>"; exit 2; }
[ -n "$REPO" ] && [ -d "$REPO" ] || { _sp_log "no repo dir: $REPO"; exit 2; }

MAIN_REF="${SWEEP_MAIN_REF:-origin/main}"
HK_DIR="$STATE_DIR/automation/housekeeping"
HANDOFF="${SWEEP_HANDOFF_DIR:-$HK_DIR/handoff}"
GH="${SWEEP_GH_BIN:-gh}"
WT_SH="$SP_DIR/sweep-worktree.sh"
mkdir -p "$HK_DIR" 2>/dev/null || true

# config caps (§2.7 defaults)
CONFIG="$REPO/.claude/agent/config.json"
_cfg() { jq -r "$1" "$CONFIG" 2>/dev/null; }
MAX_DIFF="$(_cfg '.automation.housekeeping.max_diff_lines')"; case "$MAX_DIFF" in ""|null) MAX_DIFF=400 ;; esac
MAX_PRS="$(_cfg '.automation.housekeeping.max_prs')";          case "$MAX_PRS"  in ""|null) MAX_PRS=3 ;; esac

# ---- date + branch guard -----------------------------------------------------
BRANCH="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
case "$BRANCH" in
  sweep/*) : ;;
  *) _sp_log "REFUSING: worktree branch '$BRANCH' is not sweep/* — aborting (never touch main)"
     notify "Sweep aborted" "post-phase saw non-sweep branch '$BRANCH'" critical
     exit 20 ;;
esac
DATE="${SWEEP_DATE:-${BRANCH#sweep/}}"
REPORT="$HK_DIR/report-$DATE.md"

# commit→theme mapping via the `Sweep-Theme:` git trailer (robust; not body regex)
_theme_commits() { # <theme> → shas (newest first) whose Sweep-Theme trailer == theme
  local t="$1" s
  for s in $(git -C "$WT" rev-list "$MAIN_REF..HEAD" 2>/dev/null); do
    if git -C "$WT" show -s --format='%(trailers:key=Sweep-Theme,valueonly,separator=%x0A)' "$s" 2>/dev/null \
         | sed '/^$/d' | grep -Fxq "$t"; then printf '%s\n' "$s"; fi
  done
}
# themes actually on the branch (deduped).
mapfile -t BRANCH_THEMES < <(git -C "$WT" log "$MAIN_REF..HEAD" \
  --format='%(trailers:key=Sweep-Theme,valueonly,separator=%x0A)' 2>/dev/null | sed '/^$/d' | sort -u)
HAS_COMMITS=$(git -C "$WT" rev-list --count "$MAIN_REF..HEAD" 2>/dev/null || echo 0)

DROPPED=()   # themes dropped by the diff-cap
declare -A THEME_WHY THEME_RISK

# ---- read model hand-off (what/why + residual risk; may be absent) -----------
THEMES_JSON="$HANDOFF/themes.json"
_load_handoff() {
  [ -f "$THEMES_JSON" ] && jq -e 'type=="array"' "$THEMES_JSON" >/dev/null 2>&1 || return 0
  local n i th
  n="$(jq 'length' "$THEMES_JSON" 2>/dev/null || echo 0)"
  for ((i=0;i<n;i++)); do
    th="$(jq -r ".[$i].theme // empty" "$THEMES_JSON")"
    [ -n "$th" ] || continue
    THEME_WHY["$th"]="$(jq -r ".[$i].what_why // empty" "$THEMES_JSON")"
    THEME_RISK["$th"]="$(jq -r "(.[$i].residual_risks // []) | join(\"; \")" "$THEMES_JSON")"
  done
}
_load_handoff

# ---- deterministic report writer (§5.6) --------------------------------------
# _write_report <status-emoji-line> <accept-line> <pr_url> [pr_number]
_write_report() {
  local statusline="$1" acceptline="$2" pr_url="${3:-}" pr_no="${4:-}"
  local diffstat area_rollup tests_block steel_block dropped_block themes_block
  diffstat="$(git -C "$WT" diff --shortstat "$MAIN_REF...HEAD" 2>/dev/null | sed 's/^ *//')"
  [ -n "$diffstat" ] || diffstat="no diff"
  # per-area rollup by top-level dir
  area_rollup="$(git -C "$WT" diff --numstat "$MAIN_REF...HEAD" 2>/dev/null \
    | awk -F'\t' '{n=$3; sub(/\/.*/,"",n); a[n]+=$1; d[n]+=$2}
                  END{for(k in a) printf "- %s: +%d/-%d\n", k, a[k], d[k]}' | sort)"
  [ -n "$area_rollup" ] || area_rollup="- (none)"

  # per-theme what/why lines (model prose or the branch name as honest fallback)
  themes_block=""
  local th why
  for th in "${BRANCH_THEMES[@]}"; do
    [ -n "$th" ] || continue
    why="${THEME_WHY[$th]:-}"
    [ -n "$why" ] || why="(no hand-off note — see $BRANCH)"
    themes_block="${themes_block}- ${th}: ${why}${pr_no:+ (PR #$pr_no)}"$'\n'
  done
  [ -n "$themes_block" ] || themes_block="- (nothing shipped)"$'\n'

  tests_block="$(cat "$HK_DIR/tests-summary.md" 2>/dev/null || echo '| suite | ran | pass | fail | skipped |
|---|---|---|---|---|
| autodetect | see journal | — | — | — |')"
  steel_block="$(cat "$HANDOFF/steelman-verdict.txt" 2>/dev/null || echo 'not recorded by hand-off')"

  dropped_block=""
  if [ "${#DROPPED[@]}" -gt 0 ]; then
    dropped_block="## Not done / abandoned"$'\n'
    for th in "${DROPPED[@]}"; do dropped_block="${dropped_block}- ${th}: dropped by diff-cap (> ${MAX_DIFF} lines) — journal: $HK_DIR"$'\n'; done
  fi
  # residual risks aggregated
  local risks="" r
  for th in "${BRANCH_THEMES[@]}"; do r="${THEME_RISK[$th]:-}"; [ -n "$r" ] && risks="${risks}- ${th}: ${r}"$'\n'; done

  {
    printf '# Nightly sweep — %s   %s\n\n' "$DATE" "$statusline"
    printf '%s\n\n' "$acceptline"
    printf '## What changed & why (per theme, 1 line each)\n%s\n' "$themes_block"
    printf '## Size & scope\n%s\n%s\n\n' "$diffstat" "$area_rollup"
    printf '## Tests\n%s\n\n' "$tests_block"
    printf '## Steelman verdict\n%s\n' "$steel_block"
    [ -n "$risks" ] && printf '\n**Residual risks (do not miss):**\n%s' "$risks"
    printf '\n'
    [ -n "$dropped_block" ] && printf '%s\n' "$dropped_block"
    [ -n "$pr_url" ] && printf '\nPR: %s\n' "$pr_url"
    :   # ensure the group always exits 0 so the mv below is not skipped
  } > "$REPORT.tmp" 2>/dev/null
  if [ -s "$REPORT.tmp" ]; then mv "$REPORT.tmp" "$REPORT"; else rm -f "$REPORT.tmp"; _sp_log "warn: report write empty"; fi
}

# _artifacts + _deliver: journal artifacts, notify, owner DM, marker
_emit_artifacts() { # <pr_url|"">   — consumed into the run journal by run-job.sh
  local pr="$1"
  jq -n --arg pr "$pr" --arg rpt "$REPORT" \
    '[ ($pr | select(. != "")), $rpt ]' > "$HK_DIR/artifacts.json.tmp" 2>/dev/null \
    && mv "$HK_DIR/artifacts.json.tmp" "$HK_DIR/artifacts.json" 2>/dev/null || true
}
_deliver_notify() { # <statusline> <pr_url>
  local sl="$1" pr="$2"
  notify "Nightly sweep — $DATE" "$sl${pr:+ · $pr}" normal
  # owner DM (best-effort; helper CLI, never the interactive skill)
  local dm="$SP_HOOKS_PARENT/../skills/dm-owner/dm-owner.sh"
  [ -x "$dm" ] && bash "$dm" "Nightly sweep $DATE: $sl ${pr:+accept = merge $pr}" >/dev/null 2>&1 || true
}
_advance_marker() {
  local sha; sha="$(git -C "$REPO" rev-parse "$MAIN_REF" 2>/dev/null)"
  [ -n "$sha" ] && [ -x "$WT_SH" ] && AUTOMATION_STATE_DIR="$STATE_DIR" bash "$WT_SH" marker-write "$REPO" "$sha" >/dev/null 2>&1 || true
}
_cleanup_wt() { [ -x "$WT_SH" ] && AUTOMATION_STATE_DIR="$STATE_DIR" bash "$WT_SH" destroy "$WT" >/dev/null 2>&1 || true; }

# ===== 0. nothing shipped =====================================================
if [ "$HAS_COMMITS" -eq 0 ] || [ "${#BRANCH_THEMES[@]}" -eq 0 ]; then
  _sp_log "no commits / no themes on $BRANCH — nothing shipped"
  _write_report "❌ nothing shipped" "**No qualifying changes tonight** — no themes met the no-churn/named-defect bar, or all were abandoned." "" ""
  _emit_artifacts ""
  _deliver_notify "❌ nothing shipped" ""
  _advance_marker
  _cleanup_wt
  exit 10
fi

# ===== 3. FINAL green check ===================================================
TEST_LOG="$HK_DIR/last-test.log"
_run_tests() {
  : > "$TEST_LOG"
  if [ -n "${SWEEP_TEST_CMD:-}" ]; then
    ( cd "$WT" && eval "$SWEEP_TEST_CMD" ) >>"$TEST_LOG" 2>&1; return $?
  fi
  # autodetect (mirrors pre-commit-check.sh / check-diagnostics.sh)
  if   [ -f "$WT/Cargo.toml" ];   then ( cd "$WT" && cargo test --workspace ) >>"$TEST_LOG" 2>&1
  elif [ -f "$WT/package.json" ]; then
        if jq -e '.scripts.test' "$WT/package.json" >/dev/null 2>&1; then ( cd "$WT" && npm test --silent ) >>"$TEST_LOG" 2>&1
        else _sp_log "no npm test script — treating as green"; return 0; fi
  elif [ -f "$WT/go.mod" ];       then ( cd "$WT" && go test ./... ) >>"$TEST_LOG" 2>&1
  else _sp_log "no recognized build system — treating as green"; return 0; fi
}
if ! _run_tests; then
  _sp_log "FINAL green check RED — aborting, no PR (§5.4.5)"
  # test summary for the report
  printf '| suite | result |\n|---|---|\n| autodetect | ❌ FAILED (see %s) |\n' "$TEST_LOG" > "$HK_DIR/tests-summary.md"
  _write_report "❌ nothing shipped (tests red)" "**Sweep aborted: the final build/test check failed.** Nothing was pushed. See $TEST_LOG." "" ""
  _emit_artifacts ""
  notify "Nightly sweep — $DATE" "❌ aborted: final tests RED — nothing pushed" critical
  # do NOT advance the marker on an abort — the next night re-scans this window.
  _cleanup_wt
  exit 20
fi
printf '| suite | result | detail |\n|---|---|---|\n| autodetect | ✅ green | see %s |\n' "$TEST_LOG" > "$HK_DIR/tests-summary.md"

# ===== 4. SECRET-SCAN the diff (NON-NEGOTIABLE) ===============================
SECRET_RE='-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|nsec1[a-z0-9]{20,}|[Bb]earer[[:space:]]+[A-Za-z0-9._~+/-]{20,}|-----BEGIN OPENSSH PRIVATE KEY-----'
# scan added lines only (drop the +++ header)
ADDED="$(git -C "$WT" diff "$MAIN_REF...HEAD" 2>/dev/null | grep -E '^\+' | grep -Ev '^\+\+\+ ')"
# scan the added-path list for secret files (.env / .secrets / agent identity)
ADDED_PATHS="$(git -C "$WT" diff --name-only --diff-filter=A "$MAIN_REF...HEAD" 2>/dev/null)"
SECRET_HIT=""
# NB: -e is REQUIRED — SECRET_RE begins with "-----BEGIN…" which grep would
# otherwise parse as options.
if printf '%s' "$ADDED" | grep -Eq -e "$SECRET_RE"; then SECRET_HIT="key/token material in an added line"; fi
if printf '%s\n' "$ADDED_PATHS" | grep -Eq -e '(^|/)\.env($|\.)|(^|/)\.secrets(/|$)|\.claude/agent/'; then
  SECRET_HIT="${SECRET_HIT:+$SECRET_HIT; }secret-bearing file added (.env/.secrets/agent)"
fi
if [ -n "$SECRET_HIT" ]; then
  _sp_log "SECRET-SCAN HIT: $SECRET_HIT — ABORTING push (§6 row 9)"
  _write_report "❌ nothing shipped (secret detected)" "**Sweep aborted: a secret was detected in the diff and NOTHING was pushed.** ($SECRET_HIT)" "" ""
  _emit_artifacts ""
  notify "Nightly sweep — $DATE" "❌ CRITICAL: secret detected in sweep diff — push aborted ($SECRET_HIT)" critical
  # do NOT advance the marker on an abort — the next night re-scans this window.
  _cleanup_wt
  exit 21
fi

# ===== 5. diff-cap: drop the LARGEST theme until under cap (never truncate) ===
_diff_total() { git -C "$WT" diff --numstat "$MAIN_REF...HEAD" 2>/dev/null | awk -F'\t' '{a+=$1; d+=$2} END{print a+d+0}'; }
_theme_size() { # <theme> → added+deleted across that theme's commits
  local total=0 s
  for s in $(_theme_commits "$1"); do
    total=$(( total + $(git -C "$WT" show --numstat --format= "$s" 2>/dev/null | awk -F'\t' '{a+=$1;d+=$2} END{print a+d+0}') ))
  done
  echo "$total"
}
_drop_theme() { # revert every commit carrying <theme>'s trailer, newest first
  local s
  for s in $(_theme_commits "$1"); do
    git -C "$WT" revert --no-edit "$s" >/dev/null 2>&1 || { _sp_log "revert $s failed"; return 1; }
  done
  return 0
}
TOTAL="$(_diff_total)"
while [ "$TOTAL" -gt "$MAX_DIFF" ] && [ "${#BRANCH_THEMES[@]}" -gt 1 ]; do
  # find largest remaining theme
  big=""; bigsz=-1
  for th in "${BRANCH_THEMES[@]}"; do
    sz="$(_theme_size "$th")"
    if [ "$sz" -gt "$bigsz" ]; then bigsz="$sz"; big="$th"; fi
  done
  [ -n "$big" ] || break
  _sp_log "diff-cap: total=$TOTAL > $MAX_DIFF — dropping largest theme '$big' ($bigsz lines)"
  _drop_theme "$big" || break
  DROPPED+=("$big")
  # remove from active set
  new=(); for th in "${BRANCH_THEMES[@]}"; do [ "$th" = "$big" ] || new+=("$th"); done
  BRANCH_THEMES=("${new[@]}")
  TOTAL="$(_diff_total)"
done
[ "$TOTAL" -gt "$MAX_DIFF" ] && _sp_log "note: single remaining theme still > cap ($TOTAL) — kept, not truncated"

# ===== 6. push sweep/* ONLY ===================================================
case "$BRANCH" in sweep/*) : ;; *) _sp_log "refuse push: '$BRANCH'"; exit 20 ;; esac
if [ "${SWEEP_SKIP_PUSH:-0}" != "1" ]; then
  if ! git -C "$WT" push -u origin "$BRANCH" >/dev/null 2>&1; then
    _sp_log "git push failed — leaving worktree for surfacing/retry"
    _write_report "⚠️ partial (push failed)" "**Push of $BRANCH failed** — nothing merged; worktree left for retry." "" ""
    _emit_artifacts ""
    notify "Nightly sweep — $DATE" "⚠️ push failed for $BRANCH" critical
    exit 30
  fi
fi

# ===== 7. gh pr create (≤ max_prs; label sweep:auto) ==========================
PR_BODY="$HK_DIR/pr-body.md"
{
  printf '## Nightly housekeeping sweep — %s\n\n' "$DATE"
  printf '_Autonomous sweep. **Not auto-merged.** Review the morning-review report below, then accept by merging._\n\n'
  printf '### Themes\n'
  for th in "${BRANCH_THEMES[@]}"; do printf -- '- **%s**: %s\n' "$th" "${THEME_WHY[$th]:-see commits}"; done
  printf '\n### Skipped tests (needs credentials — not run in the secret-free sweep)\n'
  if [ -f "$THEMES_JSON" ]; then jq -r '[.[].skipped_tests // []] | add // [] | .[] | "- " + .' "$THEMES_JSON" 2>/dev/null; fi
  printf '\n### Steelman\n%s\n' "$(cat "$HANDOFF/steelman-verdict.txt" 2>/dev/null || echo 'see hand-off')"
} > "$PR_BODY"

PR_URL=""; PR_NO=""
if [ "${SWEEP_SKIP_PUSH:-0}" != "1" ] || [ -n "${SWEEP_GH_BIN:-}" ]; then
  PR_URL="$("$GH" pr create --base main --head "$BRANCH" \
      --title "Nightly sweep $DATE" --body-file "$PR_BODY" --label sweep:auto 2>>"$HK_DIR/gh.log")" || PR_URL=""
  PR_NO="$(printf '%s' "$PR_URL" | grep -oE '[0-9]+$' || true)"
fi
if [ -z "$PR_URL" ] && [ "${SWEEP_SKIP_PUSH:-0}" != "1" ]; then
  _sp_log "gh pr create produced no URL — see $HK_DIR/gh.log"
  _write_report "⚠️ partial (PR create failed)" "**Branch pushed but PR creation failed** — open it manually: $BRANCH" "" ""
  _emit_artifacts ""
  notify "Nightly sweep — $DATE" "⚠️ PR create failed ($BRANCH pushed)" critical
  exit 30
fi

# ===== 8. morning-review report (source of truth) + PR-body prepend ===========
ACCEPT="**Accept = merge ${PR_URL:-$BRANCH}**"
[ -n "$PR_NO" ] && ACCEPT="**Accept = merge PR #$PR_NO** ($PR_URL)"
STATUS="✅ ready to review"
[ "${#DROPPED[@]}" -gt 0 ] && STATUS="⚠️ partial (${#DROPPED[@]} theme(s) dropped by diff-cap)"
_write_report "$STATUS" "$ACCEPT" "$PR_URL" "$PR_NO"

# prepend the report (minus the accept pointer) to the PR body via gh api PATCH
if [ -n "$PR_NO" ]; then
  NEWBODY="$HK_DIR/pr-body-full.md"
  { grep -v '^\*\*Accept = merge' "$REPORT"; printf '\n---\n\n'; cat "$PR_BODY"; } > "$NEWBODY" 2>/dev/null
  repo_nwo="$(git -C "$REPO" config --get remote.origin.url 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s/\.git$//')"
  if [ -n "$repo_nwo" ]; then
    "$GH" api -X PATCH "repos/$repo_nwo/issues/$PR_NO" -F body=@"$NEWBODY" >/dev/null 2>>"$HK_DIR/gh.log" || _sp_log "PR-body prepend (gh api PATCH) failed — non-fatal"
  fi
fi

# ===== 9. F2 registration (Group C ticketer.sh — stubbed if absent) ===========
TICKETER="$SP_HOOKS_PARENT/ticketer.sh"
if [ -x "$TICKETER" ]; then
  for th in "${BRANCH_THEMES[@]}"; do
    printf 'Sweep %s theme %s: %s\nPR: %s\n' "$DATE" "$th" "${THEME_WHY[$th]:-}" "$PR_URL" > "$HK_DIR/tk-body.md"
    bash "$TICKETER" create --title "sweep $DATE: $th" --body-file "$HK_DIR/tk-body.md" \
      --task-id "sweep-$DATE-$th" >/dev/null 2>&1 || _sp_log "ticketer create failed for $th (non-fatal)"
  done
else
  _sp_log "ticketer.sh absent (Group C not landed) — F2 registration skipped; PR still labeled sweep:auto"
fi

# ===== 10. artifacts + deliver + marker + destroy =============================
_emit_artifacts "$PR_URL"
_deliver_notify "$STATUS" "$PR_URL"
_advance_marker
_cleanup_wt
_sp_log "sweep $DATE complete: ${PR_URL:-<no-pr>} · report $REPORT · dropped=${#DROPPED[@]}"
exit 0
