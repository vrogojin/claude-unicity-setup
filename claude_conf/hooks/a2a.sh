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
# `a2a authorize` is an OWNER-driven CLI (invoked from the /a2a skill, never by auto code),
# so it carries owner-explicit intent: append --owner so it can also un-deny a denied peer.
a2a_authorize() { bash "$A2A_REGISTRY" authorize "$@" --owner; }
a2a_deny()      { bash "$A2A_REGISTRY" deny "$@"; }
a2a_caps()      { bash "$A2A_REGISTRY" caps; }
a2a_onboard()   { bash "$A2A_ONBOARD" "$@"; }

# ══════════════════════════════════════════════════════════════════════════════════════
# rotate — retire this agent's npub for a fresh one (A2A threat-model prereq). A leaked/
# harvested npub is a durable target (it is where our coordination traffic is addressed and
# what a relay allow-list keys on), so rotation replaces it. The chain of trust: the OLD key
# SIGNS an npub-rotation attestation binding old_npub→new_npub — only the holder of the old key
# (not someone who merely harvested the public npub) can authorize the successor — then we
# announce it (relay-publish + DM to owner + each authorized peer, all sent by the OLD key so
# recipients can verify it) and swap identity.json locally, archiving the old key 0600. Peers'
# classify-inbound verifies the attestation and RETIRES the old key, seeding the successor as
# PENDING for the owner to re-authorize (default-deny preserved). DESTRUCTIVE → requires --yes.
# ══════════════════════════════════════════════════════════════════════════════════════
a2a_rotate() {
  local yes=0 reason="" nametag="" no_announce=0
  while [ $# -gt 0 ]; do case "$1" in
    --yes|-y)     yes=1; shift;;
    --reason)     reason="${2:-}"; shift 2;;
    --nametag)    nametag="${2:-}"; shift 2;;
    --no-announce) no_announce=1; shift;;
    *) shift;;
  esac; done

  local id cfg relay helper
  id="$(_a2a_identity)"; cfg="$(_a2a_config)"; relay="$(_a2a_relay)"; helper="$(_a2a_helper)"
  [ -f "$id" ] || { _a2a_err "identity not found ($id) — run setup.sh"; return 1; }
  [ -n "$helper" ] && [ -f "$helper" ] || { _a2a_err "sphere-helper unresolved — run setup.sh"; return 1; }

  local oldNpub; oldNpub="$(jq -r '.npub // ""' "$id" 2>/dev/null)"
  [ -n "$oldNpub" ] || { _a2a_err "current identity has no npub — cannot rotate"; return 1; }

  if [ "$yes" != "1" ]; then
    echo "About to ROTATE this agent's identity npub:"
    echo "  current: $oldNpub"
    echo "  reason:  ${reason:-<none>}"
    echo
    echo "This generates a NEW keypair, signs an old-key attestation, announces it to the owner"
    echo "+ authorized peers, and replaces identity.json (old key archived 0600). The daemon must"
    echo "be restarted afterwards, and the owner must re-authorize the new npub on peers + relay."
    echo "Re-run with --yes to proceed."
    return 2
  fi

  # 1. Generate the successor identity into a private temp file (never on argv/stdout).
  local newId; newId="$(mktemp)"; chmod 600 "$newId"
  if ! _a2a_run_helper create-identity > "$newId" 2>/dev/null || ! jq -e .npub "$newId" >/dev/null 2>&1; then
    rm -f "$newId"; _a2a_err "could not generate a new identity (helper/SDK broken) — run: a2a verify"; return 1
  fi
  local newNpub; newNpub="$(jq -r '.npub' "$newId")"

  # 2. OLD key signs the rotation attestation binding old→new (the trust anchor).
  local att; att="$(_a2a_run_helper rotate-sign --identity "$id" --new-npub "$newNpub" ${reason:+--reason "$reason"} 2>/dev/null)"
  if ! printf '%s' "$att" | _a2a_run_helper rotate-verify >/dev/null 2>&1; then
    rm -f "$newId"; _a2a_err "rotation attestation failed to sign/verify — aborting (identity UNCHANGED)"; return 1
  fi

  # 3. Announce (best-effort) — publish to the relay + DM the owner and every authorized peer,
  #    all signed/sent by the OLD key so recipients can verify the attestation before the swap.
  local announced=0 announceFail=0
  if [ "$no_announce" != "1" ]; then
    local envelope; envelope="$(jq -nc --argjson att "$att" --arg from "$oldNpub" \
      '{kind:"identity.rotate", attestation:$att, fromNpub:$from, message:"npub rotation — please re-authorize the successor"}')"
    # relay-publish the attestation (parameterized-replaceable, discoverable by peers).
    printf '%s' "$att" | _a2a_run_helper relay-publish --relay "$relay" --identity "$id" >/dev/null 2>&1 \
      && announced=$((announced+1)) || announceFail=$((announceFail+1))
    # DM the owner.
    local ownerNpub; ownerNpub="$(jq -r '.owner_npub // ""' "$cfg" 2>/dev/null)"
    if [ -n "$ownerNpub" ] && [ "$ownerNpub" != "null" ]; then
      printf '%s' "$envelope" | _a2a_run_helper send-dm "$ownerNpub" --identity "$id" --relay "$relay" >/dev/null 2>&1 \
        && announced=$((announced+1)) || announceFail=$((announceFail+1))
    fi
    # DM every authorized peer.
    local peersJson; peersJson="$(bash "$A2A_REGISTRY" list authorized 2>/dev/null || echo '[]')"
    local n i pnpub
    n="$(printf '%s' "$peersJson" | jq 'length' 2>/dev/null || echo 0)"
    i=0
    while [ "$i" -lt "${n:-0}" ]; do
      pnpub="$(printf '%s' "$peersJson" | jq -r ".[$i].npub // \"\"" 2>/dev/null)"
      i=$((i+1))
      [ -n "$pnpub" ] && [ "$pnpub" != "null" ] || continue
      printf '%s' "$envelope" | _a2a_run_helper send-dm "$pnpub" --identity "$id" --relay "$relay" >/dev/null 2>&1 \
        && announced=$((announced+1)) || announceFail=$((announceFail+1))
    done
  fi

  # 4. Swap locally — archive the OLD key 0600, install the successor at the same path, and
  #    record the rotation in config (append old npub to previous_npubs; the retired key must
  #    stay a KNOWN dead-end, never silently forgotten).
  local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
  local bak="${id}.rotated-${ts}.bak"
  # Persist the attestation next to the identity so it can be re-announced without re-signing.
  local attFile="$(dirname "$id")/rotation-${ts}.attestation.json"
  printf '%s\n' "$att" > "$attFile"; chmod 600 "$attFile" 2>/dev/null || true
  cp -p "$id" "$bak" 2>/dev/null && chmod 600 "$bak" 2>/dev/null || { rm -f "$newId"; _a2a_err "could not archive old identity — aborting BEFORE swap (identity UNCHANGED)"; return 1; }
  # Atomic install: write beside the target then rename, so a mid-write failure can never leave a
  # truncated identity.json (the .bak archive is the recovery point regardless).
  if ! { cp "$newId" "$id.rot.tmp" && chmod 600 "$id.rot.tmp" && mv -f "$id.rot.tmp" "$id"; }; then
    rm -f "$newId" "$id.rot.tmp"; _a2a_err "could not install new identity — old identity archived at $bak; identity.json may be intact (verify)"; return 1
  fi
  rm -f "$newId"
  if [ -f "$cfg" ]; then
    local tmpc; tmpc="$(mktemp)"
    jq --arg old "$oldNpub" --arg new "$newNpub" --arg ts "$ts" \
      '.previous_npubs = ((.previous_npubs // []) + [$old] | unique)
       | .agent_npub = $new
       | .rotated_at = $ts' "$cfg" > "$tmpc" 2>/dev/null && cat "$tmpc" > "$cfg"
    rm -f "$tmpc"
  fi

  echo "ROTATED identity npub:"
  echo "  old (retired): $oldNpub   → archived: $bak"
  echo "  new (active):  $newNpub"
  echo "  attestation:   $attFile"
  [ "$no_announce" != "1" ] && echo "  announced:     $announced ok, $announceFail failed (attestation signed by the old key)"
  echo
  echo "NEXT STEPS:"
  echo "  1. Restart the message daemon so it picks up the new key:  a2a daemon restart"
  echo "  2. Owner: re-authorize the new npub on each peer (they hold it PENDING) and, if the"
  echo "     relay enforces a NIP-42 allow-list, add $newNpub (and remove the old key)."
  [ -n "$nametag" ] && echo "  3. Re-register the nametag to the new key:  (register-nametag $nametag with the new identity)"
  [ "$announceFail" -gt 0 ] && echo "  NOTE: $announceFail announcement(s) failed — re-publish $attFile / re-DM peers when connectivity returns."
  return 0
}

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

  # identity hardening (A2A threat-model prereq)
  a2a rotate --yes [--reason '…'] [--no-announce]  rotate this agent's npub (old key attests the
                                     successor; announces to owner+peers; archives old key 0600)
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
    rotate)        a2a_rotate "$@";;
    caps)          a2a_caps "$@";;
    help|-h|--help) a2a_help;;
    *) _a2a_err "unknown op '$cmd'"; a2a_help; return 1;;
  esac
}
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  _a2a_cli "$@"
fi
