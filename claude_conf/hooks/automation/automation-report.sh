#!/bin/bash
# automation-report.sh — SessionStart digest of finished automation runs (§2.6).
#
# Results are surfaced as ADVISORY SessionStart context, never a Stop gate
# (blocking the human's first morning session on automation residue would wedge
# every morning). Any run journal with reported:false → a one-paragraph digest
# (job · outcome · artifacts) injected as additionalContext, then marked
# reported:true. For the housekeeping job specifically the full morning-review
# report file (Group D's report-<date>.md) IS the digest and is injected whole.
#
# Never blocks; always exits 0.
set -uo pipefail

AR_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
AR_HOOKS_PARENT="$(cd "$AR_HOOK_DIR/.." 2>/dev/null && pwd || echo .)"
. "$AR_HOOKS_PARENT/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"

# drain the SessionStart stdin payload (unused) so we don't leave a broken pipe
[ -t 0 ] || cat >/dev/null 2>&1 || true

command -v jq >/dev/null 2>&1 || exit 0
AUTO="$STATE_DIR/automation"
[ -d "$AUTO" ] || exit 0

CTX=""
for jdir in "$AUTO"/*/; do
  [ -d "$jdir" ] || continue
  job="$(basename "$jdir")"
  # oldest unreported first, so the digest reads chronologically
  while IFS= read -r jf; do
    [ -f "$jf" ] || continue
    [ "$(jq -r '.reported // false' "$jf" 2>/dev/null)" = "false" ] || continue
    status="$(jq -r '.status // "unknown"' "$jf" 2>/dev/null)"
    summ="$(jq -r '.summary // ""' "$jf" 2>/dev/null)"
    arts="$(jq -r '(.artifacts // []) | map(tostring) | join(", ")' "$jf" 2>/dev/null)"
    line="• [$job] $status — $summ"
    [ -n "$arts" ] && line="$line"$'\n'"    artifacts: $arts"
    if [ "$job" = "housekeeping" ]; then
      rpt="$(ls -1t "$jdir"report-*.md 2>/dev/null | head -1)"
      if [ -n "$rpt" ] && [ -f "$rpt" ]; then
        line="$line"$'\n'"$(cat "$rpt")"
      fi
    fi
    CTX="${CTX}${line}"$'\n'
    # mark reported (atomic)
    if jq '.reported = true' "$jf" > "$jf.tmp" 2>/dev/null; then mv "$jf.tmp" "$jf"; else rm -f "$jf.tmp"; fi
  done < <(ls -1tr "$jdir"run-*.json 2>/dev/null)
done

[ -n "$CTX" ] || exit 0
jq -n --arg ctx "Scheduled automation — results since your last session:"$'\n'"$CTX" \
  '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$ctx}}' 2>/dev/null || true
exit 0
