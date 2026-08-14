#!/bin/bash
# ticket.sh — one-time invite tickets for single-command mutual onboarding.
#
# An issuer runs `ticket.sh issue …` and gets a copy-pasteable, signed, one-time,
# expiring ticket. A redeemer runs `ticket.sh redeem <ticket>` (or `setup.sh --ticket`)
# and ends up MUTUALLY authorized with the issuer — no npub-copying, no operator step on
# either side. Symmetric: "issuer" is just whoever ran `issue`.
#
# The admin decision happens at ISSUE time (running `issue --caps …` IS the authorization
# act, exactly like `onboard-teammate.sh <npub>` today); redemption merely binds that
# already-made decision to the transport-authenticated sender of the redeem message. So a
# hook may auto-authorize here without violating the "ingest records, a skill decides"
# stance elsewhere.
#
# SECURITY posture (the #20/#21/#23 rule): every validation failure FAILS CLOSED and LOUD —
# nothing is authorized, a human-visible reason is emitted (ticket.deny / WARN / Stop-gate),
# and the driving event is left unseen where a retry is meaningful. Secrets are 256-bit and
# stored hash-only; consumption is atomic + flock-serialized (concurrent-redeem safe).
set -uo pipefail

TK_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
# Sourcing these defines functions only (both have source-guards): coord_root, _rc_write,
# rc_envelope, rc_emit, rc_self_npub/name, _ar_npub_to_hex, _ar_validate_caps, AGENT_*,
# and the transport helper resolvers (_tc_sphere_helper / team_identity_path).
. "$TK_HOOK_DIR/agent-registry.sh" 2>/dev/null || true
. "$TK_HOOK_DIR/remote-coord.sh"   2>/dev/null || true

TK_REGISTRY="$TK_HOOK_DIR/agent-registry.sh"
TK_SIF="$TK_HOOK_DIR/sif-guard.sh"
RC_REAP_DAYS="${RC_REAP_DAYS:-14}"
TK_RATE_HEX_HOUR="${TK_RATE_HEX_HOUR:-5}"     # max FAILED redeems / sender hex / hour
TK_RATE_DAY_GLOBAL="${TK_RATE_DAY_GLOBAL:-50}" # max FAILED redeems / day globally
TK_ATTEMPTS_MAX="${TK_ATTEMPTS_MAX:-500}"      # bounded attempt ledger

_tk_now_epoch() { date +%s; }
_tk_now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
_tk_tickets_file()     { printf '%s/tickets.json'          "$(coord_root)"; }
_tk_redemptions_file() { printf '%s/redemptions.json'      "$(coord_root)"; }
_tk_attempts_file()    { printf '%s/ticket-attempts.json'  "$(coord_root)"; }
_tk_sha256() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
_tk_warn()   { echo "WARN(ticket): $*" >&2; }
_tk_err()    { echo "ERROR(ticket): $*" >&2; }

# Resolve the transport helper + our identity the same robust way rc_emit does.
_tk_helper()   { local h=""; type _tc_sphere_helper >/dev/null 2>&1 && h="$(_tc_sphere_helper)"; printf '%s' "$h"; }
_tk_identity() { local i=""; type team_identity_path >/dev/null 2>&1 && i="$(team_identity_path)"; [ -n "$i" ] || i="$TK_HOOK_DIR/../agent/identity.json"; printf '%s' "$i"; }

# Run the sphere-helper with NODE_PATH pointed at the clone's node_modules (helper dir →
# ../node_modules), so the SDK loads even when invoked from outside the clone.
_tk_run_helper() {
  local helper; helper="$(_tk_helper)"
  [ -n "$helper" ] || { _tk_err "sphere-helper.mjs not resolvable (set \$TEAM_SPHERE_HELPER or re-run setup.sh)"; return 3; }
  local np; np="$(cd "$(dirname "$helper")/.." 2>/dev/null && pwd)/node_modules:${NODE_PATH:-}"
  NODE_PATH="$np" node "$helper" "$@"
}

# Like _tk_run_helper, but feeds $1 to the helper on STDIN (the rest are argv). Used for
# ticket-sign/ticket-verify, whose input (payload / signed event) embeds the ticket SECRET —
# it must NEVER land on argv where `ps` / /proc/<pid>/cmdline could leak it.
_tk_run_helper_stdin() {  # <stdin-data> <helper-args...>
  local data="$1"; shift
  local helper; helper="$(_tk_helper)"
  [ -n "$helper" ] || { _tk_err "sphere-helper.mjs not resolvable (set \$TEAM_SPHERE_HELPER or re-run setup.sh)"; return 3; }
  local np; np="$(cd "$(dirname "$helper")/.." 2>/dev/null && pwd)/node_modules:${NODE_PATH:-}"
  printf '%s' "$data" | NODE_PATH="$np" node "$helper" "$@"
}

# Convert a duration like 30m / 24h / 7d (or bare seconds) to epoch-seconds-from-now.
_tk_ttl_to_exp() {
  local ttl="${1:-24h}" now n u; now="$(_tk_now_epoch)"
  case "$ttl" in
    *s) n="${ttl%s}"; u=1;; *m) n="${ttl%m}"; u=60;; *h) n="${ttl%h}"; u=3600;; *d) n="${ttl%d}"; u=86400;;
    *[!0-9]*) _tk_err "bad --ttl '$ttl' (use 30s/30m/24h/7d)"; return 1;; *) n="$ttl"; u=1;;
  esac
  case "$n" in ''|*[!0-9]*) _tk_err "bad --ttl '$ttl'"; return 1;; esac
  printf '%s' "$(( now + n * u ))"
}

# epoch → ISO for the ledger; ISO compare done lexically (both are Z-UTC).
_tk_epoch_to_iso() { date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || python3 -c "import time;print(time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime($1)))"; }

# ── rate limit (issuer side; before any secret comparison) ───────────────────────────
# Returns 0 = under limit (proceed), 1 = over limit (silent drop, no deny/oracle).
_tk_rate_ok() {
  local hex="$1" now hourAgo dayAgo f
  now="$(_tk_now_epoch)"; hourAgo=$(( now - 3600 )); dayAgo=$(( now - 86400 ))
  f="$(_tk_attempts_file)"; [ -f "$f" ] || return 0
  local hexFails dayFails
  hexFails="$(jq --arg h "$hex" --argjson t "$hourAgo" '[.attempts[]? | select(.hex==$h and .ok==false and .at>=$t)] | length' "$f" 2>/dev/null || echo 0)"
  dayFails="$(jq --argjson t "$dayAgo" '[.attempts[]? | select(.ok==false and .at>=$t)] | length' "$f" 2>/dev/null || echo 0)"
  [ "${hexFails:-0}" -lt "$TK_RATE_HEX_HOUR" ] && [ "${dayFails:-0}" -lt "$TK_RATE_DAY_GLOBAL" ]
}
_tk_log_attempt() {  # <hex> <tid> <ok:true|false>
  local hex="$1" tid="$2" ok="$3"
  _rc_write "$(_tk_attempts_file)" '
    .attempts = (((.attempts // []) + [{hex:$hex, tid:$tid, ok:$ok, at:($now|tonumber)}]) | .[-($max|tonumber):])
  ' --arg hex "$hex" --arg tid "$tid" --argjson ok "$ok" --arg now "$(_tk_now_epoch)" --arg max "$TK_ATTEMPTS_MAX" >/dev/null 2>&1 || true
}

# ── emit a ticket verb to a hex/npub ─────────────────────────────────────────────────
_tk_emit() {  # <kind> <payload-json> <to-hex-or-npub>
  local kind="$1" payload="$2" to="$3" env
  env="$(rc_envelope "$kind" --payload "$payload" 2>/dev/null)" || { _tk_err "envelope build failed for $kind"; return 1; }
  rc_emit "$env" --to "$to"
}

# Deny a redeem: log the reason LOUDLY (visible locally, not only in the wire payload),
# record the failed attempt, and send a ticket.deny so the redeemer fails fast (#21 rule).
_tk_deny() {  # <hex> <tid> <reason>
  echo "TICKET DENY $2 <- ${1:0:12}…: $3"
  _tk_log_attempt "$1" "$2" false
  _tk_emit "ticket.deny" "$(jq -nc --arg t "$2" --arg r "$3" '{tid:$t,reason:$r}')" "$1"
}

# ════════════════════════════════════════════════════════════════════════════════════
# ISSUE
# ════════════════════════════════════════════════════════════════════════════════════
tk_issue() {
  local caps="team-coordinate,task-bid,knowledge-share,self-directed,consult,claim-area"
  local grantBack="" ttl="24h" bind="" label="" relay=""
  while [ $# -gt 0 ]; do case "$1" in
    --caps) caps="$2"; shift 2;; --grant-back) grantBack="$2"; shift 2;;
    --ttl) ttl="$2"; shift 2;; --bind) bind="$2"; shift 2;;
    --name|--label) label="$2"; shift 2;; --relay) relay="$2"; shift 2;;
    *) shift;; esac; done
  [ -n "$grantBack" ] || grantBack="$caps"
  # Validate caps against the known set (space-joined; reuse the registry validator).
  local vcaps vgrant
  vcaps="$(_ar_validate_caps "$(printf '%s' "$caps" | tr ',' ' ')")" || { _tk_err "invalid --caps"; return 1; }
  vgrant="$(_ar_validate_caps "$(printf '%s' "$grantBack" | tr ',' ' ')")" || { _tk_err "invalid --grant-back"; return 1; }
  # Warn (do not block) if a destructive cap is included — execution still owner-gated.
  local c; for c in $vcaps; do _ar_is_destructive_cap "$c" 2>/dev/null && _tk_warn "cap '$c' is destructive — grant only permits ASKING; execution stays owner-confirmed"; done

  local iss issName exp secret tid
  iss="$(rc_self_npub)"; [ -n "$iss" ] || { _tk_err "no self identity (run setup.sh)"; return 1; }
  issName="$(rc_self_name 2>/dev/null || echo agent)"
  exp="$(_tk_ttl_to_exp "$ttl")" || return 1
  secret="$(openssl rand 32 2>/dev/null | basenc --base64url 2>/dev/null | tr -d '=' )"
  [ -n "$secret" ] || secret="$(head -c32 /dev/urandom | basenc --base64url | tr -d '=')"
  [ -n "$secret" ] || { _tk_err "could not generate secret"; return 1; }
  tid="t$(_tk_sha256 "$secret" | cut -c1-12)"
  # bind (if given) must be a decodable npub → store as hex for unspoofable compare.
  local bindHex=""
  if [ -n "$bind" ]; then bindHex="$(_ar_npub_to_hex "$bind")" || { _tk_err "--bind must be a valid npub"; return 1; }; fi

  local capsJson grantJson relaysJson
  capsJson="$(printf '%s\n' $vcaps | jq -R . | jq -sc .)"
  grantJson="$(printf '%s\n' $vgrant | jq -R . | jq -sc .)"
  relaysJson="$(jq -nc --arg r "${relay:-${RELAY_URL:-wss://nostr-relay.testnet.unicity.network}}" '[$r]')"

  # Canonical payload (embedded + signed into the event content).
  local payload
  payload="$(jq -nc --argjson v 1 --arg tid "$tid" --arg iss "$iss" --arg issName "$issName" \
      --argjson relays "$relaysJson" --arg secret "$secret" --argjson caps "$capsJson" \
      --argjson grantBack "$grantJson" --argjson exp "$exp" --arg bind "$bindHex" --arg label "$label" \
      '{v:$v, tid:$tid, iss:$iss, issName:$issName, relays:$relays, secret:$secret, caps:$caps, grantBack:$grantBack, exp:$exp, bind:$bind, label:$label}')"

  # Sign the kind-30777 event over the payload.
  local event
  event="$(_tk_run_helper_stdin "$payload" ticket-sign --identity "$(_tk_identity)")" || { _tk_err "ticket-sign failed"; return 1; }

  # Record HASH-ONLY (never the secret) in the pending ledger, under flock.
  _rc_write "$(_tk_tickets_file)" '
    .tickets = ((.tickets // []) + [{
      tid:$tid, secretHash:$sh, caps:$caps, grantBack:$grantBack, bind:$bind, label:$label,
      exp:$exp, status:"pending", createdAt:$now, redeemedBy:null, redeemedAt:"", grantSentAt:""
    }])
  ' --arg tid "$tid" --arg sh "$(_tk_sha256 "$secret")" --argjson caps "$capsJson" --argjson grantBack "$grantJson" \
    --arg bind "$bindHex" --arg label "$label" --arg exp "$(_tk_epoch_to_iso "$exp")" --arg now "$(_tk_now_iso)" \
    || { _tk_err "could not record ticket"; return 1; }

  # Emit the ticket string. Keep base64url padding (basenc --decode needs it) and -w0 to
  # produce a single unwrapped line — stripping '=' broke decode for events whose length was
  # not a multiple of 3.
  local eventB64; eventB64="$(printf '%s' "$event" | jq -c . | basenc --base64url -w0)"
  printf 'unicity-ticket:v1.%s\n' "$eventB64"
  _tk_warn "ticket $tid issued (caps: $(echo "$vcaps" | tr ' ' ','); ttl: $ttl$( [ -n "$bind" ] && echo "; bound"))." >&2
  _tk_warn "This string is a BEARER credential — send it over a private channel; 'ticket.sh revoke $tid' if it leaks." >&2
}

# Decode a ticket string → the signed event JSON on stdout (fail-closed).
_tk_decode() {  # <ticket-string>
  local t="$1"
  case "$t" in unicity-ticket:v1.*) ;; *) _tk_err "not a v1 unicity ticket"; return 1;; esac
  local b64="${t#unicity-ticket:v1.}"
  local ev; ev="$(printf '%s' "$b64" | basenc --decode --base64url 2>/dev/null)" || { _tk_err "ticket is not valid base64url"; return 1; }
  printf '%s' "$ev" | jq -e . >/dev/null 2>&1 || { _tk_err "ticket does not decode to JSON"; return 1; }
  printf '%s' "$ev"
}

# ════════════════════════════════════════════════════════════════════════════════════
# REDEEM  (redeemer side; the whole flow, works PRE-daemon via its own poll)
# ════════════════════════════════════════════════════════════════════════════════════
tk_redeem() {
  local ticket="" ticketFile="" yes=0 timeout=120
  while [ $# -gt 0 ]; do case "$1" in
    --yes) yes=1; shift;; --timeout) timeout="$2"; shift 2;;
    --ticket-file) ticketFile="$2"; shift 2;;
    -*) shift;; *) [ -z "$ticket" ] && ticket="$1"; shift;; esac; done
  # A ticket string embeds the SECRET. Prefer reading it from a file (kept 0600 by the
  # caller, e.g. setup.sh) so it never lands on this process's argv or any child's.
  if [ -n "$ticketFile" ]; then
    [ -f "$ticketFile" ] || { _tk_err "--ticket-file '$ticketFile' not found"; return 1; }
    ticket="$(cat "$ticketFile")"
  fi
  [ -n "$ticket" ] || { _tk_err "usage: redeem <ticket-string>|--ticket-file <path> [--yes] [--timeout N]"; return 1; }

  local event; event="$(_tk_decode "$ticket")" || return 1
  # Verify sig ∧ pubkey==iss BEFORE any network send (fail-closed).
  local vf; vf="$(_tk_run_helper_stdin "$event" ticket-verify)" || { _tk_err "ticket signature INVALID — refusing to redeem"; return 1; }
  [ "$(printf '%s' "$vf" | jq -r '.valid')" = "true" ] || { _tk_err "ticket invalid: $(printf '%s' "$vf" | jq -r '.reason // "?"')"; return 1; }
  local payload; payload="$(printf '%s' "$vf" | jq -c '.payload')"
  # Hard-fail an unknown ticket VERSION on the embedded payload (not just the string prefix):
  # a v2 ticket may carry different fields/semantics we don't understand — refuse it.
  local pv; pv="$(jq -r '.v // ""' <<<"$payload")"
  [ "$pv" = "1" ] || { _tk_err "unsupported ticket version '${pv:-none}' (this build understands v1 only)"; return 1; }
  local tid iss issName secret expEpoch nowEpoch
  tid="$(jq -r '.tid' <<<"$payload")"; iss="$(jq -r '.iss' <<<"$payload")"
  issName="$(jq -r '.issName' <<<"$payload")"; secret="$(jq -r '.secret' <<<"$payload")"
  expEpoch="$(jq -r '.exp' <<<"$payload")"; nowEpoch="$(_tk_now_epoch)"
  [ "$expEpoch" -gt "$nowEpoch" ] 2>/dev/null || { _tk_err "ticket EXPIRED"; return 1; }
  local issHex; issHex="$(_ar_npub_to_hex "$iss")" || { _tk_err "ticket issuer npub undecodable"; return 1; }
  # Caps must be within the known set (fail-closed on an unknown cap).
  local caps grantBack
  caps="$(jq -r '.caps | join(" ")' <<<"$payload")"; grantBack="$(jq -r '.grantBack | join(" ")' <<<"$payload")"
  _ar_validate_caps "$caps" >/dev/null || { _tk_err "ticket names unknown caps"; return 1; }
  _ar_validate_caps "$grantBack" >/dev/null || { _tk_err "ticket names unknown grant-back caps"; return 1; }

  if [ "$yes" != "1" ]; then
    echo "──────────────────────────────────────────────" >&2
    echo " Redeem ticket $tid from $issName ($iss)" >&2
    echo "   they grant you:  $(echo "$caps"      | tr ' ' ',')" >&2
    echo "   you grant them:  $(echo "$grantBack" | tr ' ' ',')" >&2
    echo "   expires:         $(_tk_epoch_to_iso "$expEpoch")" >&2
    echo "──────────────────────────────────────────────" >&2
  fi

  # Cache the issuer as a peer (seed the registry so nametag/name resolves later).
  bash "$TK_REGISTRY" upsert-peer --npub "$iss" --name "$issName" >/dev/null 2>&1 || true
  # Record the local redemption (source of truth for grant-back caps — NOT the wire).
  local grantJson expIso
  grantJson="$(printf '%s\n' $grantBack | jq -R . | jq -sc .)"; expIso="$(_tk_epoch_to_iso "$expEpoch")"
  _rc_write "$(_tk_redemptions_file)" '
    .redemptions = (((.redemptions // []) | map(select(.tid != $tid))) + [{
      tid:$tid, issuerNpub:$iss, issuerHex:$hex, issuerName:$name, grantBack:$gb,
      exp:$exp, status:"sent", sentAt:$now, grantedAt:""
    }])
  ' --arg tid "$tid" --arg iss "$iss" --arg hex "$issHex" --arg name "$issName" --argjson gb "$grantJson" \
    --arg exp "$expIso" --arg now "$(_tk_now_iso)" || { _tk_err "could not record redemption"; return 1; }

  # Send the signed redeem DM.
  local redeemPayload; redeemPayload="$(jq -nc --arg tid "$tid" --arg secret "$secret" --arg npub "$(rc_self_npub)" --arg name "$(rc_self_name 2>/dev/null || echo agent)" '{tid:$tid, secret:$secret, npub:$npub, name:$name}')"
  _tk_emit "ticket.redeem" "$redeemPayload" "$issHex" || { _tk_err "could not send redeem (transport). Re-run after the daemon is up."; return 1; }
  echo "redeem sent to $issName — waiting for grant (up to ${timeout}s)…" >&2

  # Poll for the grant/deny (works pre-daemon: our own check-messages loop).
  local ident cfg deadline sinceTs
  ident="$(_tk_identity)"; cfg="$(dirname "$ident")/config.json"
  sinceTs="$(( nowEpoch - 5 ))"; deadline=$(( nowEpoch + timeout ))
  while [ "$(_tk_now_epoch)" -lt "$deadline" ]; do
    # Daemon path may have already handled it — short-circuit if redemption is terminal.
    local st; st="$(jq -r --arg t "$tid" '.redemptions[]? | select(.tid==$t) | .status' "$(_tk_redemptions_file)" 2>/dev/null)"
    [ "$st" = "granted" ] && { echo "MUTUAL AUTH OK with $issName ($iss)"; return 0; }
    [ "$st" = "denied" ]  && { _tk_err "redeem DENIED by issuer"; return 1; }
    local msgs; msgs="$(_tk_run_helper check-messages --identity "$ident" --config "$cfg" --since "$sinceTs" 2>/dev/null || echo '{"messages":[]}')"
    # Find a ticket.grant or ticket.deny from the issuer hex for our tid.
    local hit; hit="$(printf '%s' "$msgs" | jq -c --arg hex "$issHex" --arg tid "$tid" '
      [.messages[]? | . as $m | ((.body // "") | fromjson? ) as $b
       | select(($m.from // "")==$hex and (($b.kind // "")=="ticket.grant" or ($b.kind // "")=="ticket.deny") and (($b.payload.tid // "")==$tid))
       | {kind:$b.kind, reason:($b.payload.reason // "")}] | first // empty' 2>/dev/null)"
    if [ -n "$hit" ]; then
      local kind; kind="$(printf '%s' "$hit" | jq -r '.kind')"
      if [ "$kind" = "ticket.grant" ]; then
        _tk_finalize_grant "$tid" "$issHex" && { echo "MUTUAL AUTH OK with $issName ($iss)"; return 0; }
        return 1
      else
        local r; r="$(printf '%s' "$hit" | jq -r '.reason')"
        _rc_write "$(_tk_redemptions_file)" '.redemptions |= map(if .tid==$t then (.status="denied") else . end)' --arg t "$tid" >/dev/null 2>&1
        _tk_err "redeem DENIED: $r"; return 1
      fi
    fi
    sleep 5
  done
  _tk_err "no grant within ${timeout}s (issuer offline / relay drop). Redemption recorded; it will finalize via the daemon when the grant arrives."
  return 1
}

# Authorize the issuer using our LOCALLY-stored grant-back caps (never the wire).
_tk_finalize_grant() {  # <tid> <issuerHex>
  local tid="$1" issHex="$2" f grantBack issNpub
  f="$(_tk_redemptions_file)"
  grantBack="$(jq -r --arg t "$tid" --arg hex "$issHex" '.redemptions[]? | select(.tid==$t and .issuerHex==$hex) | .grantBack | join(" ")' "$f" 2>/dev/null)"
  [ -n "$grantBack" ] || { _tk_err "no matching sent redemption for grant (tid=$tid) — IGNORING"; return 1; }
  # Seed the issuer entry (keyed by hex) so authorize resolves even if redeem didn't pre-seed.
  issNpub="$(jq -r --arg t "$tid" '.redemptions[]? | select(.tid==$t) | .issuerNpub // ""' "$f" 2>/dev/null)"
  if [ -n "$issNpub" ]; then bash "$TK_REGISTRY" upsert-peer --pubkey "$issHex" --npub "$issNpub" >/dev/null 2>&1 || true
  else                       bash "$TK_REGISTRY" upsert-peer --pubkey "$issHex"                     >/dev/null 2>&1 || true; fi
  bash "$TK_REGISTRY" authorize "$issHex" "$grantBack" --note "ticket $tid (issuer)" >/dev/null 2>&1 || { _tk_err "authorize issuer failed"; return 1; }
  _rc_write "$f" '.redemptions |= map(if .tid==$t then (.status="granted" | .grantedAt=$now) else . end)' --arg t "$tid" --arg now "$(_tk_now_iso)" >/dev/null 2>&1
  return 0
}

# ════════════════════════════════════════════════════════════════════════════════════
# INGEST (issuer/redeemer daemon-path handlers; called by classify-inbound)
# Input = the queued MESSAGE wrapper {from(hex), body(envelope-json), id, …}.
# Identity is ALWAYS the transport .from hex — never a payload claim.
# ════════════════════════════════════════════════════════════════════════════════════
_tk_read_msg() {  # reads wrapper from $1 (json/file/-), sets globals MFROM,MBODY,MKIND,MPAY
  local raw="$1" m
  if [ "$raw" = "-" ]; then m="$(cat)"; elif [ -f "$raw" ]; then m="$(cat "$raw")"; else m="$raw"; fi
  MFROM="$(printf '%s' "$m" | jq -r '.from // ""')"
  MBODY="$(printf '%s' "$m" | jq -r '.body // ""')"
  MKIND="$(printf '%s' "$MBODY" | jq -r '.kind // ""' 2>/dev/null)"
  MPAY="$(printf '%s' "$MBODY" | jq -c '.payload // {}' 2>/dev/null)"
  [ -n "$MFROM" ] && printf '%s' "$MFROM" | grep -Eq '^[0-9a-f]{64}$'
}

tk_ingest_redeem() {  # issuer side
  _tk_read_msg "${1:--}" || { _tk_warn "ticket.redeem: no valid sender hex"; return 0; }
  local hex="$MFROM"
  local tid secret; tid="$(jq -r '.tid // ""' <<<"$MPAY")"; secret="$(jq -r '.secret // ""' <<<"$MPAY")"
  [ -n "$tid" ] && [ -n "$secret" ] || { _tk_warn "ticket.redeem malformed from ${hex:0:12}"; return 0; }
  # Rate limit BEFORE any secret comparison (silent drop past the limit — no oracle).
  _tk_rate_ok "$hex" || { _tk_warn "rate-limited redeem from ${hex:0:12}… (dropped)"; return 0; }

  local f rec; f="$(_tk_tickets_file)"
  rec="$(jq -c --arg t "$tid" '.tickets[]? | select(.tid==$t)' "$f" 2>/dev/null | head -1)"
  if [ -z "$rec" ]; then _tk_deny "$hex" "$tid" "unknown-ticket"; return 0; fi

  local status secretHash bind expIso redeemedHex
  status="$(jq -r '.status' <<<"$rec")"; secretHash="$(jq -r '.secretHash' <<<"$rec")"
  bind="$(jq -r '.bind // ""' <<<"$rec")"; expIso="$(jq -r '.exp' <<<"$rec")"
  redeemedHex="$(jq -r '.redeemedBy.hex // ""' <<<"$rec")"

  # Idempotent re-redeem: same hex, already redeemed. Re-authorize BEFORE re-sending the
  # grant — the FIRST redeem may have burned the ticket "redeemed" yet failed to authorize
  # (write/lock error); resending a grant then would falsely report MUTUAL AUTH while our
  # registry never held the peer. authorize is idempotent, so this is a safe no-op when the
  # peer is already authorized, and a real repair when it isn't. Fail LOUD, don't re-grant.
  if [ "$status" = "redeemed" ] && [ "$redeemedHex" = "$hex" ]; then
    local rrCaps rrLabel; rrCaps="$(jq -r '.caps | join(" ")' <<<"$rec")"; rrLabel="$(jq -r '.label // ""' <<<"$rec")"
    bash "$TK_REGISTRY" upsert-peer --pubkey "$hex" >/dev/null 2>&1 || true
    if ! bash "$TK_REGISTRY" authorize "$hex" "$rrCaps" --note "ticket $tid: $rrLabel (re-redeem)" >/dev/null 2>&1; then
      _tk_err "re-redeem authorize FAILED tid=$tid ${hex:0:12}… — NOT re-granting (registry never held this peer)"; return 0
    fi
    _tk_send_grant "$tid" "$hex" "$rec"; return 0
  fi
  # Validate: secret hash, expiry, bind (against transport hex), status.
  if [ "$(_tk_sha256 "$secret")" != "$secretHash" ]; then _tk_deny "$hex" "$tid" "invalid"; return 0; fi
  local nowIso; nowIso="$(_tk_now_iso)"
  if [ "$expIso" \< "$nowIso" ]; then _tk_deny "$hex" "$tid" "expired"; return 0; fi
  if [ -n "$bind" ] && [ "$bind" != "$hex" ]; then _tk_deny "$hex" "$tid" "bind-mismatch"; return 0; fi
  if [ "$status" != "pending" ]; then _tk_deny "$hex" "$tid" "already-redeemed"; return 0; fi

  # ATOMIC consume: pending → redeemed, only for THIS tid; then re-read to confirm we won.
  local rname; rname="$(jq -r '.name // ""' <<<"$MPAY")"
  local rnpub; rnpub="$(jq -r '.npub // ""' <<<"$MPAY")"
  _rc_write "$f" '
    .tickets |= map(if .tid==$t and .status=="pending" and (.exp > $now)
      then (.status="redeemed" | .redeemedBy={hex:$hex,npub:$npub,name:$name} | .redeemedAt=$now)
      else . end)
  ' --arg t "$tid" --arg hex "$hex" --arg npub "$rnpub" --arg name "$rname" --arg now "$nowIso" \
    || { _tk_err "consume write failed (lock) tid=$tid — will retry"; return 1; }  # unseen → retried

  local winner; winner="$(jq -r --arg t "$tid" '.tickets[]? | select(.tid==$t) | .redeemedBy.hex // ""' "$f" 2>/dev/null)"
  if [ "$winner" != "$hex" ]; then _tk_deny "$hex" "$tid" "already-redeemed"; return 0; fi

  # Seed a registry entry keyed by the TRANSPORT hex so `authorize` (which resolves an
  # existing key or an npub) works for this not-yet-seen peer. The payload npub is a hint —
  # used only if it decodes to the transport hex; otherwise the hex alone is authoritative.
  local seedNpub=""
  if [ -n "$rnpub" ]; then
    local nh; nh="$(_ar_npub_to_hex "$rnpub" 2>/dev/null || true)"
    [ "$nh" = "$hex" ] && seedNpub="$rnpub"
  fi
  if [ -n "$seedNpub" ]; then bash "$TK_REGISTRY" upsert-peer --pubkey "$hex" --npub "$seedNpub" --name "$rname" >/dev/null 2>&1 || true
  else                        bash "$TK_REGISTRY" upsert-peer --pubkey "$hex" --name "$rname"                     >/dev/null 2>&1 || true; fi

  # We won: authorize the redeemer (fires #14 deferred-replay), then grant back.
  local caps label; caps="$(jq -r '.caps | join(" ")' <<<"$rec")"; label="$(jq -r '.label // ""' <<<"$rec")"
  if ! bash "$TK_REGISTRY" authorize "$hex" "$caps" --note "ticket $tid: $label" >/dev/null 2>&1; then
    _tk_err "authorize redeemer failed tid=$tid"; return 0
  fi
  _tk_log_attempt "$hex" "$tid" true
  _tk_send_grant "$tid" "$hex" "$(jq -c --arg t "$tid" '.tickets[]? | select(.tid==$t)' "$f" | head -1)"
  echo "TICKET REDEEMED: $tid by ${hex:0:12}… → authorized (caps: $(echo "$caps" | tr ' ' ','))"
}

_tk_send_grant() {  # <tid> <hex> <ticket-rec-json>
  local tid="$1" hex="$2" rec="$3"
  local caps grantBack issName
  caps="$(jq -c '.caps' <<<"$rec")"; grantBack="$(jq -c '.grantBack' <<<"$rec")"
  issName="$(rc_self_name 2>/dev/null || echo agent)"
  local gp; gp="$(jq -nc --arg t "$tid" --argjson caps "$caps" --argjson gb "$grantBack" --arg n "$issName" '{tid:$t,status:"granted",caps:$caps,grantBack:$gb,issuerName:$n}')"
  if _tk_emit "ticket.grant" "$gp" "$hex"; then
    _rc_write "$(_tk_tickets_file)" '.tickets |= map(if .tid==$t then (.grantSentAt=$now) else . end)' --arg t "$tid" --arg now "$(_tk_now_iso)" >/dev/null 2>&1
  else
    _tk_warn "grant send failed tid=$tid — peer's re-redeem will re-grant"
  fi
}

tk_ingest_grant() {  # redeemer side, daemon path (late grant)
  _tk_read_msg "${1:--}" || { _tk_warn "ticket.grant: no valid sender hex"; return 0; }
  local hex="$MFROM" tid; tid="$(jq -r '.tid // ""' <<<"$MPAY")"
  [ -n "$tid" ] || { _tk_warn "ticket.grant malformed"; return 0; }
  local match; match="$(jq -r --arg t "$tid" --arg h "$hex" '.redemptions[]? | select(.tid==$t and .issuerHex==$h and .status=="sent") | .tid' "$(_tk_redemptions_file)" 2>/dev/null)"
  [ -n "$match" ] || { _tk_warn "ticket.grant from ${hex:0:12}… has no matching pending redemption (tid=$tid) — IGNORING"; return 0; }
  _tk_finalize_grant "$tid" "$hex" && echo "TICKET GRANT applied: mutual auth with issuer ${hex:0:12}… (tid=$tid)"
}

tk_ingest_deny() {  # redeemer side
  _tk_read_msg "${1:--}" || return 0
  local hex="$MFROM" tid reason; tid="$(jq -r '.tid // ""' <<<"$MPAY")"; reason="$(jq -r '.reason // "invalid"' <<<"$MPAY")"
  local match; match="$(jq -r --arg t "$tid" --arg h "$hex" '.redemptions[]? | select(.tid==$t and .issuerHex==$h and .status=="sent") | .tid' "$(_tk_redemptions_file)" 2>/dev/null)"
  [ -n "$match" ] || { _tk_warn "ticket.deny with no matching redemption — ignoring"; return 0; }
  _rc_write "$(_tk_redemptions_file)" '.redemptions |= map(if .tid==$t then (.status="denied") else . end)' --arg t "$tid" >/dev/null 2>&1
  _tk_err "ticket $tid DENIED by issuer: $reason"
}

# ════════════════════════════════════════════════════════════════════════════════════
# list / revoke / reap / self-test
# ════════════════════════════════════════════════════════════════════════════════════
tk_list() {
  local filt="${1:-}"; local f; f="$(_tk_tickets_file)"; [ -f "$f" ] || { echo '[]'; return 0; }
  jq -c --arg s "$filt" '[.tickets[]? | select($s=="" or .status==$s) | {tid,status,caps,exp,label,redeemedBy:(.redeemedBy.hex // null)}]' "$f"
}
tk_revoke() {
  local tid="${1:-}"; [ -n "$tid" ] || { _tk_err "usage: revoke <tid>"; return 1; }
  local f; f="$(_tk_tickets_file)"
  jq -e --arg t "$tid" '.tickets[]? | select(.tid==$t and .status=="pending")' "$f" >/dev/null 2>&1 || { _tk_err "no pending ticket $tid"; return 1; }
  _rc_write "$f" '.tickets |= map(if .tid==$t and .status=="pending" then (.status="revoked") else . end)' --arg t "$tid" && echo "revoked $tid"
}
tk_reap() {
  local now; now="$(_tk_now_iso)"
  _rc_write "$(_tk_tickets_file)" '.tickets |= map(if .status=="pending" and .exp < $now then (.status="expired") else . end)' --arg now "$now" >/dev/null 2>&1 || true
  # Prune terminal records older than RC_REAP_DAYS.
  local cutoff; cutoff="$(_tk_epoch_to_iso "$(( $(_tk_now_epoch) - RC_REAP_DAYS*86400 ))")"
  _rc_write "$(_tk_tickets_file)" '.tickets |= map(select(.status=="pending" or .status=="redeemed" or (.createdAt // "9999") > $c))' --arg c "$cutoff" >/dev/null 2>&1 || true
  _rc_write "$(_tk_redemptions_file)" '.redemptions |= map(select(.status=="sent" or (.sentAt // "9999") > $c))' --arg c "$cutoff" >/dev/null 2>&1 || true
  echo "reaped (expired past-exp pending; pruned terminal older than ${RC_REAP_DAYS}d)"
}
tk_self_test() {
  local tmp; tmp="$(mktemp -d)"; local id="$tmp/id.json"
  _tk_run_helper create-identity > "$id" 2>/dev/null
  local iss; iss="$(jq -r .npub "$id")"
  local p; p="$(jq -nc --arg iss "$iss" '{v:1,tid:"tselftest0001",iss:$iss,issName:"self",relays:["wss://x"],secret:"x",caps:["consult"],grantBack:["consult"],exp:9999999999,bind:"",label:"self"}')"
  local ev; ev="$(_tk_run_helper_stdin "$p" ticket-sign --identity "$id")"
  local ok; ok="$(_tk_run_helper_stdin "$ev" ticket-verify | jq -r .valid)"
  rm -rf "$tmp"
  [ "$ok" = "true" ] && echo "self-test OK (sign→verify round-trip)" || { echo "self-test FAILED"; return 1; }
}

# ── CLI dispatch (only when executed directly, not when sourced) ──────────────────────
_tk_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    issue)         tk_issue "$@";;
    redeem)        tk_redeem "$@";;
    list)          tk_list "$@";;
    revoke)        tk_revoke "$@";;
    reap)          tk_reap "$@";;
    ingest-redeem) tk_ingest_redeem "${1:--}";;
    ingest-grant)  tk_ingest_grant  "${1:--}";;
    ingest-deny)   tk_ingest_deny   "${1:--}";;
    self-test)     tk_self_test;;
    decode)        _tk_decode "${1:-}";;
    *) echo "usage: ticket.sh {issue|redeem|list|revoke|reap|ingest-redeem|ingest-grant|ingest-deny|self-test} …" >&2; return 1;;
  esac
}
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  _tk_cli "$@"
fi
