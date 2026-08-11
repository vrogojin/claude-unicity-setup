#!/bin/bash
# sif-guard.sh — thin, isolated content-guard (SIF / semantic firewall) step for
# agent-comms (A2A) message bodies. Mirrors how the concierge backend guards its agent
# I/O: POST the content to the SIF guard (POST /api/guard/check, or a configured SIF
# endpoint) and QUARANTINE (block) on a flag — at inbound (before dispatch) and at
# outbound egress (before send).
#
# Pluggable + degrade-safe by design (SIF may be HELD/keyless on dev):
#   • Disabled by default (opt-in) → inert pass-through. Flip on with sif.enabled.
#   • Strictness knob `sif.required` (a.k.a. SIF_REQUIRED): on a guard ERROR (endpoint
#     unreachable/misconfigured) fail-OPEN by default (dev), fail-CLOSED when required
#     (prod). A genuine content FLAG always quarantines regardless of strictness.
#
# Config precedence: ENV overrides > .claude/agent/config.json `.sif.*` > safe defaults.
#   sif.enabled  (SIF_ENABLED)          bool   — master switch (default false = inert)
#   sif.url      (SIF_GUARD_URL)         url    — e.g. https://concierge-dev.dyndns.org/api/guard/check
#   sif.token    (SIF_GUARD_TOKEN)       string — Bearer token if the endpoint needs one
#   sif.required (SIF_REQUIRED)          bool   — fail-closed on guard error (default false = fail-open)
#   sif.host_header (SIF_GUARD_HOST)     string — optional Host: header (vhost routing)
#   sif.timeout_ms (SIF_GUARD_TIMEOUT_MS) int   — request timeout (default 4000)
#
# Usage:  printf '%s' "<body>" | sif-guard.sh check --direction inbound|outbound \
#             [--principal <id>] [--source <s>]
# Exit:   0 = pass (allow)   ·   10 = quarantine (flagged, or fail-closed guard error)
# Stdout: JSON verdict {status, decision, reasons[], detail}
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"

CONFIG_FILE="${CLAUDE_PROJECT_DIR:-}"
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE/.claude/agent/config.json" ]; then
  CONFIG_FILE="$CONFIG_FILE/.claude/agent/config.json"
else
  CONFIG_FILE="$HOOK_DIR/../agent/config.json"
fi
_cfg() { [ -f "$CONFIG_FILE" ] && jq -r "$1 // empty" "$CONFIG_FILE" 2>/dev/null || true; }

SIF_ENABLED="${SIF_ENABLED:-$(_cfg '.sif.enabled')}"
SIF_URL="${SIF_GUARD_URL:-$(_cfg '.sif.url')}"
SIF_TOKEN="${SIF_GUARD_TOKEN:-$(_cfg '.sif.token')}"
SIF_REQUIRED="${SIF_REQUIRED:-$(_cfg '.sif.required')}"
SIF_HOST="${SIF_GUARD_HOST:-$(_cfg '.sif.host_header')}"
SIF_TIMEOUT_MS="${SIF_GUARD_TIMEOUT_MS:-$(_cfg '.sif.timeout_ms')}"
[ -n "$SIF_TIMEOUT_MS" ] || SIF_TIMEOUT_MS=4000

_verdict() { # status decision reasons(pipe-joined) detail
  jq -nc --arg s "$1" --arg d "$2" --arg r "${3:-}" --arg det "${4:-}" \
    '{status:$s, decision:$d, reasons:($r|split("|")|map(select(length>0))), detail:$det}'
}
_pass()       { _verdict "$1" "pass" "${2:-}" "${3:-}"; exit 0; }
_quarantine() { _verdict "$1" "quarantine" "${2:-}" "${3:-}"; exit 10; }

CMD="${1:-check}"; shift 2>/dev/null || true
DIRECTION="inbound"; PRINCIPAL=""; SOURCE="agent-comms"
while [ $# -gt 0 ]; do
  case "$1" in
    --direction) DIRECTION="${2:-}"; shift 2;;
    --principal) PRINCIPAL="${2:-}"; shift 2;;
    --source)    SOURCE="${2:-}"; shift 2;;
    *) shift;;
  esac
done

# `config` subcommand: report the effective knobs (for debugging / docs).
if [ "$CMD" = "config" ]; then
  jq -nc --arg e "$SIF_ENABLED" --arg u "$SIF_URL" --arg r "$SIF_REQUIRED" \
     --arg h "$SIF_HOST" --arg t "$SIF_TIMEOUT_MS" \
     '{enabled:($e=="true" or $e=="1" or $e=="yes"), url:$u,
       required:($r=="true" or $r=="1" or $r=="yes"), host_header:$h, timeout_ms:($t|tonumber? // 4000)}'
  exit 0
fi

BODY="$(cat)"

# Disabled → inert pass-through (default; dev-safe).
case "$SIF_ENABLED" in
  true|1|yes) ;;
  *) _pass "disabled" "" "SIF guard disabled (set sif.enabled=true / SIF_ENABLED=1 to activate)";;
esac

# Guard-error strictness resolver.
_failmode() {
  case "$SIF_REQUIRED" in
    true|1|yes) _quarantine "error-failclosed" "guard-unreachable" "$1";;
    *) echo "[sif-guard] WARN: content-guard unavailable — failing OPEN (set sif.required=true for fail-closed): $1" >&2
       _pass "error-failopen" "guard-unreachable" "$1";;
  esac
}

[ -n "$SIF_URL" ] || _failmode "no sif.url configured"
command -v curl >/dev/null 2>&1 || _failmode "curl not available"

REQ="$(jq -nc --arg c "$BODY" --arg src "$SOURCE" --arg dir "$DIRECTION" --arg p "$PRINCIPAL" \
  '{content:$c, text:$c, source:$src, direction:$dir, principal:$p}')"
TIMEOUT_S=$(( (SIF_TIMEOUT_MS + 999) / 1000 )); [ "$TIMEOUT_S" -ge 1 ] || TIMEOUT_S=1

HDR=(-H "Content-Type: application/json")
[ -n "$SIF_TOKEN" ] && HDR+=(-H "Authorization: Bearer $SIF_TOKEN")
[ -n "$SIF_HOST" ]  && HDR+=(-H "Host: $SIF_HOST")

RESP="$(curl -sS --max-time "$TIMEOUT_S" -X POST "${HDR[@]}" -d "$REQ" "$SIF_URL" 2>/dev/null)" \
  || _failmode "curl failed contacting $SIF_URL"
[ -n "$RESP" ] || _failmode "empty guard response"
echo "$RESP" | jq -e . >/dev/null 2>&1 || _failmode "non-JSON guard response"

# Liberal flag detection across plausible SIF response shapes (fail-closed reading:
# the guard blocks on a flag).
FLAGGED="$(echo "$RESP" | jq -r '
  ((.flagged==true) or (.blocked==true) or (.allowed==false) or (.safe==false)
   or ((.action   // "")|ascii_downcase=="block")
   or ((.decision // "")|ascii_downcase|test("block|deny|quarantine"))
   or ((.verdict  // "")|ascii_downcase|test("block|unsafe|malicious|deny")))
' 2>/dev/null || echo "false")"
REASONS="$(echo "$RESP" | jq -r '[(.reasons // .rules // .categories // .labels // [])[]? | tostring] | join("|")' 2>/dev/null || echo "")"

if [ "$FLAGGED" = "true" ]; then
  _quarantine "flagged" "$REASONS" "content-guard flagged the ${DIRECTION} message"
fi
_pass "clean" "$REASONS" "content-guard passed"
