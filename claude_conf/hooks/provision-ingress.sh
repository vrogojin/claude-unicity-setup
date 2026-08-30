#!/usr/bin/env bash
# provision-ingress.sh — capability-gated public-ingress provisioner (A2A verb backend).
#
# WHAT IT IS: the deterministic, JSON-in/JSON-out worker behind the `provision-ingress`
# A2A capability. An AUTHORIZED peer (e.g. Mission Control / AMC) asks THIS instance to
# expose a locally-spawned service on a public hostname; THIS side does the Cloudflare
# provisioning under ITS OWN credential + owner consent. The credential NEVER leaves this
# side and is NEVER emitted — the response carries only the 0600 path to the connector
# token, never the token value.
#
# TRUST MODEL (why this is safe to expose over A2A):
#   • The capability `provision-ingress` is DESTRUCTIVE/outward: it is granted by the owner
#     AND owner-confirmed PER provision (rebuild-reload-service class). The A2A processor
#     (/process-agent-requests) calls this script in `--plan` mode ONLY (read-only, no
#     mutation), surfaces the plan to the owner, and STOPS. The owner runs `--apply`.
#   • Hostname is pinned to the allowed zone (INGRESS_ZONE, default concierge-dev.app) — a
#     peer can NEVER provision a name in someone else's zone.
#   • Target is pinned to loopback (127.0.0.1:<port>) — a peer can NEVER point a public
#     hostname at an arbitrary host.
#   • Idempotent: re-requesting an existing hostname returns the existing tunnel, never a
#     duplicate.
#
# CONVENTION (mirrors gptbridge/README.md + gptbridge-tunnel.service): one named cloudflared
# tunnel + one DNS CNAME + one ingress rule per service; connector token persisted 0600 at
# .secrets/ingress/<tunnel>.env; run as a `systemd --user` unit (fallback: supervised run).
#
# KNOWN SCOPE GAP (handled explicitly, never faked): the persisted Cloudflare token
# (.secrets/staging-tls/cloudflare.ini `dns_cloudflare_api_token`) is DNS-only, and there
# is no ~/.cloudflared/cert.pem — so `cloudflared tunnel create` FAILS until a one-time
# owner fix. When that happens we return status:"blocked_scope" with the exact remediation.
# See provision-ingress.README.md.
#
# USAGE:
#   provision-ingress.sh provision   --plan   [--in FILE | --json '<obj>' | -<stdin>]
#   INGRESS_APPLY_CONFIRM=1 provision-ingress.sh provision   --apply  [ ... ]
#   provision-ingress.sh deprovision --plan   [ ... ]
#   INGRESS_APPLY_CONFIRM=1 provision-ingress.sh deprovision --apply  [ ... ]
#   provision-ingress.sh --help
# --apply mutates PUBLIC DNS + a cloud credential, so it is technically gated: it refuses
# (status:"blocked_confirm") unless the OWNER sets INGRESS_APPLY_CONFIRM=1. The /process-
# agent-requests processor runs ONLY --plan and must never set that env.
#
# REQUEST  (stdin/--in/--json): { "hostname", "target":"127.0.0.1:<port>", "purpose", "ttl_hint" }
# RESPONSE (stdout, one JSON object): { "hostname", "connector_token_path", "tunnel_name",
#   "status", ... additive non-secret diagnostics: op, mode, reason, remediation[] }.
#   The token VALUE is never present. All logs go to stderr.
set -uo pipefail

# --- Resolvable knobs -------------------------------------------------------------------
# Precedence for every project-specific bit: ENV override  >  the project's own config
# block  >  built-in default. This is what makes the verb a GENERIC reference impl: AMC's
# OTHER projects supply their own zone + token path (the "direct" mode) by dropping an
# `ingress` block into .claude/agent/config.json — WITHOUT editing this script. The defaults
# target the concierge dev runtime (the "delegated" mode).
#
# Project config block (all keys optional), $PROJECT_DIR/.claude/agent/config.json:
#   { "ingress": { "zone": "...", "cloudflare_ini": "<path>", "token_dir": "<path>",
#                  "tunnel_prefix": "ingress-", "cf_api": "https://api.cloudflare.com/client/v4" } }
# NOTE: only PATHS/NAMES live in config — the account-scoped secret stays env-only
# (CLOUDFLARED_API_TOKEN), never persisted to a project config.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
PROJECT_DIR="${INGRESS_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-/home/vrogojin/concierge}}"
INGRESS_CONFIG_FILE="${INGRESS_CONFIG_FILE:-$PROJECT_DIR/.claude/agent/config.json}"

# _cfg <jq-path> : value from the project's .ingress config block, or empty.
_cfg() {
  [ -f "$INGRESS_CONFIG_FILE" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r "$1 // empty" "$INGRESS_CONFIG_FILE" 2>/dev/null
}
# _pick <env-value> <config-jq-path> <default> : ENV > project config > default.
_pick() { if [ -n "$1" ]; then printf '%s' "$1"; else local c; c="$(_cfg "$2")"; printf '%s' "${c:-$3}"; fi; }

INGRESS_ZONE="$(_pick "${INGRESS_ZONE:-}" '.ingress.zone' 'concierge-dev.app')"
SECRETS_DIR="${INGRESS_SECRETS_DIR:-$PROJECT_DIR/.secrets}"
INGRESS_DIR="$(_pick "${INGRESS_TOKEN_DIR:-}" '.ingress.token_dir' "$SECRETS_DIR/ingress")"
CF_INI="$(_pick "${INGRESS_CF_INI:-}" '.ingress.cloudflare_ini' "$SECRETS_DIR/staging-tls/cloudflare.ini")"
INGRESS_TUNNEL_PREFIX="$(_pick "${INGRESS_TUNNEL_PREFIX:-}" '.ingress.tunnel_prefix' 'ingress-')"
CF_API="$(_pick "${INGRESS_CF_API:-}" '.ingress.cf_api' 'https://api.cloudflare.com/client/v4')"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-cloudflared}"
# Tunnel lifecycle backend: "auto" (cert.pem→cli, else account-token→api) | "cli" | "api"
INGRESS_TUNNEL_MODE="${INGRESS_TUNNEL_MODE:-auto}"
# DNS backend: "api" (Cloudflare API w/ dns token) | "cli" (cloudflared route dns) | "skip" (tests)
INGRESS_DNS_MODE="${INGRESS_DNS_MODE:-api}"
# Service supervisor: "systemd" (systemd --user) | "none" (skip start; tests / headless)
INGRESS_SUPERVISOR="${INGRESS_SUPERVISOR:-systemd}"

_ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
_log() { printf '%s [provision-ingress] %s\n' "$(_ts)" "$*" >&2; }
_have() { command -v "$1" >/dev/null 2>&1; }

# --- JSON emit: single object to stdout, then exit. Token value is never a field. --------
# _emit <status> <reason> [remediation-json-array]
_emit() {
  local status="$1" reason="${2:-}" remediation="${3:-[]}"
  jq -cn \
    --arg hostname "${HOSTNAME_REQ:-}" \
    --arg token_path "${CONNECTOR_TOKEN_PATH:-}" \
    --arg tunnel "${TUNNEL_NAME:-}" \
    --arg status "$status" \
    --arg op "${OP:-}" \
    --arg mode "${MODE:-}" \
    --arg reason "$reason" \
    --argjson remediation "$remediation" \
    '{hostname:$hostname, connector_token_path:$token_path, tunnel_name:$tunnel,
      status:$status, op:$op, mode:$mode, reason:$reason, remediation:$remediation}'
}

# The exact one-time owner fixes for the tunnel-create scope gap (machine-readable).
_remediation_scope() {
  jq -cn '[
    "OPTION A (extend the API token): in the Cloudflare dashboard add permission '\''Account > Cloudflare Tunnel > Edit'\'' to the token stored at '"$CF_INI"' (key dns_cloudflare_api_token), then re-run --apply. cloudflared will use it via CLOUDFLARED_API_TOKEN.",
    "OPTION B (interactive login, persists a cert): run '\''cloudflared tunnel login'\'' once as the service user to write ~/.cloudflared/cert.pem, then re-run --apply."
  ]'
}

# --- Input parse -------------------------------------------------------------------------
OP=""; MODE=""; REQ_JSON=""; IN_FILE=""; INLINE=""
_read_args() {
  OP="${1:-}"; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --plan)  MODE="plan";;
      --apply) MODE="apply";;
      --in)    IN_FILE="${2:-}"; shift;;
      --json)  INLINE="${2:-}"; shift;;
      -)       IN_FILE="/dev/stdin";;
      -h|--help) return 2;;
      *) _log "unknown arg: $1";;
    esac
    shift
  done
}

_load_request() {
  if [ -n "$INLINE" ]; then REQ_JSON="$INLINE"
  elif [ -n "$IN_FILE" ]; then REQ_JSON="$(cat "$IN_FILE" 2>/dev/null)"
  elif [ ! -t 0 ]; then REQ_JSON="$(cat 2>/dev/null)"
  fi
  [ -n "$REQ_JSON" ] || return 1
  printf '%s' "$REQ_JSON" | jq -e . >/dev/null 2>&1 || return 1
}

# --- Derive + validate the target from the request --------------------------------------
HOSTNAME_REQ=""; TARGET=""; PURPOSE=""; TTL_HINT=""; TARGET_PORT=""
TUNNEL_NAME=""; CONNECTOR_TOKEN_PATH=""
_derive() {
  HOSTNAME_REQ="$(printf '%s' "$REQ_JSON" | jq -r '.hostname // ""')"
  TARGET="$(printf '%s' "$REQ_JSON" | jq -r '.target // ""')"
  PURPOSE="$(printf '%s' "$REQ_JSON" | jq -r '.purpose // ""')"
  TTL_HINT="$(printf '%s' "$REQ_JSON" | jq -r '.ttl_hint // ""')"

  # hostname: RFC1123-ish labels AND must be within the allowed zone (anti zone-escape).
  case "$HOSTNAME_REQ" in
    *[!a-zA-Z0-9.-]* | "" | .* | *. ) return 10;;
  esac
  case "$HOSTNAME_REQ" in
    *".$INGRESS_ZONE") : ;;                       # foo.concierge-dev.app  ✔
    "$INGRESS_ZONE")   return 11;;                # the bare zone apex is not provisionable
    *) return 11;;                                # any other zone -> reject
  esac

  # target: loopback host:port ONLY (anti open-proxy). Accept 127.0.0.1 or localhost.
  local thost tport
  thost="${TARGET%%:*}"; tport="${TARGET##*:}"
  case "$thost" in 127.0.0.1|localhost) : ;; *) return 12;; esac
  case "$tport" in ''|*[!0-9]*) return 13;; esac
  [ "$tport" -ge 1 ] && [ "$tport" -le 65535 ] || return 13
  TARGET_PORT="$tport"

  # Deterministic tunnel name from the leading label → idempotency anchor.
  local label sane
  label="${HOSTNAME_REQ%%.*}"
  sane="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//')"
  [ -n "$sane" ] || return 10
  TUNNEL_NAME="${INGRESS_TUNNEL_PREFIX}$sane"
  CONNECTOR_TOKEN_PATH="$INGRESS_DIR/$TUNNEL_NAME.env"
  return 0
}

_validate_or_die() {
  local rc="$1"
  case "$rc" in
    10) _emit invalid "hostname is empty or not a valid DNS name"; exit 0;;
    11) _emit invalid "hostname must be a subdomain of the allowed zone '$INGRESS_ZONE'"; exit 0;;
    12) _emit invalid "target host must be loopback (127.0.0.1 or localhost); got '${TARGET%%:*}'"; exit 0;;
    13) _emit invalid "target port must be an integer 1-65535; got '${TARGET##*:}'"; exit 0;;
  esac
}

# --- Cloudflare helpers ------------------------------------------------------------------
# Two lifecycle backends, auto-selected (INGRESS_TUNNEL_MODE=auto|cli|api):
#   • cli — `cloudflared tunnel …`, authenticated by ~/.cloudflared/cert.pem  (owner fix B)
#   • api — Cloudflare API /cfd_tunnel with an account-scoped token           (owner fix A)
# Auto picks cli when cert.pem exists, else api when an account token is set, else BLOCKED.
_cf()   { "$CLOUDFLARED_BIN" "$@"; }                  # cloudflared wrapper (stub-able)
_curl() { "${INGRESS_CURL:-curl}" "$@"; }            # curl wrapper (stub-able)

# The account-scoped token for the API path (owner fix A). Distinct from the DNS-only token.
_cf_acct_token() { [ -n "${CLOUDFLARED_API_TOKEN:-}" ] && printf '%s' "$CLOUDFLARED_API_TOKEN"; }

TUNNEL_UUID=""                                        # populated by create / lookup
_tunnel_mode() {
  case "$INGRESS_TUNNEL_MODE" in
    cli|api) printf '%s' "$INGRESS_TUNNEL_MODE"; return 0;;
  esac
  if [ -f "$HOME/.cloudflared/cert.pem" ]; then printf 'cli'; return 0; fi
  if [ -n "$(_cf_acct_token)" ]; then printf 'api'; return 0; fi
  return 1   # scope gap: neither a cert nor an account token
}

# Read the DNS-only API token from cloudflare.ini (never echoed).
_cf_dns_token() {
  [ -f "$CF_INI" ] || return 1
  local t; t="$(sed -n 's/^[[:space:]]*dns_cloudflare_api_token[[:space:]]*[:=][[:space:]]*//p' "$CF_INI" | head -1)"
  [ -n "$t" ] || return 1
  printf '%s' "$t"
}

# Resolve the zone id for INGRESS_ZONE via the API (read-only, DNS token).
_cf_zone_id() {
  local tok; tok="$(_cf_dns_token)" || return 1
  _curl -fsS -H "Authorization: Bearer $tok" \
    "$CF_API/zones?name=$INGRESS_ZONE&status=active" 2>/dev/null \
    | jq -r '.result[0].id // empty'
}

# Cloudflare account id for the API path (from the account-scoped token).
_cf_acct_id() {
  local tok; tok="$(_cf_acct_token)" || return 1
  _curl -fsS -H "Authorization: Bearer $tok" "$CF_API/accounts?per_page=1" 2>/dev/null \
    | jq -r '.result[0].id // empty'
}

# Does the named tunnel already exist? Sets TUNNEL_UUID as a side effect. (read-only)
_tunnel_exists() {
  local mode; mode="$(_tunnel_mode)" || return 1
  if [ "$mode" = api ]; then
    local tok acct id
    tok="$(_cf_acct_token)" || return 1
    acct="$(_cf_acct_id)"; [ -n "$acct" ] || return 1
    id="$(_curl -fsS -H "Authorization: Bearer $tok" \
      "$CF_API/accounts/$acct/cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false" 2>/dev/null \
      | jq -r '.result[0].id // empty')"
    [ -n "$id" ] || return 1
    TUNNEL_UUID="$id"; return 0
  fi
  local out
  out="$(_cf tunnel list --name "$TUNNEL_NAME" --output json 2>/dev/null)"
  printf '%s' "$out" | jq -e --arg n "$TUNNEL_NAME" 'any(.[]?; .name==$n)' >/dev/null 2>&1 || return 1
  TUNNEL_UUID="$(printf '%s' "$out" | jq -r '.[0].id // empty')"
  return 0
}

# Preflight: is any create path available? 0 = yes, 1 = the known scope gap.
_can_create_tunnel() { _tunnel_mode >/dev/null 2>&1; }

# ========================================================================================
# PLAN — read-only. No mutation. This is what /process-agent-requests shows the owner.
# ========================================================================================
_plan_provision() {
  if _tunnel_exists 2>/dev/null && [ -f "$CONNECTOR_TOKEN_PATH" ]; then
    _emit exists "tunnel '$TUNNEL_NAME' + token already present; provision would be a no-op (idempotent)"
    return
  fi
  if ! _have "$CLOUDFLARED_BIN" && ! _cf --version >/dev/null 2>&1; then
    _emit blocked_scope "cloudflared binary not found (CLOUDFLARED_BIN=$CLOUDFLARED_BIN)" \
      "$(jq -cn '["Install cloudflared and re-run, or set CLOUDFLARED_BIN to its path."]')"
    return
  fi
  if ! _can_create_tunnel; then
    _emit blocked_scope \
      "cannot create a cloudflared tunnel: no ~/.cloudflared/cert.pem and no CLOUDFLARED_API_TOKEN. The persisted token at $CF_INI is DNS-only. Owner must do a one-time fix (below); then --apply will provision '$HOSTNAME_REQ' -> http://$TARGET on tunnel '$TUNNEL_NAME'." \
      "$(_remediation_scope)"
    return
  fi
  _emit planned "would create tunnel '$TUNNEL_NAME', persist connector token 0600 at $CONNECTOR_TOKEN_PATH, add CNAME $HOSTNAME_REQ -> <tunnel>.cfargotunnel.com in zone $INGRESS_ZONE, ingress -> http://$TARGET, and start it via $INGRESS_SUPERVISOR"
}

_plan_deprovision() {
  if ! _tunnel_exists 2>/dev/null && [ ! -f "$CONNECTOR_TOKEN_PATH" ]; then
    _emit not_found "no tunnel '$TUNNEL_NAME' and no token file; nothing to deprovision (idempotent)"
    return
  fi
  _emit planned "would stop + delete tunnel '$TUNNEL_NAME', remove CNAME $HOSTNAME_REQ from zone $INGRESS_ZONE, and delete token file $CONNECTOR_TOKEN_PATH"
}

# ========================================================================================
# APPLY — mutating. Only the owner runs this (after confirming the plan).
# ========================================================================================
_apply_provision() {
  mkdir -p "$INGRESS_DIR" 2>/dev/null || true
  chmod 700 "$INGRESS_DIR" 2>/dev/null || true

  # Idempotent short-circuit.
  if _tunnel_exists 2>/dev/null && [ -f "$CONNECTOR_TOKEN_PATH" ]; then
    _emit exists "tunnel '$TUNNEL_NAME' already provisioned; returning existing token path (no change)"
    return
  fi

  # 1) Create the named tunnel — the KNOWN scope gap lives here.
  local mode
  if ! mode="$(_tunnel_mode)"; then
    _emit blocked_scope \
      "tunnel-create requires a credential this instance does not hold (no ~/.cloudflared/cert.pem and no account-scoped CLOUDFLARED_API_TOKEN; the token at $CF_INI is DNS-only). NOT provisioned. Owner: apply one of the one-time fixes below, then re-run --apply." \
      "$(_remediation_scope)"
    return
  fi

  local token=""
  if [ "$mode" = api ]; then
    # --- API path (owner fix A): POST /cfd_tunnel returns id + connector token ------------
    local tok acct create_json id
    tok="$(_cf_acct_token)"; acct="$(_cf_acct_id)"
    if [ -z "$acct" ]; then
      _emit blocked_scope "the account-scoped token could not resolve a Cloudflare account (needs Account:Read + Cloudflare Tunnel:Edit). NOT provisioned." "$(_remediation_scope)"; return
    fi
    create_json="$(_curl -fsS -X POST -H "Authorization: Bearer $tok" -H "Content-Type: application/json" \
      "$CF_API/accounts/$acct/cfd_tunnel" \
      --data "$(jq -cn --arg n "$TUNNEL_NAME" '{name:$n, config_src:"cloudflare"}')" 2>&1)"
    id="$(printf '%s' "$create_json" | jq -r '.result.id // empty' 2>/dev/null)"
    if [ -z "$id" ]; then
      # Already exists? adopt it. Else classify auth failure honestly.
      if _tunnel_exists 2>/dev/null; then id="$TUNNEL_UUID"; else
        case "$create_json" in
          *[Ff]orbidden*|*403*|*[Aa]uthentic*|*9109*|*"not authorized"*)
            _emit blocked_scope "Cloudflare API rejected tunnel create (token lacks Cloudflare Tunnel:Edit). NOT provisioned. Owner fix below." "$(_remediation_scope)";;
          *) _emit error "Cloudflare API tunnel create failed: $(printf '%s' "$create_json" | tr '\n' ' ' | cut -c1-240)";;
        esac
        return
      fi
    fi
    TUNNEL_UUID="$id"
    token="$(printf '%s' "$create_json" | jq -r '.result.token // empty' 2>/dev/null)"
    [ -n "$token" ] || token="$(_curl -fsS -H "Authorization: Bearer $tok" \
      "$CF_API/accounts/$acct/cfd_tunnel/$id/token" 2>/dev/null | jq -r '. // empty')"
  else
    # --- CLI path (owner fix B): cloudflared uses ~/.cloudflared/cert.pem -----------------
    local create_out create_rc
    create_out="$(_cf tunnel create "$TUNNEL_NAME" 2>&1)"; create_rc=$?
    if [ $create_rc -ne 0 ]; then
      case "$create_out" in
        *already\ exists*) : ;;  # adopt existing
        *[Aa]uth*|*cert.pem*|*credential*|*[Ff]orbidden*|*403*|*login*)
          _emit blocked_scope "cloudflared tunnel create failed on authorization (scope gap). NOT provisioned. Owner fix below, then re-run --apply." "$(_remediation_scope)"; return;;
        *) _emit error "cloudflared tunnel create failed: $(printf '%s' "$create_out" | tr '\n' ' ' | cut -c1-240)"; return;;
      esac
    fi
    _tunnel_exists 2>/dev/null || true          # refresh TUNNEL_UUID
    token="$(_cf tunnel token "$TUNNEL_NAME" 2>/dev/null)"
  fi

  # 2) Persist the connector token 0600 (VALUE never emitted). The write is CHECKED — a
  # silent failure must never be reported as ok.
  if [ -z "$token" ]; then
    _rollback_provision "$mode"
    _emit error "tunnel '$TUNNEL_NAME' created but its connector token could not be read; rolled back"
    return
  fi
  if ! ( umask 077; printf 'TUNNEL_TOKEN=%s\n' "$token" > "$CONNECTOR_TOKEN_PATH" ) \
     || [ ! -s "$CONNECTOR_TOKEN_PATH" ]; then
    unset token; _rollback_provision "$mode"
    _emit error "could not persist the connector token to $CONNECTOR_TOKEN_PATH; rolled back"
    return
  fi
  chmod 600 "$CONNECTOR_TOKEN_PATH" 2>/dev/null || true
  unset token

  # 3) Configure the tunnel's INGRESS rule (hostname -> http://target). Without this the
  # edge has no route and traffic 404s — so a failure here is fatal, never "ok".
  if ! _configure_ingress "$mode"; then
    _rollback_provision "$mode"
    _emit error "tunnel + token created but the ingress rule for $HOSTNAME_REQ could not be configured; rolled back"
    return
  fi

  # 4) DNS CNAME → <tunnel-uuid>.cfargotunnel.com (works with the DNS-only token).
  if ! _dns_upsert; then
    _rollback_provision "$mode"
    _emit error "tunnel + ingress configured but the DNS CNAME for $HOSTNAME_REQ could not be created; rolled back"
    return
  fi

  # 5) Start the connector (systemd --user unit, or skip when INGRESS_SUPERVISOR=none).
  _start_service "$mode" || _log "service start reported a problem (tunnel + ingress + DNS are in place)"

  _emit ok "provisioned $HOSTNAME_REQ -> http://$TARGET via tunnel '$TUNNEL_NAME'"
}

# Best-effort teardown of a half-built provision so a failed --apply never orphans a tunnel
# or leaves a stale token/config on disk. Never emits — the caller emits the outcome.
_rollback_provision() {  # <mode>
  local mode="${1:-cli}"
  _log "rolling back partial provision of '$TUNNEL_NAME'"
  if _tunnel_exists 2>/dev/null; then
    if [ "$mode" = api ]; then
      local tok acct; tok="$(_cf_acct_token)"; acct="$(_cf_acct_id)"
      [ -n "$acct" ] && _curl -fsS -X DELETE -H "Authorization: Bearer $tok" \
        "$CF_API/accounts/$acct/cfd_tunnel/$TUNNEL_UUID" >/dev/null 2>&1 || true
    else
      _cf tunnel delete -f "$TUNNEL_NAME" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$CONNECTOR_TOKEN_PATH" "$INGRESS_DIR/$TUNNEL_NAME.config.yml" 2>/dev/null || true
}

_apply_deprovision() {
  local existed=0 problem=0 del_out del_rc
  # Did any real resource exist BEFORE we touch anything? (DNS is best-effort/idempotent
  # and must NOT by itself count as "something existed".)
  if _tunnel_exists 2>/dev/null || [ -f "$CONNECTOR_TOKEN_PATH" ]; then existed=1; fi

  # 1) Delete the DNS CNAME (best-effort; the DNS-only token can do this).
  _dns_delete || { problem=1; _log "DNS CNAME delete reported a problem"; }

  # 2) Stop + delete the tunnel (mode-aware).
  _stop_service || true
  if _tunnel_exists 2>/dev/null; then
    local mode; mode="$(_tunnel_mode 2>/dev/null || echo cli)"
    if [ "$mode" = api ]; then
      local tok acct
      tok="$(_cf_acct_token)"; acct="$(_cf_acct_id)"
      del_out="$(_curl -fsS -X DELETE -H "Authorization: Bearer $tok" \
        "$CF_API/accounts/$acct/cfd_tunnel/$TUNNEL_UUID" 2>&1)"; del_rc=$?
    else
      del_out="$(_cf tunnel delete -f "$TUNNEL_NAME" 2>&1)"; del_rc=$?
    fi
    if [ $del_rc -ne 0 ]; then
      case "$del_out" in
        *[Aa]uth*|*cert.pem*|*credential*|*[Ff]orbidden*|*403*)
          _emit blocked_scope "DNS + token removed, but tunnel delete needs account scope. Owner fix below." "$(_remediation_scope)"; return;;
        *) problem=1; _log "tunnel delete: $del_out";;
      esac
    fi
  fi

  # 3) Remove the token file + any local ingress config.
  [ -f "$CONNECTOR_TOKEN_PATH" ] && rm -f "$CONNECTOR_TOKEN_PATH"
  rm -f "$INGRESS_DIR/$TUNNEL_NAME.config.yml" 2>/dev/null || true

  if [ "$existed" = 0 ]; then _emit not_found "nothing to deprovision for '$TUNNEL_NAME'"
  elif [ "$problem" = 1 ]; then _emit partial "deprovisioned '$TUNNEL_NAME' with one or more non-fatal warnings (see logs)"
  else _emit ok "deprovisioned '$TUNNEL_NAME' (tunnel + CNAME + token removed)"; fi
}

# --- DNS CNAME upsert/delete via the Cloudflare API (dns_cloudflare_api_token) -----------
_dns_upsert() {
  case "$INGRESS_DNS_MODE" in
    skip) _log "INGRESS_DNS_MODE=skip — DNS upsert skipped"; return 0;;
    cli)  _cf tunnel route dns "$TUNNEL_NAME" "$HOSTNAME_REQ" >/dev/null 2>&1; return $?;;
  esac
  local tok zid uuid target rid
  tok="$(_cf_dns_token)" || { _log "no DNS token"; return 1; }
  zid="$(_cf_zone_id)"   || { _log "no zone id"; return 1; }
  [ -n "$zid" ] || return 1
  uuid="${TUNNEL_UUID:-}"
  [ -n "$uuid" ] || { _tunnel_exists 2>/dev/null && uuid="$TUNNEL_UUID"; }
  [ -n "$uuid" ] || { _log "no tunnel uuid"; return 1; }
  target="$uuid.cfargotunnel.com"
  # Upsert: reuse an existing record id if present (idempotent), else create.
  rid="$(_curl -fsS -H "Authorization: Bearer $tok" \
      "$CF_API/zones/$zid/dns_records?type=CNAME&name=$HOSTNAME_REQ" 2>/dev/null \
      | jq -r '.result[0].id // empty')"
  local body; body="$(jq -cn --arg n "$HOSTNAME_REQ" --arg c "$target" \
      '{type:"CNAME",name:$n,content:$c,proxied:true,ttl:1}')"
  if [ -n "$rid" ]; then
    _curl -fsS -X PUT -H "Authorization: Bearer $tok" -H "Content-Type: application/json" \
      "$CF_API/zones/$zid/dns_records/$rid" --data "$body" >/dev/null 2>&1
  else
    _curl -fsS -X POST -H "Authorization: Bearer $tok" -H "Content-Type: application/json" \
      "$CF_API/zones/$zid/dns_records" --data "$body" >/dev/null 2>&1
  fi
}

_dns_delete() {
  case "$INGRESS_DNS_MODE" in skip) return 0;; cli) return 0;; esac
  local tok zid rid
  tok="$(_cf_dns_token)" || return 1
  zid="$(_cf_zone_id)"   || return 1
  [ -n "$zid" ] || return 1
  rid="$(_curl -fsS -H "Authorization: Bearer $tok" \
      "$CF_API/zones/$zid/dns_records?type=CNAME&name=$HOSTNAME_REQ" 2>/dev/null \
      | jq -r '.result[0].id // empty')"
  [ -n "$rid" ] || return 0   # already gone → success
  _curl -fsS -X DELETE -H "Authorization: Bearer $tok" \
    "$CF_API/zones/$zid/dns_records/$rid" >/dev/null 2>&1
}

# --- Ingress-rule configuration (maps the public hostname to http://<target>) ------------
# api: the tunnel is remotely-managed (config_src:cloudflare) → PUT its configuration so the
#      edge routes <hostname> → http://<target>. cloudflared then pulls it at token-run.
# cli: the tunnel is locally-managed → write a config.yml (ingress + credentials-file) that
#      the connector runs with (`--config`). Either way, WITHOUT this step traffic 404s.
_ingress_config_yml() { printf '%s' "$INGRESS_DIR/$TUNNEL_NAME.config.yml"; }
_configure_ingress() {  # <mode>
  local mode="${1:-cli}"
  if [ "$mode" = api ]; then
    case "$INGRESS_DNS_MODE" in skip) _log "DNS_MODE=skip — ingress config PUT skipped"; return 0;; esac
    local tok acct body
    tok="$(_cf_acct_token)"; acct="$(_cf_acct_id)"
    [ -n "$acct" ] && [ -n "$TUNNEL_UUID" ] || { _log "ingress config: no account id / tunnel uuid"; return 1; }
    body="$(jq -cn --arg h "$HOSTNAME_REQ" --arg s "http://$TARGET" \
      '{config:{ingress:[{hostname:$h,service:$s},{service:"http_status:404"}]}}')"
    _curl -fsS -X PUT -H "Authorization: Bearer $tok" -H "Content-Type: application/json" \
      "$CF_API/accounts/$acct/cfd_tunnel/$TUNNEL_UUID/configurations" --data "$body" >/dev/null 2>&1
    return $?
  fi
  # cli path: a locally-managed tunnel is run from a config.yml with its credentials file.
  local yml cred; yml="$(_ingress_config_yml)"; cred="$HOME/.cloudflared/$TUNNEL_UUID.json"
  ( umask 077; cat > "$yml" <<YML
tunnel: $TUNNEL_UUID
credentials-file: $cred
ingress:
  - hostname: $HOSTNAME_REQ
    service: http://$TARGET
  - service: http_status:404
YML
  ) || { _log "ingress config: could not write $yml"; return 1; }
  [ -s "$yml" ]
}

# --- Service supervision (systemd --user unit; matches gptbridge-tunnel.service) ---------
_unit_name() { printf '%s.service' "$TUNNEL_NAME"; }
_start_service() {  # <mode>
  local mode="${1:-cli}"
  [ "$INGRESS_SUPERVISOR" = "systemd" ] || { _log "supervisor=$INGRESS_SUPERVISOR — start skipped"; return 0; }
  _have systemctl || { _log "no systemctl — start skipped"; return 0; }
  local unit_dir="$HOME/.config/systemd/user"
  mkdir -p "$unit_dir" 2>/dev/null || true
  local cfbin; cfbin="$(command -v "$CLOUDFLARED_BIN" 2>/dev/null || printf '%s' "$CLOUDFLARED_BIN")"
  # api → token-run (config pulled from the edge); cli → run the local config.yml.
  local envline execline
  if [ "$mode" = api ]; then
    envline="EnvironmentFile=$CONNECTOR_TOKEN_PATH"
    execline="ExecStart=$cfbin tunnel --no-autoupdate run"
  else
    envline="# (cli mode: credentials + ingress come from the config file)"
    execline="ExecStart=$cfbin tunnel --no-autoupdate --config $(_ingress_config_yml) run $TUNNEL_NAME"
  fi
  cat > "$unit_dir/$(_unit_name)" <<UNIT
[Unit]
Description=ingress tunnel $TUNNEL_NAME ($HOSTNAME_REQ -> http://$TARGET)
After=network.target

[Service]
Type=simple
$envline
$execline
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now "$(_unit_name)" 2>/dev/null
}
_stop_service() {
  [ "$INGRESS_SUPERVISOR" = "systemd" ] || return 0
  _have systemctl || return 0
  systemctl --user disable --now "$(_unit_name)" 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/$(_unit_name)" 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
}

# --- Help --------------------------------------------------------------------------------
_usage() {
  sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- Main --------------------------------------------------------------------------------
main() {
  if ! _have jq; then _log "jq is required"; exit 1; fi
  _read_args "$@"; local ra=$?
  if [ "$ra" = 2 ] || [ "$OP" = "--help" ] || [ "$OP" = "-h" ]; then _usage; exit 0; fi
  case "$OP" in provision|deprovision) : ;; *) _log "op must be provision|deprovision"; _usage; exit 1;; esac
  case "$MODE" in plan|apply) : ;; *) _log "mode must be --plan|--apply"; exit 1;; esac

  if ! _load_request; then _emit invalid "request must be a JSON object on stdin/--in/--json"; exit 0; fi
  _derive; _validate_or_die $?

  # OWNER-CONFIRMATION GATE (defense-in-depth). --apply mutates PUBLIC DNS + a cloud
  # credential, so it refuses unless the owner explicitly sets INGRESS_APPLY_CONFIRM=1.
  # The capability-scoped /process-agent-requests processor runs ONLY --plan and must NOT
  # set this; copying the plan command verbatim therefore yields a safe refusal, not a
  # provision. (A determined injected agent with shell access is out of scope for a single
  # env var — the registry grant + this gate + the permission system are the layered
  # controls; this converts the common accidental/auto path into a hard stop.)
  if [ "$MODE" = apply ] && [ "${INGRESS_APPLY_CONFIRM:-}" != "1" ]; then
    _emit blocked_confirm "refusing to --apply without owner confirmation: this mutates public DNS. The OWNER re-runs with INGRESS_APPLY_CONFIRM=1 after reviewing the --plan. The capability-scoped processor must NOT set this."
    exit 0
  fi

  case "$OP:$MODE" in
    provision:plan)    _plan_provision;;
    provision:apply)   _apply_provision;;
    deprovision:plan)  _plan_deprovision;;
    deprovision:apply) _apply_deprovision;;
  esac
}
main "$@"
