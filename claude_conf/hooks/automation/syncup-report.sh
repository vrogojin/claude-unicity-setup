#!/bin/bash
# syncup-report.sh — the DETERMINISTIC builder of our own `sync.report` payload
# (F1 syncup, design §3.4 / §3.2 "Own-status report" row / work-item B2).
#
# It assembles the report the syncup job emits to authorized peers, from EXISTING
# read-only stores ONLY:
#   • completed   ← git merge commits + (best-effort) `gh pr list --state merged`
#   • in_progress ← open feature branches + the ROADMAP "🚧 In progress" section
#   • commitments ← remote-coord.sh's change-commitment ledger (cmid → status)
#   • asks/notes  ← left EMPTY: they are free-text prose the model may add later; the
#                   builder never invents them (and the model may NOT add refs the
#                   builder didn't produce — §3.4 anti-hallucination rule).
#
# HARD CONSTRAINTS (design §7 / failure mode #9):
#   • READ-ONLY. It never writes a repo, never mutates coordination state.
#   • METADATA ONLY. It NEVER reads .env / .secrets / config secrets / key material —
#     only git history, `gh` metadata, docs/ROADMAP.md, and the coord ledger. This is
#     why a report can be sent to peers without leaking anything. (Residual risk: a secret
#     a human committed INTO git metadata — a branch name or merge subject — is faithfully
#     reported; the builder cannot distinguish it from normal text. Keep secrets out of
#     branch names / commit messages, per the standing rule.)
#   • DETERMINISM is over report CONTENT (completed/in_progress/commitments) for a fixed
#     period — the `period.to` envelope field defaults to "now" and so varies per run.
#
# Output: the ENVELOPE PAYLOAD object (period/repo/completed/in_progress/commitments/
# asks/notes) on stdout — NOT a wire envelope. The caller wraps it:
#     remote-coord.sh envelope sync.report --payload "$(syncup-report.sh …)"
# so `rc_envelope` stamps kind/id/from and nests it under `.payload` (§3.4 wire shape).
#
# Usage:
#   syncup-report.sh [--project DIR] [--from ISO] [--to ISO] [--since-sha SHA]
#                    [--repo SLUG] [--max N]
#   Period selection (most precise first): --since-sha gives the exact <sha>..HEAD
#   range that matches the last-syncup marker; else --from as a `git log --since`;
#   else the last N merges. --to defaults to "now".
# Env: SYNCUP_REPORT_NO_GH=1 forces the `gh` completed-PR lookup off (hermetic tests).
set -uo pipefail

US=$'\x1f'   # unit separator — record field delimiter (won't appear in commit subjects)

PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"
FROM="" TO="" SINCE_SHA="" REPO="" MAX=50
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --project)   PROJ="${2:-}"; shift 2;;
    --from)      FROM="${2:-}"; shift 2;;
    --to)        TO="${2:-}"; shift 2;;
    --since-sha) SINCE_SHA="${2:-}"; shift 2;;
    --repo)      REPO="${2:-}"; shift 2;;
    --max)       MAX="${2:-50}"; shift 2;;
    *) shift;;
  esac
done
[ -n "$PROJ" ] || PROJ="$PWD"
[[ "$MAX" =~ ^[0-9]+$ ]] || MAX=50

_git() { git -C "$PROJ" "$@" 2>/dev/null; }

# --- period ------------------------------------------------------------------
[ -n "$TO" ] || TO="$(date -u +%FT%TZ)"
# If a marker sha was given but no --from, derive the human-readable from-instant from
# that commit's date (keeps period.from meaningful even when we range by sha..HEAD).
if [ -z "$FROM" ] && [ -n "$SINCE_SHA" ]; then
  FROM="$(_git show -s --format=%cI "$SINCE_SHA" 2>/dev/null || echo "")"
fi

# git revision range / window flags (sha range is the most precise; matches the marker).
# Guard the sha range with an ANCESTRY check: a marker sha that is known locally but NOT an
# ancestor of HEAD (diverged branch / partial rewrite) would make `<sha>..HEAD` span the
# whole divergence — potentially all of history. Only range from an actual ancestor.
GITRANGE=()
if [ -n "$SINCE_SHA" ] && _git cat-file -e "${SINCE_SHA}^{commit}" 2>/dev/null \
   && _git merge-base --is-ancestor "$SINCE_SHA" HEAD 2>/dev/null; then
  GITRANGE=("${SINCE_SHA}..HEAD")
elif [ -n "$FROM" ]; then
  GITRANGE=(--since="$FROM" --until="$TO")
else
  GITRANGE=(--max-count="$MAX")
fi

# --- repo slug ---------------------------------------------------------------
if [ -z "$REPO" ]; then
  REPO="$(_git remote get-url origin 2>/dev/null | sed -E 's#.*[/:]([^/]+/[^/]+)(\.git)?$#\1#; s#\.git$##' | tr '/' '-')"
  [ -n "$REPO" ] || REPO="$(basename "$PROJ" 2>/dev/null || echo repo)"
fi

# --- completed: merge commits (deterministic) + best-effort merged PRs --------
# %H<US>%s per line; 12-char sha ref, subject as title. Read-only over git history.
COMPLETED_GIT="$(_git log "${GITRANGE[@]}" --merges --pretty=format:"%H${US}%s" 2>/dev/null \
  | jq -R -s --arg us "$US" '
      split("\n") | map(select(length>0) | split($us))
      | map({title: ((.[1:] | join($us))), ref: ((.[0] // "")[0:12])})' 2>/dev/null)"
[ -n "$COMPLETED_GIT" ] || COMPLETED_GIT='[]'

COMPLETED_GH='[]'
if [ "${SYNCUP_REPORT_NO_GH:-0}" != "1" ] && command -v gh >/dev/null 2>&1; then
  # merged:>=<date> needs a date; use the from-date when we have one (else skip — a
  # date-less "all merged" search would blow the period bound). Best-effort: any gh
  # failure (no auth, no network, not a GH repo) leaves the git-only list intact.
  GHDATE="${FROM%%T*}"
  if [ -n "$GHDATE" ]; then
    # HARD timeout: `gh` uses Go's default HTTP client (no request timeout); a black-hole
    # network would otherwise hang — bounded only by the runner's wall cap in the scheduled
    # path, and UNBOUNDED in an interactive run. Cap it; any failure keeps the git-only list.
    COMPLETED_GH="$(cd "$PROJ" && timeout "${SYNCUP_GH_TIMEOUT:-20}" gh pr list --state merged \
        --search "merged:>=$GHDATE" --limit "$MAX" --json title,url 2>/dev/null \
        | jq 'map({title: (.title // ""), ref: (.url // "")})' 2>/dev/null)"
    [ -n "$COMPLETED_GH" ] || COMPLETED_GH='[]'
  fi
fi
COMPLETED="$(jq -c -n --argjson g "$COMPLETED_GIT" --argjson h "$COMPLETED_GH" --argjson max "$MAX" \
  '($g + $h) | unique_by(.title) | .[0:$max]' 2>/dev/null)"
[ -n "$COMPLETED" ] || COMPLETED='[]'

# --- in_progress: open feature branches + ROADMAP 🚧 lines --------------------
BRANCHES="$(_git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null \
  | grep -Ev '^(main|master|HEAD)$' \
  | jq -R -s '
      split("\n") | map(select(length>0))
      | map({title: ., branch: ., ref: ""})' 2>/dev/null)"
[ -n "$BRANCHES" ] || BRANCHES='[]'

# ROADMAP "## 🚧 In progress" section: bullet lines until the next "## " header.
ROADMAP_WIP='[]'
RM="$PROJ/docs/ROADMAP.md"
if [ -f "$RM" ]; then
  ROADMAP_WIP="$(awk '
      { sub(/\r$/, "") }                                  # tolerate CRLF line endings
      /^## / { insec = ($0 ~ /🚧/) ? 1 : 0; next }
      insec && /^[-*] / { sub(/^[-*][ \t]+/, ""); print }
    ' "$RM" 2>/dev/null \
    | jq -R -s '
        split("\n") | map(select(length>0))
        | map({title: ., branch: "", ref: "roadmap:🚧"})' 2>/dev/null)"
  [ -n "$ROADMAP_WIP" ] || ROADMAP_WIP='[]'
fi
IN_PROGRESS="$(jq -c -n --argjson b "$BRANCHES" --argjson r "$ROADMAP_WIP" --argjson max "$MAX" \
  '($b + $r) | unique_by(.title) | .[0:$max]' 2>/dev/null)"
[ -n "$IN_PROGRESS" ] || IN_PROGRESS='[]'

# --- commitments: the change-commitment ledger (cmid → status) ----------------
RC_SH="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)/remote-coord.sh"
COMMITMENTS='[]'
if [ -f "$RC_SH" ]; then
  COMMITMENTS="$(bash "$RC_SH" commitments 2>/dev/null | jq -c 'map({cmid, status: (.status // "pending")})' 2>/dev/null)"
  [ -n "$COMMITMENTS" ] || COMMITMENTS='[]'
fi

# --- assemble the payload (§3.4). asks/notes intentionally empty for the model. ---
jq -c -n \
  --arg from "$FROM" --arg to "$TO" --arg repo "$REPO" \
  --argjson completed "$COMPLETED" --argjson in_progress "$IN_PROGRESS" \
  --argjson commitments "$COMMITMENTS" \
  '{ period: {from: $from, to: $to}, repo: $repo,
     completed: $completed, in_progress: $in_progress,
     commitments: $commitments, asks: [], notes: "" }'
