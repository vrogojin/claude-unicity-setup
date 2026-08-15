#!/bin/bash
# a2a.sh — one turnkey entry point for EVERY agent-to-agent (A2A) operation.
#
# The pain this removes: before this, each A2A op required RESEARCH — finding the right
# sphere-helper/ticket.sh, exporting TEAM_SPHERE_HELPER, locating identity/config/coord-root,
# hand-building the `{from:<hex>, body:<envelope>}` ingest wrapper, assembling consult/advise
# envelopes, etc. This script BAKES ALL OF THAT IN so the /a2a skill can give one exact,
# self-contained command per operation. It is a thin, deterministic wrapper over the existing
# engines (ticket.sh, remote-coord.sh, agent-registry.sh, onboard-teammate.sh, sphere-helper);
# it invents no new transport or trust logic — the same default-deny + SIF guards still apply.
#
# Resolution baked in (identical to rc_emit / agent-comms-check / _tc_sphere_helper):
#   helper   = $TEAM_SPHERE_HELPER → config.transport.helper_path → relative candidates
#   identity = $TEAM_IDENTITY_FILE → <agent>/identity.json
#   config   = <identity dir>/config.json
#   daemon   = <helper dir>/sphere-daemon.mjs
#   coord    = coord_root() (durable A2A store)
#
# Usage:  bash .claude/hooks/a2a.sh <op> [args]     (run `a2a.sh help` for the op list)
set -uo pipefail

A2A_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
# Sourcing these defines functions only (each has a source-guard / runs its CLI only when
# executed directly): coord_root, rc_self_npub/name, rc_envelope, rc_emit, rc_resolve_target,
# rc_consult_open/get, rc_advise, rc_is_verb, _tc_sphere_helper, team_identity_path, AGENT_*.
. "$A2A_HOOK_DIR/agent-registry.sh" 2>/dev/null || true
. "$A2A_HOOK_DIR/team-coord.sh"     2>/dev/null || true
. "$A2A_HOOK_DIR/remote-coord.sh"   2>/dev/null || true

A2A_REGISTRY="$A2A_HOOK_DIR/agent-registry.sh"
A2A_TICKET="$A2A_HOOK_DIR/ticket.sh"
A2A_ONBOARD="$A2A_HOOK_DIR/onboard-teammate.sh"
A2A_SIF="$A2A_HOOK_DIR/sif-guard.sh"
A2A_DAEMON_SESSION="$A2A_HOOK_DIR/daemon-session.sh"

_a2a_err()  { echo "ERROR(a2a): $*" >&2; }
_a2a_warn() { echo "WARN(a2a): $*" >&2; }

# ── resolution (single source of truth for the whole script) ─────────────────────────
_a2a_helper()   { local h=""; type _tc_sphere_helper >/dev/null 2>&1 && h="$(_tc_sphere_helper)"; printf '%s' "$h"; }
_a2a_identity() {
  local i=""; type team_identity_path >/dev/null 2>&1 && i="$(team_identity_path)"
  [ -n "$i" ] || i="$A2A_HOOK_DIR/../agent/identity.json"; printf '%s' "$i"
}
_a2a_config()   { printf '%s/config.json' "$(dirname "$(_a2a_identity)")"; }
_a2a_daemon()   { local h; h="$(_a2a_helper)"; [ -n "$h" ] && printf '%s/sphere-daemon.mjs' "$(dirname "$h")"; }
_a2a_relay()    {
  local c; c="$(_a2a_config)"
  local r=""; [ -f "$c" ] && r="$(jq -r '.group.relays[0] // .relays[0] // ""' "$c" 2>/dev/null)"
  printf '%s' "${r:-${RELAY_URL:-wss://nostr-relay.testnet.unicity.network}}"
}
_a2a_project()  { printf '%s' "${CLAUDE_PROJECT_DIR:-$(cd "$A2A_HOOK_DIR/../.." 2>/dev/null && pwd || echo .)}"; }
# Run the transport helper with NODE_PATH pointed at the clone's node_modules (helper dir →
# ../node_modules), so @unicitylabs/sphere-sdk loads even when invoked from outside the clone.
_a2a_run_helper() {
  local helper; helper="$(_a2a_helper)"
  [ -n "$helper" ] || { _a2a_err "sphere-helper.mjs not resolvable (set \$TEAM_SPHERE_HELPER or re-run setup.sh)"; return 3; }
  local np; np="$(cd "$(dirname "$helper")/.." 2>/dev/null && pwd)/node_modules:${NODE_PATH:-}"
  NODE_PATH="$np" node "$helper" "$@"
}
_a2a_state_dir() {
  local sd=""; . "$A2A_HOOK_DIR/state-dir.sh" 2>/dev/null && sd="${STATE_DIR:-}"
  printf '%s' "${sd:-/tmp/claude}"
}

# ══════════════════════════════════════════════════════════════════════════════════════
# whoami — everything a caller (or a stuck skill) needs to see at a glance.
# ══════════════════════════════════════════════════════════════════════════════════════
a2a_whoami() {
  local id cfg helper daemon npub name relay coord dstat
  id="$(_a2a_identity)"; cfg="$(_a2a_config)"; helper="$(_a2a_helper)"; daemon="$(_a2a_daemon)"
  npub="$(rc_self_npub 2>/dev/null)"; name="$(rc_self_name 2>/dev/null)"; relay="$(_a2a_relay)"
  coord="$(coord_root 2>/dev/null)"
  dstat=""
  if [ -n "$daemon" ]; then dstat="$(node "$daemon" status --project "$(_a2a_project)" 2>/dev/null | head -1)"; fi
  [ -n "$dstat" ] || dstat="unknown (daemon script unresolved)"
  jq -nc \
    --arg npub "$npub" --arg name "$name" --arg id "$id" --arg cfg "$cfg" \
    --arg helper "$helper" --arg daemon "$daemon" --arg relay "$relay" --arg coord "$coord" \
    --arg idok "$( [ -f "$id" ] && echo yes || echo NO )" \
    --arg helperok "$( [ -n "$helper" ] && [ -f "$helper" ] && echo yes || echo NO )" \
    --arg dstat "$dstat" \
    '{self:{name:$name, npub:$npub}, identity:{path:$id, present:$idok}, config:$cfg,
      helper:{path:$helper, present:$helperok}, daemonScript:$daemon, daemonStatus:$dstat,
      relay:$relay, coordRoot:$coord}'
}

# ══════════════════════════════════════════════════════════════════════════════════════
# check — drain the inbound queue NOW (no cooldown): poll → merge (dedup by id) → classify.
# Reuses the AUTHORITATIVE router (classify-inbound.sh), so ticket verbs get the correct
# {from,body} ingest and coordination verbs get capability-gated enqueue — no hand-wrapping.
# This is the manual stand-in for a running daemon (the inbound-deaf case).
# ══════════════════════════════════════════════════════════════════════════════════════
a2a_check() {
  local since="" all=0
  while [ $# -gt 0 ]; do case "$1" in
    --since) since="$2"; shift 2;; --all) all=1; shift;; *) shift;; esac; done
  local id cfg; id="$(_a2a_identity)"; cfg="$(_a2a_config)"
  [ -f "$id" ] && [ -f "$cfg" ] || { _a2a_err "identity/config missing ($id / $cfg) — run setup.sh"; return 1; }
  local now; now="$(date +%s)"
  [ -n "$since" ] || { [ "$all" = "1" ] && since=0 || since=$(( now - 86400 )); }

  local poll rc
  poll="$(_a2a_run_helper check-messages --identity "$id" --config "$cfg" --since "$since" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$poll" | jq -e 'has("messages")' >/dev/null 2>&1; then
    _a2a_err "poll FAILED (helper rc=$rc). Transport unusable — run: bash $A2A_HOOK_DIR/a2a.sh verify"; return 1
  fi
  local n; n="$(printf '%s' "$poll" | jq '.messages | length')"
  local sd sf; sd="$(_a2a_state_dir)"; sf="$sd/agent-messages.json"; mkdir -p "$sd"
  [ -f "$sf" ] || printf '{"unread":false,"unread_count":0,"priority_count":0,"messages":[]}' > "$sf"
  # Merge only messages whose id is not already in the state file (dedup — an improvement over
  # the cooldown-poll path, which can double-append). Then hand off to the classifier.
  local merged
  merged="$(jq --argjson poll "$poll" '
    (.messages | map(.id) ) as $have
    | ($poll.messages | map(select((.id // "") as $i | ($i=="" or (($have|index($i))==null))))) as $fresh
    | .messages += $fresh
    | .unread = ((.unread) or (($fresh|length)>0))
    | .unread_count = (.unread_count + ($fresh|length))
    | .priority_count = (.priority_count + ($fresh|map(select(.priority==true))|length))
    | ._a2a_fresh = ($fresh|length)
  ' "$sf")"
  local fresh; fresh="$(printf '%s' "$merged" | jq '._a2a_fresh')"
  printf '%s' "$merged" | jq 'del(._a2a_fresh)' > "$sf.tmp.$$" && mv "$sf.tmp.$$" "$sf"
  if [ -f "$A2A_HOOK_DIR/classify-inbound.sh" ]; then
    CLAUDE_PROJECT_DIR="$(_a2a_project)" bash "$A2A_HOOK_DIR/classify-inbound.sh" >/dev/null 2>&1 || true
  fi
  echo "checked: $n polled, $fresh new since $since → routed through classify-inbound (ticket verbs ingested, coordination verbs queued)."
  echo "  read them:  /check-messages    ·    coordination queue: /coordinator-advise (or /consult-coordinator)"
}

# ══════════════════════════════════════════════════════════════════════════════════════
# verify — end-to-end round-trip self-test with LOUD diagnosis (the missing check dmytro +
# claude-test1 flagged). Step 1 = network-free crypto (sdk/node_modules). Step 2 = a LIVE
# relay DM round-trip to self (identity + helper + relay + gift-wrap encrypt/decrypt). With
# --peer, sends to a peer instead (their echo requires them to run `a2a check`/daemon).
# ══════════════════════════════════════════════════════════════════════════════════════
a2a_verify() {
  local peer="" timeout=45
  while [ $# -gt 0 ]; do case "$1" in
    --peer) peer="$2"; shift 2;; --timeout) timeout="$2"; shift 2;; *) shift;; esac; done
  local id cfg helper daemon npub relay
  id="$(_a2a_identity)"; cfg="$(_a2a_config)"; helper="$(_a2a_helper)"; relay="$(_a2a_relay)"
  npub="$(rc_self_npub 2>/dev/null)"

  echo "── A2A round-trip self-test ──────────────────────────────────"
  # Preflight the resolution the WHOLE stack depends on, each failure named.
  local hard=0
  if [ -f "$id" ] && [ -n "$npub" ]; then echo "  [ok] identity        $id ($npub)"
  else echo "  [FAIL] identity      $id — missing or has no npub (run setup.sh)"; hard=1; fi
  if [ -n "$helper" ] && [ -f "$helper" ]; then echo "  [ok] helper          $helper"
  else echo "  [FAIL] helper        unresolved — set \$TEAM_SPHERE_HELPER or record transport.helper_path (setup.sh)"; hard=1; fi
  if [ -f "$cfg" ]; then echo "  [ok] config          $cfg"
  else echo "  [FAIL] config        $cfg — missing (run setup.sh)"; hard=1; fi
  echo "  relay: $relay"
  [ "$hard" = "0" ] || { echo "── RESULT: FAIL (configuration) ─────────────────────────────"; return 1; }

  # Step 1 — crypto / sdk (network-free): ticket sign→verify via the stub relay.
  if bash "$A2A_TICKET" self-test >/dev/null 2>&1; then
    echo "  [ok] crypto/sdk      sign→verify round-trips (node_modules + schnorr + AES-GCM)"
  else
    echo "  [FAIL] crypto/sdk    ticket self-test failed → @unicitylabs/sphere-sdk not resolvable."
    echo "         fix:  (cd \"$(cd "$(dirname "$helper")/.." 2>/dev/null && pwd)\" && npm install)"
    echo "── RESULT: FAIL (sdk/node_modules) ──────────────────────────"; return 1
  fi

  # Step 2 — live DM round-trip.
  local target="${peer:-$npub}" thex nonce
  nonce="a2a-verify-$(date +%s)-$RANDOM"
  echo "  sending probe DM → ${peer:+peer }${peer:-self} ($target)…"
  if ! printf '%s' "$nonce" | _a2a_run_helper send-dm "$target" --identity "$id" --relay "$relay" >/dev/null 2>&1; then
    echo "  [FAIL] send          could not publish DM to $target"
    echo "         → relay unreachable ($relay) or identity/helper broken. Check network + RELAY_URL."
    echo "── RESULT: FAIL (send) ──────────────────────────────────────"; return 1
  fi
  echo "  [ok] send            probe published; waiting up to ${timeout}s for it to come back…"

  if [ -n "$peer" ]; then
    echo "  [note] --peer set: the return leg needs $peer to echo (their daemon/'a2a check' up)."
  fi
  local deadline; deadline=$(( $(date +%s) + timeout ))
  local sinceTs; sinceTs=$(( $(date +%s) - 120 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local msgs hit
    msgs="$(_a2a_run_helper check-messages --identity "$id" --config "$cfg" --since "$sinceTs" 2>/dev/null || echo '{"messages":[]}')"
    hit="$(printf '%s' "$msgs" | jq -r --arg n "$nonce" '[.messages[]? | select((.body // "")|contains($n))] | length')"
    if [ "${hit:-0}" -gt 0 ] 2>/dev/null; then
      echo "  [ok] receive         probe returned — inbound path verified"
      echo "── RESULT: PASS (send + receive round-trip OK via $relay) ───"; return 0
    fi
    sleep 5
  done
  echo "  [FAIL] receive       probe did NOT return within ${timeout}s"
  if [ -n "$peer" ]; then
    echo "         → outbound worked; the peer never echoed. Confirm $peer is live and ran 'a2a check'."
  else
    echo "         → outbound worked but self-delivery failed: relay may not retain/serve our gift-wrap,"
    echo "           the relay dropped it, or the poll window missed it. Retry, or verify with --peer <npub>."
  fi
  echo "── RESULT: FAIL (receive) ───────────────────────────────────"; return 1
}

# ══════════════════════════════════════════════════════════════════════════════════════
# daemon — thin passthrough to the session-lifecycle manager (start/stop/status/restart).
# ══════════════════════════════════════════════════════════════════════════════════════
a2a_daemon() {
  local sub="${1:-status}"; shift || true
  local d proj; d="$(_a2a_daemon)"; proj="$(_a2a_project)"
  case "$sub" in
    status)  [ -n "$d" ] && node "$d" status --project "$proj" || _a2a_err "daemon script unresolved";;
    # start goes through the session manager (registers a session + starts detached, no double-start).
    start)   [ -f "$A2A_DAEMON_SESSION" ] && bash "$A2A_DAEMON_SESSION" start || _a2a_err "daemon-session.sh missing";;
    # stop/restart here are a MANUAL hard control (bypasses refcount) — for the operator.
    stop)    [ -n "$d" ] && node "$d" stop --project "$proj" || _a2a_err "daemon script unresolved";;
    restart) [ -n "$d" ] && { node "$d" stop --project "$proj" >/dev/null 2>&1; sleep 1; bash "$A2A_DAEMON_SESSION" start; } || _a2a_err "daemon script unresolved";;
    *) _a2a_err "usage: a2a daemon {status|start|stop|restart}"; return 1;;
  esac
}

# ══════════════════════════════════════════════════════════════════════════════════════
# tickets — issue / redeem / revoke / list (delegates to ticket.sh; identical semantics).
# ══════════════════════════════════════════════════════════════════════════════════════
a2a_issue()   { bash "$A2A_TICKET" issue "$@"; }
a2a_redeem()  {
  # Accept a bare ut2_/v1 string, or --file <path> (preferred: keeps the secret off argv).
  local file="" ; local -a rest=()
  while [ $# -gt 0 ]; do case "$1" in --file) file="$2"; shift 2;; *) rest+=("$1"); shift;; esac; done
  if [ -n "$file" ]; then bash "$A2A_TICKET" redeem --ticket-file "$file" ${rest[@]+"${rest[@]}"}
  else bash "$A2A_TICKET" redeem ${rest[@]+"${rest[@]}"}; fi
}
a2a_revoke()  { bash "$A2A_TICKET" revoke "$@"; }
a2a_tickets() { bash "$A2A_TICKET" list "$@"; }

# ══════════════════════════════════════════════════════════════════════════════════════
# ingest — MANUAL daemon-path handlers (when the daemon was deaf). Builds the correct
# transport wrapper {from:<hex>, body:<envelope>} for you, so you never hand-shape it.
#   a2a ingest-redeem --from <hex> --body '<envelope-json>'      (issuer side)
#   a2a ingest-grant  --from <hex> --body '<envelope-json>'      (redeemer side)
#   a2a ingest-deny   --from <hex> --body '<envelope-json>'
# You usually want `a2a check` instead — it polls + wraps + routes ALL inbound at once.
# ══════════════════════════════════════════════════════════════════════════════════════
_a2a_wrap_ingest() {  # <verb> <from-hex> <body-json-or-string>
  local verb="$1" from="$2" body="$3"
  printf '%s' "$from" | grep -Eq '^[0-9a-f]{64}$' || { _a2a_err "--from must be a 64-hex transport pubkey"; return 1; }
  # body may be an object or a JSON string; pass it through unchanged inside the wrapper.
  local wrap; wrap="$(jq -nc --arg from "$from" --argjson body "$(printf '%s' "$body" | jq -c . 2>/dev/null || jq -nc --arg b "$body" '$b')" '{from:$from, body:$body}')"
  bash "$A2A_TICKET" "$verb" "$wrap"
}
a2a_ingest() {  # ingest-redeem|ingest-grant|ingest-deny  --from H --body J
  local verb="$1"; shift; local from="" body=""
  while [ $# -gt 0 ]; do case "$1" in --from) from="$2"; shift 2;; --body) body="$2"; shift 2;; *) shift;; esac; done
  [ -n "$from" ] && [ -n "$body" ] || { _a2a_err "usage: a2a $verb --from <hex> --body '<envelope-json>'"; return 1; }
  _a2a_wrap_ingest "$verb" "$from" "$body"
}

# ══════════════════════════════════════════════════════════════════════════════════════
# dm — send a plain human DM (SIF egress-guarded, optional first-contact intro). Body via
# STDIN to the helper (never argv — mirrors rc_emit's secret-safe send).
# ══════════════════════════════════════════════════════════════════════════════════════
a2a_dm() {
  local intro=1 ; local to="" ; local -a words=()
  while [ $# -gt 0 ]; do case "$1" in
    --no-intro) intro=0; shift;;
    *) if [ -z "$to" ]; then to="$1"; else words+=("$1"); fi; shift;; esac; done
  [ -n "$to" ] && [ "${#words[@]}" -gt 0 ] || { _a2a_err "usage: a2a dm <peer-name-or-npub> <message…> [--no-intro]"; return 1; }
  local msg="${words[*]}"
  local npub; npub="$(rc_resolve_target "${to#@}" 2>/dev/null)" || { _a2a_err "could not resolve '$to' to an npub (pass a raw npub for a brand-new peer)"; return 1; }
  # First-contact intro unless suppressed and unless we already know this peer.
  local known; known="$(bash "$A2A_REGISTRY" get "$npub" 2>/dev/null | jq -r '.status // ""' 2>/dev/null || echo "")"
  local body="$msg"
  if [ "$intro" = "1" ] && [ -z "$known" ]; then
    body="[$(rc_self_name 2>/dev/null || echo agent) · a2a] $msg"
  fi
  # Egress content-guard (fail-closed on quarantine).
  if [ -f "$A2A_SIF" ]; then
    local dec; dec="$(printf '%s' "$body" | bash "$A2A_SIF" check --direction outbound --principal "$npub" --source agent-comms 2>/dev/null | jq -r '.decision // "pass"' 2>/dev/null || echo pass)"
    [ "$dec" = "quarantine" ] && { _a2a_err "outbound blocked by content-guard — NOT sent"; return 1; }
  fi
  local id; id="$(_a2a_identity)"
  if printf '%s' "$body" | _a2a_run_helper send-dm "$npub" --identity "$id" --relay "$(_a2a_relay)" >/dev/null 2>&1; then
    echo "sent → ${to} ($(printf '%s' "$npub" | cut -c1-16)…)$( [ "$body" != "$msg" ] && echo ' (first-contact intro included)')"
  else
    _a2a_err "send failed (transport). Try: a2a verify"; return 1
  fi
}

# ══════════════════════════════════════════════════════════════════════════════════════
# consult / advise — the consult fabric, one command each (wraps open+envelope+emit).
# ══════════════════════════════════════════════════════════════════════════════════════
a2a_consult() {  # <coord> --intent T [--areas csv --repos csv --changes J --questions J --urgency U]
  local to="$1"; shift
  [ -n "$to" ] || { _a2a_err "usage: a2a consult <coord-npub-or-name> --intent '…' [--areas … --repos … --changes JSON --questions JSON --urgency high]"; return 1; }
  local cid; cid="$(rc_consult_open --to "$to" "$@")" || { _a2a_err "consult-open failed"; return 1; }
  local env; env="$(rc_envelope consult.request --consult "$cid" --payload "$(rc_consult_get "$cid" | jq -c '{intent, areas, repos, changes, questions, urgency}')")"
  rc_emit "$env" --to "$to" && echo "consult $cid sent → $to"
}
a2a_advise() {  # <cid> --advisory T [--commit "desc|scope" …]
  local cid="$1"; shift
  [ -n "$cid" ] || { _a2a_err "usage: a2a advise <cid> --advisory '…' [--commit 'desc|scope' …]"; return 1; }
  local adv; adv="$(rc_advise "$cid" "$@")" || { _a2a_err "advise failed (unknown cid?)"; return 1; }
  local to; to="$(rc_consult_get "$cid" | jq -r '.peerNpub // ""')"
  [ -n "$to" ] || { _a2a_err "consult $cid has no recorded counterpart to send to"; return 1; }
  rc_emit "$adv" --to "$to" && echo "advisory for $cid sent → $to"
}

# ══════════════════════════════════════════════════════════════════════════════════════
# emit — escape hatch: send ANY coordination verb (work.intent, area.claim, peer.announce,
# split.propose, conflict.open, …) with a raw payload. Wraps rc_envelope + rc_emit.
# ══════════════════════════════════════════════════════════════════════════════════════
a2a_emit() {  # <kind> --to <peer|--to-all-peers> [--payload J] [--consult C] [--area A]
  local kind="$1"; shift
  [ -n "$kind" ] || { _a2a_err "usage: a2a emit <kind> --to <peer> [--payload JSON] [--consult CID] [--area AREA]"; return 1; }
  local to="" all=0 payload="{}" cid="" area=""
  while [ $# -gt 0 ]; do case "$1" in
    --to) to="$2"; shift 2;; --to-all-peers) all=1; shift;;
    --payload) payload="$2"; shift 2;; --consult) cid="$2"; shift 2;; --area) area="$2"; shift 2;; *) shift;; esac; done
  local -a envargs=(--payload "$payload"); [ -n "$cid" ] && envargs+=(--consult "$cid"); [ -n "$area" ] && envargs+=(--area "$area")
  local env; env="$(rc_envelope "$kind" "${envargs[@]}")"
  if [ "$all" = "1" ]; then rc_emit "$env" --to-all-peers; else rc_emit "$env" --to "$to"; fi
}

# ══════════════════════════════════════════════════════════════════════════════════════
# registry / peers — list / authorize / deny / onboard / caps.
# ══════════════════════════════════════════════════════════════════════════════════════
a2a_peers()     { bash "$A2A_REGISTRY" list "$@"; }
a2a_authorize() { bash "$A2A_REGISTRY" authorize "$@"; }
a2a_deny()      { bash "$A2A_REGISTRY" deny "$@"; }
a2a_caps()      { bash "$A2A_REGISTRY" caps; }
a2a_onboard()   { bash "$A2A_ONBOARD" "$@"; }

a2a_help() {
  cat <<'EOF'
a2a.sh — one turnkey entry point for every A2A operation. All resolution is baked in.

  a2a whoami                         self npub/name, helper/identity/config/coord paths, daemon status
  a2a check [--since EPOCH|--all]    drain inbound NOW: poll+merge+route (ticket ingest + coordination queue)
  a2a verify [--peer NPUB] [--timeout N]   end-to-end round-trip self-test, loud diagnosis
  a2a daemon {status|start|stop|restart}   session-managed message daemon

  # one-time invite tickets (mutual auto-authorization)
  a2a issue [--caps c,c] [--ttl 15m] [--bind NPUB] [--name L] [--v1]
  a2a redeem <ut2_…|--file PATH> [--relay URL] [--yes] [--timeout N]
  a2a revoke <tid>            a2a tickets [pending|redeemed]

  # manual daemon-path ingest (usually use `a2a check` instead)
  a2a ingest-redeem --from HEX --body '<envelope-json>'
  a2a ingest-grant  --from HEX --body '<envelope-json>'
  a2a ingest-deny   --from HEX --body '<envelope-json>'

  # messaging + coordination
  a2a dm <peer> <message…> [--no-intro]
  a2a consult <coord> --intent '…' [--areas csv --repos csv --changes JSON --questions JSON --urgency high]
  a2a advise  <cid> --advisory '…' [--commit 'desc|scope' …]
  a2a emit <kind> --to <peer|--to-all-peers> [--payload JSON] [--consult CID] [--area AREA]

  # registry / peers
  a2a peers [authorized|pending|denied|peer]     a2a caps
  a2a authorize <peer> <caps>                     a2a deny <peer>
  a2a onboard <npub> --name NAME [--caps csv]
EOF
}

# ── CLI dispatch (only when executed directly, not when sourced) ──────────────────────
_a2a_cli() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    whoami)        a2a_whoami "$@";;
    check)         a2a_check "$@";;
    verify)        a2a_verify "$@";;
    daemon)        a2a_daemon "$@";;
    issue)         a2a_issue "$@";;
    redeem)        a2a_redeem "$@";;
    revoke)        a2a_revoke "$@";;
    tickets)       a2a_tickets "$@";;
    ingest-redeem) a2a_ingest ingest-redeem "$@";;
    ingest-grant)  a2a_ingest ingest-grant "$@";;
    ingest-deny)   a2a_ingest ingest-deny "$@";;
    dm)            a2a_dm "$@";;
    consult)       a2a_consult "$@";;
    advise)        a2a_advise "$@";;
    emit)          a2a_emit "$@";;
    peers)         a2a_peers "$@";;
    authorize)     a2a_authorize "$@";;
    deny)          a2a_deny "$@";;
    onboard)       a2a_onboard "$@";;
    caps)          a2a_caps "$@";;
    help|-h|--help) a2a_help;;
    *) _a2a_err "unknown op '$cmd'"; a2a_help; return 1;;
  esac
}
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  _a2a_cli "$@"
fi
