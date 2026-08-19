#!/bin/bash
# secret-scan.sh — shared secret-pattern tripwire for OUTBOUND text.
#
# A small, dependency-free (grep -E only) scanner that flags high-confidence
# credential shapes in text about to leave this machine. First created for the
# gptbridge relay's owner-approved replies (design §4.4) and the scheduled-
# automation D2 lane; both SOURCE this file or call its CLI. Deliberately
# HIGH-CONFIDENCE only — a reply/notification is human-authored, so a false
# positive is a real annoyance (it blocks legitimate text). We match key
# material and provider token shapes, NOT loose "password=" heuristics.
#
# Contract (two entry points, one behaviour):
#   • Sourced:  secret_scan_text "<text>"   → echoes matched LABELS (one/line)
#                                              to stdout; returns 0 clean, 10 hit.
#   • CLI:      secret-scan.sh scan [file]   → reads FILE or stdin; same output;
#                                              exit 0 clean / 10 on a hit
#               secret-scan.sh redact [file] → echoes text with hits masked
#
# Exit 10 == "secret found" mirrors sif-guard.sh's non-zero == quarantine
# convention, so callers can branch on it without parsing stdout. No network,
# no state, safe under `set -euo pipefail` (returns, never exits, when sourced).

# --- pattern table: LABEL<TAB>ERE. Anchored/among-word-boundaries where useful.
# Ordered most-specific first. Kept in lock-step with the mjs redactSecrets list.
_ss_patterns() {
  cat <<'PATTERNS'
private-key	-----BEGIN[A-Z ]*PRIVATE KEY-----
nostr-nsec	nsec1[02-9ac-hj-np-z]{20,}
bip32-xprv	xprv[0-9a-zA-Z]{20,}
aws-access-key	(^|[^A-Z0-9])AKIA[0-9A-Z]{16}([^A-Z0-9]|$)
google-api-key	(^|[^A-Za-z0-9])AIza[0-9A-Za-z_-]{35}([^A-Za-z0-9]|$)
github-token	(^|[^A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{30,}
slack-token	(^|[^A-Za-z0-9])xox[baprs]-[A-Za-z0-9-]{10,}
openai-key	(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}
jwt	(^|[^A-Za-z0-9])eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}
PATTERNS
}

# Return 0 (clean) / 10 (hit). Echoes the LABEL of every pattern that matched.
secret_scan_text() {
  local text="$1" label ere hit=0
  # -F not usable (we need ERE). grep reads the text on stdin per pattern; the
  # text may be large but replies are size-capped upstream, so this is cheap.
  while IFS=$'\t' read -r label ere; do
    [ -n "$label" ] || continue
    if printf '%s' "$text" | grep -Eq "$ere" 2>/dev/null; then
      printf '%s\n' "$label"
      hit=1
    fi
  done < <(_ss_patterns)
  [ "$hit" = "1" ] && return 10
  return 0
}

# Mask every hit (defence-in-depth for callers that prefer redact-and-send over
# block). Applied pattern-by-pattern with sed -E; label used in the placeholder.
secret_redact_text() {
  local text="$1" label ere
  while IFS=$'\t' read -r label ere; do
    [ -n "$label" ] || continue
    text="$(printf '%s' "$text" | sed -E "s/$ere/[REDACTED $label]/g" 2>/dev/null || printf '%s' "$text")"
  done < <(_ss_patterns)
  printf '%s' "$text"
}

# --- CLI (only when executed directly; sourcing just defines the functions) ---
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  _ss_cmd="${1:-scan}"; shift 2>/dev/null || true
  _ss_input=""
  if [ "${1:-}" != "" ] && [ -f "$1" ]; then _ss_input="$(cat "$1")"; else _ss_input="$(cat)"; fi
  case "$_ss_cmd" in
    scan)
      secret_scan_text "$_ss_input"; exit $?;;
    redact)
      secret_redact_text "$_ss_input"; echo; exit 0;;
    *)
      echo "usage: secret-scan.sh {scan|redact} [file]" >&2; exit 2;;
  esac
fi
