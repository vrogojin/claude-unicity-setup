#!/bin/bash
# gptbridge.sh — T2 ChatGPT-session consult-relay lifecycle + in-session verbs.
#
# The literal owner ask: "let my ChatGPT session and this Claude Code session
# consult each other." ChatGPT can only reach us as an MCP *client* over public
# HTTPS (§1.1), so T2 is a tiny loopback relay (relay.mjs) fronted by a
# cloudflared quick tunnel, registered as a ChatGPT developer-mode connector.
# This script is the control plane around it:
#
#   start|stop|status|url            relay + tunnel supervisor, capability-URL
#                                     token mint (rotated per start), TTL, 0600 state
#   ingest --question … [--context]  inject an inbound consult AS a2a peer traffic
#                                     (rides classify-inbound: SIF/quarantine, dedup,
#                                     Stop-gate, /deny-agent) — the relay calls this
#   reply <consult_id> --text …       owner-approved answer → outbox (secret-scanned)
#   ask "<question>"                  Claude-initiated question → outbox (pull-only)
#   pending                          list inbound consults awaiting a reply
#   reply-get <consult_id>           relay sync-wait: pop a ready reply (single-delivery)
#   deliver                          relay check_relay: pop all undelivered items
#   register-peer                    idempotent registry entry for pseudo-peer
#   reap-session                     SessionEnd reap (stop_with_session)
#   bridge-hex | preflight           helpers
#
# SECURITY POSTURE (design §0.2, §9): ChatGPT NEVER reaches a tool/file/exec on
# this surface — the relay only enqueues consult text and serves owner-approved
# replies. Inbound is UNTRUSTED DATA through the a2a quarantine. Auth is a
# per-start capability-URL token; loopback-only relay; cloudflared is the only
# ingress; TTL auto-stop; SessionEnd reap; kill-switches at every layer.
#
# Default OFF: inert unless gptbridge.enabled && gptbridge.relay.enabled in
# .claude/agent/config.json. GPTBRIDGE_DISABLE=1 refuses mid-flight.
#
# No -e (siblings omit it too): guarded with || true; always exits deliberately.
set -uo pipefail

GB_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
GB_CLAUDE_DIR="$(cd "$GB_HOOK_DIR/../.." 2>/dev/null && pwd || echo .)"     # .../.claude
GB_HOOKS="$GB_HOOK_DIR/.."                                                  # .../.claude/hooks
. "$GB_HOOK_DIR/../state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"
GB_DIR="$STATE_DIR/gptbridge"
GB_INBOX="$GB_DIR/inbox"
GB_OUTBOX="$GB_DIR/outbox.jsonl"
GB_STATE="$GB_DIR/relay.json"
GB_LOCK="$GB_DIR/relay.lock"
GB_OUTLOCK="$GB_DIR/outbox.lock"
GB_RELAY_LOG="$GB_DIR/relay.log"
GB_TUNNEL_LOG="$GB_DIR/tunnel.log"
GB_RATE="$GB_DIR/rate.jsonl"
mkdir -p "$GB_INBOX" 2>/dev/null || true

REGISTRY="$GB_HOOKS/agent-registry.sh"
CLASSIFY="$GB_HOOKS/classify-inbound.sh"
SECRET_SCAN="$GB_HOOKS/lib/secret-scan.sh"

# CONFIG_FILE: env project dir first (hooks always have it), else derive from us.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/.claude/agent/config.json" ]; then
  CONFIG_FILE="$CLAUDE_PROJECT_DIR/.claude/agent/config.json"
else
  CONFIG_FILE="$GB_CLAUDE_DIR/agent/config.json"
fi

_gb_log()  { printf '[gptbridge] %s\n' "$*" >&2; }
_gb_err()  { printf 'ERROR(gptbridge): %s\n' "$*" >&2; }
_gb_now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- config accessors (fail-closed to OFF/defaults) ---------------------------
_gb_cfg() { # <jq-filter> <default>
  local f="$1" d="$2" v
  v="$(jq -r "$f // empty" "$CONFIG_FILE" 2>/dev/null || true)"
  [ -n "$v" ] && [ "$v" != "null" ] && printf '%s' "$v" || printf '%s' "$d"
}
gb_master_on() { [ "$(_gb_cfg '.gptbridge.enabled' false)" = "true" ]; }
gb_relay_on()  { [ "$(_gb_cfg '.gptbridge.relay.enabled' false)" = "true" ]; }
gb_killed()    { [ "${GPTBRIDGE_DISABLE:-}" = "1" ]; }
gb_enabled()   { ! gb_killed && gb_master_on && gb_relay_on; }

GB_PORT="$(_gb_cfg '.gptbridge.relay.port' 8873)"
GB_TTL_HOURS="$(_gb_cfg '.gptbridge.relay.ttl_hours' 4)"
GB_EXPOSE="$(_gb_cfg '.gptbridge.relay.expose' quicktunnel)"
GB_SYNC_WAIT="$(_gb_cfg '.gptbridge.relay.sync_wait_s' 20)"
GB_MAX_KB="$(_gb_cfg '.gptbridge.relay.max_consult_kb' 16)"
GB_MAX_PER_HR="$(_gb_cfg '.gptbridge.relay.max_consults_per_hour' 30)"
GB_REPLY_POLICY="$(_gb_cfg '.gptbridge.relay.reply_policy' owner_approve)"
GB_STOP_WITH_SESSION="$(_gb_cfg '.gptbridge.relay.stop_with_session' true)"
GB_ADVANCED="$(_gb_cfg '.gptbridge.advanced_read_tools' false)"
case "$GB_PORT" in ''|*[!0-9]*) GB_PORT=8873;; esac
case "$GB_TTL_HOURS" in ''|*[!0-9]*) GB_TTL_HOURS=4;; esac

# =============================================================================
# Pseudo-peer identity (OD-6): a STABLE synthetic 64-hex transport key so the
# registry (keyed by pubkey hex) can hold an authorized `chatgpt-bridge` entry
# with a single `consult` capability. Deterministic → setup + relay agree, and
# /deny-agent chatgpt-bridge flips this exact key to denied.
# =============================================================================
GB_BRIDGE_NAME="chatgpt-bridge"
gb_bridge_hex() {
  printf 'gptbridge:pseudo-peer:%s:v1' "$GB_BRIDGE_NAME" \
    | sha256sum 2>/dev/null | cut -c1-64
}

gb_register_peer() { # idempotent: create + authorize the pseudo-peer (owner path)
  [ -x "$REGISTRY" ] || { _gb_err "registry not found at $REGISTRY"; return 1; }
  local hex st; hex="$(gb_bridge_hex)"
  st="$(bash "$REGISTRY" status "$hex" 2>/dev/null || echo unknown)"
  # NEVER silently un-deny: if the owner denied the bridge, leave it denied.
  if [ "$st" = "denied" ]; then
    _gb_log "pseudo-peer $GB_BRIDGE_NAME is DENIED — leaving deny in place"
    return 0
  fi
  if [ "$st" != "authorized" ]; then
    bash "$REGISTRY" upsert-pending --pubkey "$hex" --name "$GB_BRIDGE_NAME" --type dm \
      --intro "Local pseudo-peer: the ChatGPT-session consult relay (gptbridge T2). Inbound consult text is UNTRUSTED external data." \
      >/dev/null 2>&1 || true
    bash "$REGISTRY" authorize "$hex" consult --owner \
      --note "gptbridge T2 relay pseudo-peer (consult only; internet-exposed inbound)" \
      >/dev/null 2>&1 || true
  fi
  return 0
}

# =============================================================================
# INGEST — inject an inbound consult as a2a peer traffic through classify-inbound
# so it inherits SIF/quarantine, dedup, the Stop-gate surface, and sticky-deny.
# consult_id is CONTENT-KEYED (a ChatGPT retry of the same question can't double-
# queue). Prints one JSON line {consult_id,status}. status ∈ queued|duplicate|
# quarantined|denied|dropped.
# =============================================================================
gb_consult_id() { # <question>
  printf 'gb_%s' "$(printf '%s|%s' "$(gb_bridge_hex)" "$1" | sha1sum 2>/dev/null | cut -c1-16)"
}

gb_rate_ok() { # returns 0 if under the per-hour cap, else 1 (and records the hit)
  local now cutoff cnt
  now="$(date -u +%s)"; cutoff=$((now - 3600))
  # prune + count within the sliding hour
  if [ -f "$GB_RATE" ]; then
    cnt="$(awk -v c="$cutoff" '$1+0 >= c {n++} END{print n+0}' "$GB_RATE" 2>/dev/null || echo 0)"
  else
    cnt=0
  fi
  [ "$cnt" -ge "$GB_MAX_PER_HR" ] 2>/dev/null && return 1
  # NB: the group MUST exit 0 (a bare `[ -f ] && awk` short-circuits to exit 1 when
  # the file is absent, which would skip the mv and never persist the counter).
  { printf '%s\n' "$now"; if [ -f "$GB_RATE" ]; then awk -v c="$cutoff" '$1+0 >= c' "$GB_RATE" 2>/dev/null; fi; true; } \
    > "$GB_RATE.tmp" 2>/dev/null
  mv "$GB_RATE.tmp" "$GB_RATE" 2>/dev/null || true
  return 0
}

gb_ingest() {
  local question="" context=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --question) question="${2:-}"; shift 2;;
      --context)  context="${2:-}"; shift 2;;
      *) shift;;
    esac
  done
  if ! gb_enabled; then
    printf '{"consult_id":"","status":"disabled"}\n'; return 0
  fi
  [ -n "$question" ] || { printf '{"consult_id":"","status":"empty"}\n'; return 0; }
  # size cap (bytes)
  local qbytes; qbytes="$(printf '%s%s' "$question" "$context" | wc -c | tr -d ' ')"
  if [ "$qbytes" -gt $((GB_MAX_KB * 1024)) ] 2>/dev/null; then
    printf '{"consult_id":"","status":"too_large"}\n'; return 0
  fi
  # rate cap
  if ! gb_rate_ok; then printf '{"consult_id":"","status":"rate_limited"}\n'; return 0; fi

  local cid hex; cid="$(gb_consult_id "$question")"; hex="$(gb_bridge_hex)"
  # dedup fast-path
  if [ -f "$GB_INBOX/$cid.json" ]; then
    printf '{"consult_id":"%s","status":"duplicate"}\n' "$cid"; return 0
  fi
  # sticky-deny fast-path (authoritative check is classify-inbound too)
  local st; st="$(bash "$REGISTRY" status "$hex" 2>/dev/null || echo unknown)"
  if [ "$st" = "denied" ]; then
    printf '{"consult_id":"%s","status":"denied"}\n' "$cid"; return 0
  fi

  # Build the gptbridge.consult envelope + DM wrapper, append to agent-messages,
  # and run the classifier (which enqueues/quarantines/deny-drops).
  local env msg sf now; now="$(_gb_now)"
  # message is an OBJECT {text:…} — classify-inbound extracts `.message.text` for
  # DISPLAY_BODY; a bare string there makes its jq indexing raise and drop the text.
  env="$(jq -nc --arg from "$GB_BRIDGE_NAME" --arg cid "$cid" --arg q "$question" --arg ctx "$context" \
    '{a2a:"1", kind:"gptbridge.consult", id:$cid, from:$from, fromNpub:"",
      consult_id:$cid, message:{text:$q}, context:$ctx}')"
  msg="$(jq -nc --arg from "$hex" --arg body "$env" --arg ts "$now" \
    '{type:"dm", from:$from, from_name:"chatgpt-bridge", body:$body, timestamp:$ts, priority:false, read:false}')"
  sf="$STATE_DIR/agent-messages.json"
  (
    flock 9 2>/dev/null || true
    if [ -f "$sf" ] && jq -e 'type=="object"' "$sf" >/dev/null 2>&1; then
      jq -c --argjson m "$msg" '.messages = ((.messages // []) + [$m]) | .unread=true | .unread_count = ((.unread_count // 0)+1)' \
        "$sf" > "$sf.tmp.$$" 2>/dev/null && mv "$sf.tmp.$$" "$sf" || rm -f "$sf.tmp.$$"
    else
      jq -nc --argjson m "$msg" '{messages:[$m], unread:true, unread_count:1}' > "$sf" 2>/dev/null || true
    fi
  ) 9>"$sf.lock" 2>/dev/null

  CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$GB_CLAUDE_DIR/.." 2>/dev/null && pwd)}" \
    bash "$CLASSIFY" >/dev/null 2>&1 || true

  # Outcome from disk (classify-inbound is the authority). Deny/rate/size are all
  # caught above BEFORE injection, so the only post-classify non-queued outcome
  # is a SIF quarantine (the content-guard held the text for owner review).
  if [ -f "$GB_INBOX/$cid.json" ]; then
    printf '{"consult_id":"%s","status":"queued"}\n' "$cid"; return 0
  fi
  printf '{"consult_id":"%s","status":"quarantined"}\n' "$cid"; return 0
}

# =============================================================================
# OUTBOX — owner-approved replies + Claude-initiated questions to ChatGPT.
# Append-only JSONL with a `delivered` flag; single-delivery under flock.
# =============================================================================
_gb_outbox_append() { # <json-line>
  ( flock 9 2>/dev/null || true; printf '%s\n' "$1" >> "$GB_OUTBOX"; ) 9>"$GB_OUTLOCK" 2>/dev/null
}

gb_reply() { # <consult_id> --text TEXT   (owner-approved answer)
  local cid="${1:-}"; shift 2>/dev/null || true
  local text=""
  while [ $# -gt 0 ]; do case "$1" in --text) text="${2:-}"; shift 2;; *) shift;; esac; done
  [ -n "$cid" ] || { _gb_err "usage: gptbridge.sh reply <consult_id> --text '<answer>'"; return 1; }
  [ -n "$text" ] || { _gb_err "reply text is empty"; return 1; }
  if [ ! -f "$GB_INBOX/$cid.json" ]; then
    _gb_err "no pending consult '$cid' (see: gptbridge.sh pending)"; return 1
  fi
  # Secret-scan tripwire — an owner-authored reply should still never carry a key.
  if [ -f "$SECRET_SCAN" ]; then
    local hits; hits="$(printf '%s' "$text" | bash "$SECRET_SCAN" scan 2>/dev/null)"
    if [ -n "$hits" ]; then
      _gb_err "reply BLOCKED — secret-scan matched: $(printf '%s' "$hits" | tr '\n' ',' | sed 's/,$//'). Remove the secret and retry."
      return 2
    fi
  fi
  local now; now="$(_gb_now)"
  _gb_outbox_append "$(jq -nc --arg cid "$cid" --arg t "$text" --arg ts "$now" \
    '{type:"reply", consult_id:$cid, text:$t, ts:$ts, delivered:false}')"
  # mark the inbound consult answered
  jq -c --arg ts "$now" '.status="answered" | .answeredAt=$ts' "$GB_INBOX/$cid.json" \
    > "$GB_INBOX/$cid.json.tmp" 2>/dev/null && mv "$GB_INBOX/$cid.json.tmp" "$GB_INBOX/$cid.json" || rm -f "$GB_INBOX/$cid.json.tmp"
  echo "reply queued for ChatGPT (consult $cid). It is delivered when ChatGPT next calls check_relay."
  return 0
}

gb_ask() { # "<question>"   (Claude-initiated question, pull-only)
  local q="$*"
  [ -n "$q" ] || { _gb_err "usage: gptbridge.sh ask '<question for ChatGPT>'"; return 1; }
  if [ -f "$SECRET_SCAN" ]; then
    local hits; hits="$(printf '%s' "$q" | bash "$SECRET_SCAN" scan 2>/dev/null)"
    [ -n "$hits" ] && { _gb_err "question BLOCKED — secret-scan matched: $(printf '%s' "$hits" | tr '\n' ',' | sed 's/,$//')."; return 2; }
  fi
  local id now; now="$(_gb_now)"; id="q_$(printf '%s|%s' "$now" "$q" | sha1sum 2>/dev/null | cut -c1-16)"
  _gb_outbox_append "$(jq -nc --arg id "$id" --arg t "$q" --arg ts "$now" \
    '{type:"question", id:$id, text:$t, ts:$ts, delivered:false}')"
  echo "question queued for ChatGPT ($id). ChatGPT receives it when the owner tells it to \"check the relay\" (pull-only)."
  return 0
}

gb_reply_get() { # <consult_id>  → print reply text + mark delivered; exit 1 if none
  local cid="${1:-}"; [ -n "$cid" ] || return 1
  [ -f "$GB_OUTBOX" ] || return 1
  local out; out="$( (
    flock 9 2>/dev/null || true
    found="$(jq -c --arg cid "$cid" 'select(.type=="reply" and .consult_id==$cid and (.delivered|not))' "$GB_OUTBOX" 2>/dev/null | head -1)"
    [ -n "$found" ] || exit 1
    # mark that exact line delivered (match by consult_id, first undelivered)
    awk -v cid="$cid" '
      BEGIN{done=0}
      { if(!done && index($0,"\"type\":\"reply\"") && index($0,"\"consult_id\":\""cid"\"") && index($0,"\"delivered\":false")){ sub(/"delivered":false/,"\"delivered\":true"); done=1 } print }
    ' "$GB_OUTBOX" > "$GB_OUTBOX.tmp" 2>/dev/null && mv "$GB_OUTBOX.tmp" "$GB_OUTBOX"
    printf '%s' "$found"
  ) 9>"$GB_OUTLOCK" )"
  [ -n "$out" ] || return 1
  printf '%s' "$out" | jq -r '.text' 2>/dev/null
  return 0
}

gb_deliver() { # print JSON array of all undelivered items; mark them delivered
  [ -f "$GB_OUTBOX" ] || { echo '[]'; return 0; }
  local arr; arr="$( (
    flock 9 2>/dev/null || true
    items="$(jq -sc '[ .[] | select(.delivered|not) ]' "$GB_OUTBOX" 2>/dev/null || echo '[]')"
    # mark everything delivered
    jq -c '.delivered=true' "$GB_OUTBOX" > "$GB_OUTBOX.tmp" 2>/dev/null && mv "$GB_OUTBOX.tmp" "$GB_OUTBOX"
    printf '%s' "$items"
  ) 9>"$GB_OUTLOCK" )"
  [ -n "$arr" ] && printf '%s\n' "$arr" || echo '[]'
  return 0
}

gb_pending() { # list inbound consults awaiting a reply (JSON array)
  local out='[]'
  if [ -d "$GB_INBOX" ]; then
    out="$(for f in "$GB_INBOX"/*.json; do [ -e "$f" ] || continue
      [ "$(jq -r '.status // "pending"' "$f" 2>/dev/null)" = "pending" ] && cat "$f"
    done | jq -sc '.' 2>/dev/null || echo '[]')"
  fi
  printf '%s\n' "$out"
}

# =============================================================================
# RELAY + TUNNEL LIFECYCLE
# =============================================================================
_gb_mint_token() { head -c 32 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n'; }
_gb_pid_alive()  { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

_gb_relay_pid()  { [ -f "$GB_STATE" ] && jq -r '.pid_relay // empty' "$GB_STATE" 2>/dev/null; }
_gb_tunnel_pid() { [ -f "$GB_STATE" ] && jq -r '.pid_tunnel // empty' "$GB_STATE" 2>/dev/null; }
_gb_running()    { local p; p="$(_gb_relay_pid)"; _gb_pid_alive "$p"; }

gb_start() {
  if gb_killed; then _gb_err "GPTBRIDGE_DISABLE=1 — refusing to start."; return 1; fi
  if ! gb_master_on; then _gb_err "gptbridge.enabled=false — set it true in $CONFIG_FILE first."; return 1; fi
  if ! gb_relay_on;  then _gb_err "gptbridge.relay.enabled=false — set it true in $CONFIG_FILE first."; return 1; fi
  command -v node >/dev/null 2>&1 || { _gb_err "node not found — the relay needs Node.js."; return 1; }

  # singleton
  exec 8>"$GB_LOCK"
  if ! flock -n 8; then _gb_err "another gptbridge start is in progress."; return 1; fi
  if _gb_running; then
    _gb_log "relay already running (pid $(_gb_relay_pid))."
    gb_url; return 0
  fi
  gb_register_peer

  local token port; token="$(_gb_mint_token)"; port="$GB_PORT"
  [ -n "$token" ] || { _gb_err "failed to mint token (no /dev/urandom?)."; return 1; }

  # launch relay (loopback only), detached so it survives this shell
  : > "$GB_RELAY_LOG"
  GPTBRIDGE_TOKEN="$token" GPTBRIDGE_PORT="$port" GPTBRIDGE_STATE_DIR="$GB_DIR" \
    CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$GB_CLAUDE_DIR/.." 2>/dev/null && pwd)}" \
    setsid nohup node "$GB_HOOK_DIR/relay.mjs" >>"$GB_RELAY_LOG" 2>&1 &
  local rpid=$!
  sleep 1
  if ! _gb_pid_alive "$rpid"; then
    _gb_err "relay failed to start — see $GB_RELAY_LOG"; tail -5 "$GB_RELAY_LOG" >&2 2>/dev/null; return 1
  fi

  # tunnel
  local url="" tpid=""
  if [ "$GB_EXPOSE" = "quicktunnel" ]; then
    if command -v cloudflared >/dev/null 2>&1; then
      : > "$GB_TUNNEL_LOG"
      setsid nohup cloudflared tunnel --url "http://127.0.0.1:$port" >>"$GB_TUNNEL_LOG" 2>&1 &
      tpid=$!
      # poll the log for the assigned https://<x>.trycloudflare.com host (~up to 20s)
      local base=""
      for _ in $(seq 1 40); do
        base="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$GB_TUNNEL_LOG" 2>/dev/null | head -1)"
        [ -n "$base" ] && break
        _gb_pid_alive "$tpid" || break
        sleep 0.5
      done
      [ -n "$base" ] && url="$base/mcp/$token"
    else
      _gb_err "cloudflared not found — relay is up on 127.0.0.1:$port but NOT exposed. Install cloudflared or set expose=none."
    fi
  fi

  local now expires; now="$(_gb_now)"
  expires="$(date -u -d "+${GB_TTL_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
  ( umask 077
    jq -nc --arg token "$token" --argjson port "$port" --argjson rpid "$rpid" \
       --arg tpid "${tpid:-}" --arg url "$url" --arg base "http://127.0.0.1:$port" \
       --arg started "$now" --arg expires "$expires" --argjson ttl "$GB_TTL_HOURS" \
       '{token:$token, port:$port, pid_relay:$rpid, pid_tunnel:($tpid|select(.!="")|tonumber? // null),
         url:$url, local:$base, started_at:$started, expires_at:$expires, ttl_hours:$ttl}' \
       > "$GB_STATE".tmp 2>/dev/null && mv "$GB_STATE".tmp "$GB_STATE" )
  chmod 600 "$GB_STATE" 2>/dev/null || true

  # TTL auto-stop watcher (detached; stop is idempotent)
  if [ "$GB_TTL_HOURS" -gt 0 ] 2>/dev/null; then
    setsid nohup bash -c "sleep $((GB_TTL_HOURS*3600)); '$GB_HOOK_DIR/gptbridge.sh' stop --reason ttl" >/dev/null 2>&1 &
  fi

  echo ""
  echo "  gptbridge relay STARTED (ChatGPT-session consult relay — T2)"
  echo "    local:    http://127.0.0.1:$port   (loopback only)"
  if [ -n "$url" ]; then
    echo "    connector URL (paste into ChatGPT → Settings → Apps → Advanced → Developer mode → Add custom connector, auth: none):"
    echo ""
    echo "        $url"
    echo ""
    echo "    This URL carries a per-start secret token; it ROTATES on every start — re-paste after each restart."
  else
    echo "    (no public URL — tunnel unavailable; see above)"
  fi
  echo "    surface:  exactly two tools — consult_claude (ChatGPT asks you) and check_relay (ChatGPT pulls replies)."
  echo "              ChatGPT gets NO file/tool/exec access. Inbound consults are UNTRUSTED and land quarantined for your approval."
  echo "    expires:  ${expires:-<none>}  (TTL ${GB_TTL_HOURS}h auto-stop; also reaped on SessionEnd)"
  echo "    stop:     /gptbridge stop   (or GPTBRIDGE_DISABLE=1 to refuse mid-flight)"
  [ "$GB_ADVANCED" = "true" ] && echo "    ⚠ advanced_read_tools=true is set, but the read-tools tier is NOT built in this version — the relay stays consult-only."
  echo ""
  return 0
}

gb_stop() {
  local reason=""
  while [ $# -gt 0 ]; do case "$1" in --reason) reason="${2:-}"; shift 2;; *) shift;; esac; done
  local rpid tpid; rpid="$(_gb_relay_pid)"; tpid="$(_gb_tunnel_pid)"
  _gb_pid_alive "$rpid" && { kill "$rpid" 2>/dev/null; sleep 0.3; kill -9 "$rpid" 2>/dev/null; }
  _gb_pid_alive "$tpid" && { kill "$tpid" 2>/dev/null; sleep 0.3; kill -9 "$tpid" 2>/dev/null; }
  rm -f "$GB_STATE" 2>/dev/null || true
  echo "gptbridge relay stopped${reason:+ ($reason)}. Token invalidated; the connector URL is now dead (404)."
  return 0
}

gb_status() {
  if [ ! -f "$GB_STATE" ] || ! _gb_running; then
    echo "gptbridge relay: STOPPED"
    gb_enabled && echo "  (enabled in config — start with: /gptbridge start)" || echo "  (disabled: gptbridge.enabled/relay.enabled OFF, or GPTBRIDGE_DISABLE=1)"
    return 0
  fi
  local started expires port url tpid; started="$(jq -r '.started_at//""' "$GB_STATE")"
  expires="$(jq -r '.expires_at//""' "$GB_STATE")"; port="$(jq -r '.port//""' "$GB_STATE")"
  url="$(jq -r '.url//""' "$GB_STATE")"; tpid="$(jq -r '.pid_tunnel//empty' "$GB_STATE")"
  echo "gptbridge relay: RUNNING (pid $(_gb_relay_pid), port $port)"
  echo "  started: $started    expires: ${expires:-<none>}"
  echo "  tunnel:  $([ -n "$tpid" ] && _gb_pid_alive "$tpid" && echo up || echo down)   exposed: $([ -n "$url" ] && echo yes || echo no)"
  # mask the token in status output (it may be logged); use /gptbridge url for the full URL
  if [ -n "$url" ]; then echo "  connector URL: $(printf '%s' "$url" | sed -E 's#(/mcp/)[0-9a-f]{6}[0-9a-f]+#\1******#')  (full URL: /gptbridge url)"; fi
  local pend; pend="$(gb_pending | jq 'length' 2>/dev/null || echo 0)"
  echo "  pending inbound consults awaiting your reply: $pend"
  return 0
}

gb_url() {
  if [ ! -f "$GB_STATE" ] || ! _gb_running; then _gb_err "relay not running."; return 1; fi
  local url; url="$(jq -r '.url//""' "$GB_STATE" 2>/dev/null)"
  if [ -n "$url" ]; then echo "$url"; else
    echo "http://127.0.0.1:$(jq -r '.port//""' "$GB_STATE")/mcp/$(jq -r '.token//""' "$GB_STATE")"
    _gb_err "(no public tunnel — this is the loopback URL only)"
  fi
  return 0
}

gb_reap_session() {
  [ "$GB_STOP_WITH_SESSION" = "true" ] || return 0
  _gb_running || return 0
  gb_stop --reason session-end >/dev/null 2>&1 || true
  return 0
}

gb_preflight() {
  echo "gptbridge T2 relay preflight:"
  echo "  enabled:      master=$(gb_master_on && echo yes || echo no)  relay=$(gb_relay_on && echo yes || echo no)  killed=$(gb_killed && echo yes || echo no)"
  echo "  node:         $(command -v node >/dev/null 2>&1 && echo yes || echo no)"
  echo "  cloudflared:  $(command -v cloudflared >/dev/null 2>&1 && echo yes || echo 'no (needed for the public tunnel; install to expose)')"
  echo "  pseudo-peer:  $GB_BRIDGE_NAME ($(gb_bridge_hex | cut -c1-12)…) status=$(bash "$REGISTRY" status "$(gb_bridge_hex)" 2>/dev/null || echo unregistered)"
  echo "  reply policy: $GB_REPLY_POLICY   sync-wait: ${GB_SYNC_WAIT}s   caps: ${GB_MAX_KB}KB / ${GB_MAX_PER_HR}/h"
}

# =============================================================================
# dispatch
# =============================================================================
cmd="${1:-status}"; shift 2>/dev/null || true
case "$cmd" in
  start)         gb_start "$@";;
  stop)          gb_stop "$@";;
  status)        gb_status "$@";;
  url)           gb_url "$@";;
  ingest)        gb_ingest "$@";;
  reply)         gb_reply "$@";;
  ask)           gb_ask "$@";;
  pending)       gb_pending "$@";;
  reply-get)     gb_reply_get "$@";;
  deliver)       gb_deliver "$@";;
  register-peer) gb_register_peer "$@";;
  reap-session)  gb_reap_session "$@";;
  bridge-hex)    gb_bridge_hex;;
  preflight)     gb_preflight "$@";;
  sync-wait-s)   echo "$GB_SYNC_WAIT";;
  *) _gb_err "usage: gptbridge.sh {start|stop|status|url|ingest|reply|ask|pending|reply-get|deliver|register-peer|reap-session|preflight}"; exit 1;;
esac
exit $?
