#!/usr/bin/env bash
# provision-ingress.sh — capability-gated public-ingress provisioner (A2A verb backend).
#
# WHAT IT IS: the deterministic, JSON-in/JSON-out worker behind the `provision-ingress`
# A2A capability. An AUTHORIZED peer (e.g. Mission Control / AMC) asks THIS instance to
# expose a locally-spawned service on a public hostname; THIS side does the ingress
# provisioning under ITS OWN infra + owner consent.
#
# TWO PLUGGABLE MODES (INGRESS_MODE, default "haproxy"):
#   • haproxy (PRIMARY) — register the hostname with a SHARED haproxy domain-multiplexer's
#     Registration API (POST http://<HAPROXY_HOST>:8404/v1/backends). Public reach already
#     comes from a WILDCARD DNS record (*.staging.<zone> → the host IP) → haproxy → the
#     target CONTAINER on haproxy-net. NO Cloudflare, NO tunnel, NO credential/secret.
#     This is the common case for any project with a shared reverse proxy.
#   • tunnel (FALLBACK) — for projects with NO shared haproxy: create a Cloudflare named
#     tunnel + DNS CNAME + 0600 connector token under this side's own Cloudflare credential.
#     The credential never leaves this side and is never emitted (only the token's 0600 path).
#
# TRUST MODEL (why this is safe to expose over A2A):
#   • `provision-ingress` is DESTRUCTIVE/outward: owner-GRANTED in the registry AND
#     owner-CONFIRMED per op (rebuild-reload-service class). /process-agent-requests runs
#     ONLY `--plan` (read-only) and STOPS; the owner runs `--apply`, which additionally
#     refuses unless INGRESS_APPLY_CONFIRM=1. The verb is INERT until BOTH gates pass.
#   • Zone-pin: hostname must be a subdomain of the allowed zone — no zone-escape.
#   • Target-pin (mode-specific): haproxy → a CONTAINER name:port (NOT loopback — haproxy
#     cannot reach the host's 127.0.0.1); tunnel → 127.0.0.1:<port> ONLY (anti open-proxy).
#   • Idempotent: re-provisioning an existing hostname returns it, never a duplicate.
#
# USAGE:
#   provision-ingress.sh provision   --plan   [--in FILE | --json '<obj>' | -<stdin>]
#   INGRESS_APPLY_CONFIRM=1 provision-ingress.sh provision   --apply  [ ... ]
#   provision-ingress.sh deprovision --plan   [ ... ]
#   INGRESS_APPLY_CONFIRM=1 provision-ingress.sh deprovision --apply  [ ... ]
#   provision-ingress.sh --help
# --apply mutates public ingress, so it is technically gated: it refuses
# (status:"blocked_confirm") unless the OWNER sets INGRESS_APPLY_CONFIRM=1. The /process-
# agent-requests processor runs ONLY --plan and must never set that env.
#
# REQUEST (haproxy):  { "hostname":"<name>.staging.<zone>", "target":"<container>:<port>",
#                       "https_port":443, "purpose", "ttl_hint" }
# REQUEST (tunnel):   { "hostname":"<name>.<zone>", "target":"127.0.0.1:<port>", "purpose", "ttl_hint" }
# RESPONSE (one JSON object): always {hostname, status, mode, op, phase} plus mode fields —
#   haproxy: {backend}; tunnel: {connector_token_path, tunnel_name} — plus non-secret
#   {reason, remediation[]}. A token/secret VALUE is NEVER emitted. All logs go to stderr.
set -uo pipefail

# --- Resolvable knobs -------------------------------------------------------------------
# Precedence for every project-specific bit: ENV override > the project's own config block
# > built-in default. This keeps the verb a GENERIC reference impl: AMC's OTHER projects
# supply their own mode/zone/haproxy-host (or Cloudflare token path) via an `ingress` block
# in .claude/agent/config.json WITHOUT editing this script.
#
# Project config block (all optional), $PROJECT_DIR/.claude/agent/config.json:
#   { "ingress": {
#       "mode": "haproxy"|"tunnel",
#       "zone": "...",                              // allowed provisioning zone
#       "haproxy_host": "...", "haproxy_api_port": 8404, "haproxy_https_port": 443,
#       "cloudflare_ini": "<path>", "token_dir": "<path>", "tunnel_prefix": "ingress-",
#       "cf_api": "https://api.cloudflare.com/client/v4" } }
# Only PATHS/NAMES live in config — secrets stay env/secret-file only.
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

INGRESS_MODE="$(_pick "${INGRESS_MODE:-}" '.ingress.mode' 'haproxy')"
# Zone default depends on mode: haproxy publishes under the wildcard *.staging.<base>.
_default_zone() { case "$INGRESS_MODE" in haproxy) echo 'staging.concierge-dev.app';; *) echo 'concierge-dev.app';; esac; }
INGRESS_ZONE="$(_pick "${INGRESS_ZONE:-}" '.ingress.zone' "$(_default_zone)")"

# --- haproxy knobs ---
INGRESS_HAPROXY_HOST="$(_pick "${INGRESS_HAPROXY_HOST:-${HAPROXY_HOST:-}}" '.ingress.haproxy_host' '')"
INGRESS_HAPROXY_API_PORT="$(_pick "${INGRESS_HAPROXY_API_PORT:-}" '.ingress.haproxy_api_port' '8404')"
INGRESS_HAPROXY_HTTPS_PORT="$(_pick "${INGRESS_HAPROXY_HTTPS_PORT:-}" '.ingress.haproxy_https_port' '443')"
INGRESS_HAPROXY_NET="$(_pick "${INGRESS_HAPROXY_NET:-}" '.ingress.haproxy_net' 'haproxy-net')"
# Container allowlist enforcement (the PRIMARY SSRF control). DEFAULT is fail-closed:
#   require (default) = enforce membership; if docker is unavailable → blocked_config (never
#                       silently downgrade to blacklist-only).
#   auto              = enforce when docker is available; if not, fall back to the IP-literal
#                       reject AND stamp the result reason "UNVERIFIED (…)" so the downgrade
#                       is visible in the plan the owner reviews. Explicit opt-in.
#   off               = skip the membership check (blacklist only). Explicit opt-in.
INGRESS_VERIFY_CONTAINER="$(_pick "${INGRESS_VERIFY_CONTAINER:-}" '.ingress.verify_container' 'require')"
DOCKER_BIN="${DOCKER_BIN:-docker}"

# --- tunnel (fallback) knobs ---
SECRETS_DIR="${INGRESS_SECRETS_DIR:-$PROJECT_DIR/.secrets}"
INGRESS_DIR="$(_pick "${INGRESS_TOKEN_DIR:-}" '.ingress.token_dir' "$SECRETS_DIR/ingress")"
CF_INI="$(_pick "${INGRESS_CF_INI:-}" '.ingress.cloudflare_ini' "$SECRETS_DIR/staging-tls/cloudflare.ini")"
INGRESS_TUNNEL_PREFIX="$(_pick "${INGRESS_TUNNEL_PREFIX:-}" '.ingress.tunnel_prefix' 'ingress-')"
CF_API="$(_pick "${INGRESS_CF_API:-}" '.ingress.cf_api' 'https://api.cloudflare.com/client/v4')"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-cloudflared}"
INGRESS_TUNNEL_MODE="${INGRESS_TUNNEL_MODE:-auto}"     # cloudflared backend: auto|cli|api
INGRESS_DNS_MODE="${INGRESS_DNS_MODE:-api}"            # api|cli|skip
INGRESS_SUPERVISOR="${INGRESS_SUPERVISOR:-systemd}"    # systemd|none

_ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
_log() { printf '%s [provision-ingress] %s\n' "$(_ts)" "$*" >&2; }
_have() { command -v "$1" >/dev/null 2>&1; }
# curl wrapper (stub-able). ALWAYS bounded — an unreachable HAPROXY_HOST/Cloudflare must
# never hang --plan, which the unattended /process-agent-requests processor runs per request.
_curl() { "${INGRESS_CURL:-curl}" --connect-timeout "${INGRESS_CURL_CONNECT_TIMEOUT:-3}" --max-time "${INGRESS_CURL_MAX_TIME:-8}" "$@"; }
_cf()   { "$CLOUDFLARED_BIN" "$@"; }                  # cloudflared wrapper (stub-able)
_docker() { "$DOCKER_BIN" "$@"; }                    # docker wrapper (stub-able)

# PRIMARY haproxy target allowlist: is <container> a real container ATTACHED to haproxy-net?
# This makes every IP-literal encoding moot — an arbitrary address is not a container on the
# shared proxy network, so it is rejected regardless of spelling. 0 = on-net, 1 = not.
_container_on_haproxy_net() {  # <container>
  local nets; nets="$(_docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}
{{end}}' "$1" 2>/dev/null)" || return 1
  case $'\n'"$nets"$'\n' in *$'\n'"$INGRESS_HAPROXY_NET"$'\n'*) return 0;; esac
  return 1
}

# Set when INGRESS_VERIFY_CONTAINER=auto had to fall back to blacklist-only (docker absent).
INGRESS_UNVERIFIED=""

# --- JSON emit: single object to stdout, then exit. A token/secret value is never a field.
_emit() {  # <status> <reason> [remediation-json-array]
  local status="$1" reason="${2:-}" remediation="${3:-[]}"
  # Make an auto-mode blacklist-fallback VISIBLE on any pass — never a silent downgrade.
  if [ -n "${INGRESS_UNVERIFIED:-}" ]; then
    case "$status" in planned|ok|exists) reason="UNVERIFIED (docker unavailable — container membership NOT checked; IP-blacklist only): $reason";; esac
  fi
  jq -cn \
    --arg hostname "${HOSTNAME_REQ:-}" \
    --arg status "$status" --arg mode "$INGRESS_MODE" \
    --arg op "${OP:-}" --arg phase "${MODE:-}" \
    --arg backend "${BACKEND_DESC:-}" \
    --arg token_path "${CONNECTOR_TOKEN_PATH:-}" \
    --arg tunnel "${TUNNEL_NAME:-}" \
    --arg reason "$reason" --argjson remediation "$remediation" \
    '{hostname:$hostname, status:$status, mode:$mode, op:$op, phase:$phase,
      backend:$backend, connector_token_path:$token_path, tunnel_name:$tunnel,
      reason:$reason, remediation:$remediation}'
}

# The exact one-time owner fixes for the TUNNEL-mode create scope gap (machine-readable).
_remediation_scope() {
  jq -cn '[
    "OPTION A (extend the existing token, ZERO other steps): in the Cloudflare dashboard add permission '\''Account > Cloudflare Tunnel > Edit'\'' to the token stored at '"$CF_INI"' (key dns_cloudflare_api_token). The script auto-reads that token — no export needed — so provisioning just works afterwards.",
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
HOSTNAME_REQ=""; TARGET=""; PURPOSE=""; TTL_HINT=""
TARGET_HOST=""; TARGET_PORT=""; HTTPS_PORT=""
TUNNEL_NAME=""; CONNECTOR_TOKEN_PATH=""; BACKEND_DESC=""
_derive() {
  HOSTNAME_REQ="$(printf '%s' "$REQ_JSON" | jq -r '.hostname // ""')"
  TARGET="$(printf '%s' "$REQ_JSON" | jq -r '.target // ""')"
  PURPOSE="$(printf '%s' "$REQ_JSON" | jq -r '.purpose // ""')"
  TTL_HINT="$(printf '%s' "$REQ_JSON" | jq -r '.ttl_hint // ""')"
  HTTPS_PORT="$(printf '%s' "$REQ_JSON" | jq -r '.https_port // ""')"

  # hostname: RFC1123-ish labels AND must be within the allowed zone (anti zone-escape).
  case "$HOSTNAME_REQ" in
    *[!a-zA-Z0-9.-]* | "" | .* | *. ) return 10;;
  esac
  case "$HOSTNAME_REQ" in
    *".$INGRESS_ZONE") : ;;
    *) return 11;;                                # bare apex or any other zone → reject
  esac

  # target host:port split on first/last colon.
  TARGET_HOST="${TARGET%%:*}"; TARGET_PORT="${TARGET##*:}"
  case "$TARGET_PORT" in ''|*[!0-9]*) return 13;; esac
  [ "$TARGET_PORT" -ge 1 ] && [ "$TARGET_PORT" -le 65535 ] || return 13

  if [ "$INGRESS_MODE" = haproxy ]; then
    # haproxy routes to a CONTAINER on haproxy-net BY NAME. The target must be a real
    # container NAME — never loopback, and never an IP literal / numeric host. Rejecting
    # IPs closes an SSRF/open-proxy hole: without it a peer could point our owned public
    # wildcard hostname at an arbitrary internet IP, the docker bridge gateway
    # (172.17.0.1 → host services), or a cloud metadata endpoint (169.254.169.254).
    case "$TARGET_HOST" in
      127.0.0.1|localhost|::1|"") return 14;;                 # loopback / empty
      *[!a-zA-Z0-9_.-]* ) return 14;;                         # invalid docker name chars (also bars [] : )
      [!a-zA-Z0-9]* ) return 14;;                             # must start alnum
    esac
    # Belt-and-suspenders IP-literal reject (the existence allowlist below is the REAL
    # control; this only matters in the no-docker fallback). Reject IP literals in any
    # inet_aton-parseable notation:
    #   • all digits+dots            → dotted-quad / octal / decimal-int / trailing-dot
    #   • any octet starting 0x/0X   → hex, at ANY position (e.g. 169.254.0xA9.0xFE)
    # (IPv6 / v4-in-v6 already fall out: their ':' / '[' fail the split or the charset check.)
    local _oct _o
    IFS=. read -ra _oct <<< "$TARGET_HOST"
    for _o in "${_oct[@]}"; do case "$_o" in 0[xX]*) return 16;; esac; done
    case "$TARGET_HOST" in
      *[!0-9.]* ) : ;;                                        # has a name char → OK
      * ) return 16;;                                         # all digits/dots → IP/numeric → reject
    esac
    # PRIMARY control — EXISTENCE-BASED ALLOWLIST: the target must be a real container
    # ATTACHED to haproxy-net. Any IP/hostname (in any encoding) is not a container on that
    # network, so this rejects the whole SSRF class by construction, not by spelling.
    # Fail-closed by default (require): never SILENTLY downgrade to the blacklist.
    case "$INGRESS_VERIFY_CONTAINER" in
      off) : ;;
      auto) if _have "$DOCKER_BIN"; then _container_on_haproxy_net "$TARGET_HOST" || return 17
            else INGRESS_UNVERIFIED=1; fi;;               # visible-marked blacklist fallback
      require|*) if _have "$DOCKER_BIN"; then _container_on_haproxy_net "$TARGET_HOST" || return 17
                 else return 18; fi;;                     # fail-closed
    esac
    BACKEND_DESC="$TARGET_HOST:$TARGET_PORT"
    # https_port: request > config default; empty/0/"null" → HTTP-only (null in the API).
    case "$HTTPS_PORT" in ''|null|0) HTTPS_PORT="$INGRESS_HAPROXY_HTTPS_PORT";; esac
    case "$HTTPS_PORT" in ''|null|0) HTTPS_PORT="";; *[!0-9]*) return 15;; esac
  else
    # tunnel: loopback ONLY (anti open-proxy).
    case "$TARGET_HOST" in 127.0.0.1|localhost) : ;; *) return 12;; esac
    local label sane
    label="${HOSTNAME_REQ%%.*}"
    sane="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//')"
    [ -n "$sane" ] || return 10
    TUNNEL_NAME="${INGRESS_TUNNEL_PREFIX}$sane"
    CONNECTOR_TOKEN_PATH="$INGRESS_DIR/$TUNNEL_NAME.env"
  fi
  return 0
}
_validate_or_die() {
  case "$1" in
    10) _emit invalid "hostname is empty or not a valid DNS name"; exit 0;;
    11) _emit invalid "hostname must be a subdomain of the allowed zone '$INGRESS_ZONE'"; exit 0;;
    12) _emit invalid "tunnel-mode target host must be loopback (127.0.0.1/localhost); got '$TARGET_HOST'"; exit 0;;
    13) _emit invalid "target port must be an integer 1-65535; got '${TARGET##*:}'"; exit 0;;
    14) _emit invalid "haproxy-mode target must be a container name:port on haproxy-net (not loopback); got '$TARGET_HOST'"; exit 0;;
    15) _emit invalid "https_port must be an integer or null; got '$HTTPS_PORT'"; exit 0;;
    16) _emit invalid "haproxy-mode target must be a container NAME on haproxy-net, not an IP address or numeric host; got '$TARGET_HOST'"; exit 0;;
    17) _emit invalid "haproxy-mode target container '$TARGET_HOST' is not a running container attached to the '$INGRESS_HAPROXY_NET' network — refusing (only real containers on the shared proxy network may be exposed)"; exit 0;;
    18) _emit blocked_config "cannot verify the target is a container on '$INGRESS_HAPROXY_NET': docker CLI unavailable. The default is fail-closed. Give this runner docker access, or explicitly set INGRESS_VERIFY_CONTAINER=auto (blacklist fallback, result marked UNVERIFIED) or =off."; exit 0;;
  esac
}

# ========================================================================================
# HAPROXY MODE (primary) — register/deregister with the shared Registration API. No secret.
# ========================================================================================
_urlenc() { jq -rn --arg s "$1" '$s|@uri'; }
_haproxy_base() {  # the Registration API base URL, or empty if host unresolved
  local host="$INGRESS_HAPROXY_HOST"
  if [ -z "$host" ] && [ -f "$PROJECT_DIR/.env" ]; then
    # strip a trailing inline comment + surrounding quotes/space (config hygiene).
    host="$(sed -n 's/^[[:space:]]*HAPROXY_HOST[[:space:]]*=[[:space:]]*//p' "$PROJECT_DIR/.env" \
      | tail -1 | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//' | tr -d '"'"'"'')"
  fi
  [ -n "$host" ] || return 1
  printf 'http://%s:%s/v1/backends' "$host" "$INGRESS_HAPROXY_API_PORT"
}
# Existence probe (HTTP code; best-effort — some API builds lack GET).
_haproxy_exists() {
  local base; base="$(_haproxy_base)" || return 2
  local code; code="$(_curl -fsS -o /dev/null -w '%{http_code}' "$base/$(_urlenc "$HOSTNAME_REQ")" 2>/dev/null)" || return 1
  [ "$code" = 200 ]
}
# The CURRENTLY-registered backend "<container>:<http_port>" for the domain, or empty if
# none/unreadable. Lets us detect a RETARGET (existing route repointed) vs a true no-op.
_haproxy_backend_now() {
  local base; base="$(_haproxy_base)" || return 1
  _curl -fsS "$base/$(_urlenc "$HOSTNAME_REQ")" 2>/dev/null | jq -r '
    if type=="object" then
      ((.container // .backend // "") ) as $c | (.http_port // .port // empty) as $p |
      (if ($c|length)>0 then $c + (if $p then ":"+($p|tostring) else "" end) else "" end)
    else "" end' 2>/dev/null
}

_plan_haproxy() {
  local base; if ! base="$(_haproxy_base)"; then
    _emit blocked_config "HAPROXY_HOST is not set — cannot reach the haproxy Registration API. Set HAPROXY_HOST (env), the project .env, or .ingress.haproxy_host." \
      "$(jq -cn '["Set HAPROXY_HOST to the shared haproxy container/host reachable on the :8404 Registration API."]')"
    return
  fi
  local cur; cur="$(_haproxy_backend_now)"
  if [ -n "$cur" ]; then
    if [ "$cur" = "$BACKEND_DESC" ]; then _emit exists "'$HOSTNAME_REQ' is already registered to the SAME target $BACKEND_DESC; provision would be a no-op"
    else _emit conflict "'$HOSTNAME_REQ' is already registered to a DIFFERENT target ($cur); apply would REFUSE (no silent repoint). Deprovision it first, or request the existing target."; fi
    return
  fi
  if _haproxy_exists 2>/dev/null; then
    _emit conflict "a registration for '$HOSTNAME_REQ' already exists (current target unreadable); apply would REFUSE to repoint. Deprovision it first."; return
  fi
  _emit planned "would register '$HOSTNAME_REQ' -> $BACKEND_DESC (https_port=${HTTPS_PORT:-null}) with the haproxy Registration API at $base"
}
_apply_haproxy() {
  local base; if ! base="$(_haproxy_base)"; then
    _emit blocked_config "HAPROXY_HOST is not set — cannot reach the haproxy Registration API." \
      "$(jq -cn '["Set HAPROXY_HOST (env / project .env / .ingress.haproxy_host)."]')"
    return
  fi
  # Collision guard BEFORE any POST: never silently repoint a live public route.
  local cur; cur="$(_haproxy_backend_now)"
  if [ -n "$cur" ]; then
    [ "$cur" = "$BACKEND_DESC" ] && { _emit exists "'$HOSTNAME_REQ' already registered to $BACKEND_DESC; no change"; return; }
    _emit conflict "'$HOSTNAME_REQ' is already registered to a DIFFERENT target ($cur); REFUSING to repoint to $BACKEND_DESC. Deprovision it first."; return
  fi
  if _haproxy_exists 2>/dev/null; then
    _emit conflict "'$HOSTNAME_REQ' already has a registration (current target unreadable); REFUSING to repoint. Deprovision it first."; return
  fi
  local hp; if [ -n "$HTTPS_PORT" ]; then hp="$HTTPS_PORT"; else hp="null"; fi
  local body; body="$(jq -cn --arg d "$HOSTNAME_REQ" --arg c "$TARGET_HOST" \
      --argjson http "$TARGET_PORT" --argjson https "$hp" \
      '{domain:$d, container:$c, http_port:$http, https_port:$https}')"
  local code
  code="$(_curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' \
      "$base" --data "$body" 2>/dev/null)"
  case "$code" in
    2??) _emit ok "registered '$HOSTNAME_REQ' -> $BACKEND_DESC via haproxy (https_port=${HTTPS_PORT:-null})";;
    000|"") _emit error "haproxy Registration API unreachable at $base (curl failed)";;
    *) _emit error "haproxy Registration API returned HTTP $code registering '$HOSTNAME_REQ'";;
  esac
}
_deprovision_haproxy() {
  local base; if ! base="$(_haproxy_base)"; then
    _emit blocked_config "HAPROXY_HOST is not set — cannot reach the haproxy Registration API."; return
  fi
  local existed=0; _haproxy_exists 2>/dev/null && existed=1
  local code
  code="$(_curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$base/$(_urlenc "$HOSTNAME_REQ")" 2>/dev/null)"
  case "$code" in
    2??) _emit ok "deregistered '$HOSTNAME_REQ' from haproxy";;
    404) if [ "$existed" = 1 ]; then _emit ok "deregistered '$HOSTNAME_REQ'"; else _emit not_found "no haproxy registration for '$HOSTNAME_REQ' (idempotent)"; fi;;
    000|"") _emit error "haproxy Registration API unreachable at $base";;
    *) _emit error "haproxy Registration API returned HTTP $code deleting '$HOSTNAME_REQ'";;
  esac
}

# ========================================================================================
# TUNNEL MODE (fallback) — Cloudflare named tunnel. cert.pem (cli) OR account token (api).
# ========================================================================================
TUNNEL_UUID=""
# Account-scoped token for the API path: env override, else the SAME cloudflare.ini token
# (Option A — once the owner adds Account>Cloudflare Tunnel:Edit to it, provisioning just
# works with no export). The VALUE is never emitted.
_cf_acct_token() {
  if [ -n "${CLOUDFLARED_API_TOKEN:-}" ]; then printf '%s' "$CLOUDFLARED_API_TOKEN"; return 0; fi
  _cf_dns_token
}
_cf_dns_token() {
  [ -f "$CF_INI" ] || return 1
  local t; t="$(sed -n 's/^[[:space:]]*dns_cloudflare_api_token[[:space:]]*[:=][[:space:]]*//p' "$CF_INI" | head -1)"
  [ -n "$t" ] || return 1
  printf '%s' "$t"
}
_tunnel_mode() {
  case "$INGRESS_TUNNEL_MODE" in cli|api) printf '%s' "$INGRESS_TUNNEL_MODE"; return 0;; esac
  if [ -f "$HOME/.cloudflared/cert.pem" ]; then printf 'cli'; return 0; fi
  if [ -n "$(_cf_acct_token)" ]; then printf 'api'; return 0; fi
  return 1
}
_cf_zone_id() {
  local tok; tok="$(_cf_dns_token)" || return 1
  _curl -fsS -H "Authorization: Bearer $tok" "$CF_API/zones?name=$INGRESS_ZONE&status=active" 2>/dev/null | jq -r '.result[0].id // empty'
}
_cf_acct_id() {
  local tok; tok="$(_cf_acct_token)" || return 1
  _curl -fsS -H "Authorization: Bearer $tok" "$CF_API/accounts?per_page=1" 2>/dev/null | jq -r '.result[0].id // empty'
}
_tunnel_exists() {
  local mode; mode="$(_tunnel_mode)" || return 1
  if [ "$mode" = api ]; then
    local tok acct id; tok="$(_cf_acct_token)" || return 1; acct="$(_cf_acct_id)"; [ -n "$acct" ] || return 1
    id="$(_curl -fsS -H "Authorization: Bearer $tok" "$CF_API/accounts/$acct/cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false" 2>/dev/null | jq -r '.result[0].id // empty')"
    [ -n "$id" ] || return 1; TUNNEL_UUID="$id"; return 0
  fi
  local out; out="$(_cf tunnel list --name "$TUNNEL_NAME" --output json 2>/dev/null)"
  printf '%s' "$out" | jq -e --arg n "$TUNNEL_NAME" 'any(.[]?; .name==$n)' >/dev/null 2>&1 || return 1
  TUNNEL_UUID="$(printf '%s' "$out" | jq -r '.[0].id // empty')"; return 0
}
_can_create_tunnel() { _tunnel_mode >/dev/null 2>&1; }
# Read-only probe of whether the API token actually carries Cloudflare Tunnel scope, so
# --plan can detect the Option-A scope gap WITHOUT mutating. 200 on the list endpoint ⇒
# scope present. (cli/cert.pem mode is assumed scoped — no cheap read-only probe.)
_api_tunnel_scope_ok() {
  local tok acct code; tok="$(_cf_acct_token)" || return 1; acct="$(_cf_acct_id)" || return 1
  [ -n "$acct" ] || return 1
  code="$(_curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $tok" "$CF_API/accounts/$acct/cfd_tunnel?per_page=1" 2>/dev/null)"
  [ "$code" = 200 ]
}

_plan_tunnel() {
  if _tunnel_exists 2>/dev/null && [ -f "$CONNECTOR_TOKEN_PATH" ]; then
    _emit exists "tunnel '$TUNNEL_NAME' + token already present; provision would be a no-op (idempotent)"; return
  fi
  if ! _have "$CLOUDFLARED_BIN" && ! _cf --version >/dev/null 2>&1; then
    _emit blocked_scope "cloudflared binary not found (CLOUDFLARED_BIN=$CLOUDFLARED_BIN)" \
      "$(jq -cn '["Install cloudflared, or set CLOUDFLARED_BIN to its path."]')"; return
  fi
  local mode
  if ! mode="$(_tunnel_mode)"; then
    _emit blocked_scope "cannot create a cloudflared tunnel: no ~/.cloudflared/cert.pem and no usable Cloudflare token (none at $CF_INI, none in CLOUDFLARED_API_TOKEN). Owner does a one-time fix (below), then --apply provisions '$HOSTNAME_REQ' -> http://$TARGET." "$(_remediation_scope)"; return
  fi
  if [ "$mode" = api ] && ! _api_tunnel_scope_ok; then
    _emit blocked_scope "the Cloudflare token at $CF_INI is reachable but lacks 'Account > Cloudflare Tunnel > Edit' scope (Option A). No mutation performed. Owner adds that permission (below), then --apply just works — the token is auto-read." "$(_remediation_scope)"; return
  fi
  _emit planned "would create tunnel '$TUNNEL_NAME', persist 0600 token at $CONNECTOR_TOKEN_PATH, configure ingress -> http://$TARGET, add CNAME $HOSTNAME_REQ, and start it via $INGRESS_SUPERVISOR"
}
_plan_tunnel_deprovision() {
  if ! _tunnel_exists 2>/dev/null && [ ! -f "$CONNECTOR_TOKEN_PATH" ]; then
    _emit not_found "no tunnel '$TUNNEL_NAME' and no token file; nothing to deprovision (idempotent)"; return
  fi
  _emit planned "would stop + delete tunnel '$TUNNEL_NAME', remove CNAME $HOSTNAME_REQ, and delete the token + config"
}

_apply_tunnel() {
  mkdir -p "$INGRESS_DIR" 2>/dev/null || true; chmod 700 "$INGRESS_DIR" 2>/dev/null || true
  if _tunnel_exists 2>/dev/null && [ -f "$CONNECTOR_TOKEN_PATH" ]; then
    _emit exists "tunnel '$TUNNEL_NAME' already provisioned; returning existing token path (no change)"; return
  fi
  local mode; if ! mode="$(_tunnel_mode)"; then
    _emit blocked_scope "tunnel-create requires a credential this instance does not hold (no cert.pem; token at $CF_INI is DNS-only). NOT provisioned. Owner fix below, then re-run --apply." "$(_remediation_scope)"; return
  fi
  local token=""
  if [ "$mode" = api ]; then
    local tok acct create_json id; tok="$(_cf_acct_token)"; acct="$(_cf_acct_id)"
    [ -n "$acct" ] || { _emit blocked_scope "the token could not resolve a Cloudflare account (needs Account:Read + Cloudflare Tunnel:Edit). NOT provisioned." "$(_remediation_scope)"; return; }
    create_json="$(_curl -fsS -X POST -H "Authorization: Bearer $tok" -H "Content-Type: application/json" \
      "$CF_API/accounts/$acct/cfd_tunnel" --data "$(jq -cn --arg n "$TUNNEL_NAME" '{name:$n, config_src:"cloudflare"}')" 2>&1)"
    id="$(printf '%s' "$create_json" | jq -r '.result.id // empty' 2>/dev/null)"
    if [ -z "$id" ]; then
      if _tunnel_exists 2>/dev/null; then id="$TUNNEL_UUID"; else
        case "$create_json" in
          *[Ff]orbidden*|*403*|*[Aa]uthentic*|*9109*|*"not authorized"*) _emit blocked_scope "Cloudflare API rejected tunnel create (token lacks Cloudflare Tunnel:Edit). NOT provisioned. Owner fix below." "$(_remediation_scope)";;
          *) _emit error "Cloudflare API tunnel create failed: $(printf '%s' "$create_json" | tr '\n' ' ' | cut -c1-240)";;
        esac; return
      fi
    fi
    TUNNEL_UUID="$id"
    token="$(printf '%s' "$create_json" | jq -r '.result.token // empty' 2>/dev/null)"
    [ -n "$token" ] || token="$(_curl -fsS -H "Authorization: Bearer $tok" "$CF_API/accounts/$acct/cfd_tunnel/$id/token" 2>/dev/null | jq -r '. // empty')"
  else
    local create_out create_rc; create_out="$(_cf tunnel create "$TUNNEL_NAME" 2>&1)"; create_rc=$?
    if [ $create_rc -ne 0 ]; then
      case "$create_out" in
        *already\ exists*) : ;;
        *[Aa]uth*|*cert.pem*|*credential*|*[Ff]orbidden*|*403*|*login*) _emit blocked_scope "cloudflared tunnel create failed on authorization (scope gap). NOT provisioned. Owner fix below." "$(_remediation_scope)"; return;;
        *) _emit error "cloudflared tunnel create failed: $(printf '%s' "$create_out" | tr '\n' ' ' | cut -c1-240)"; return;;
      esac
    fi
    _tunnel_exists 2>/dev/null || true
    token="$(_cf tunnel token "$TUNNEL_NAME" 2>/dev/null)"
  fi

  if [ -z "$token" ]; then _rollback_tunnel "$mode"; _emit error "tunnel '$TUNNEL_NAME' created but its connector token could not be read; rolled back"; return; fi
  if ! ( umask 077; printf 'TUNNEL_TOKEN=%s\n' "$token" > "$CONNECTOR_TOKEN_PATH" ) || [ ! -s "$CONNECTOR_TOKEN_PATH" ]; then
    unset token; _rollback_tunnel "$mode"; _emit error "could not persist the connector token to $CONNECTOR_TOKEN_PATH; rolled back"; return
  fi
  chmod 600 "$CONNECTOR_TOKEN_PATH" 2>/dev/null || true; unset token

  if ! _configure_tunnel_ingress "$mode"; then _rollback_tunnel "$mode"; _emit error "tunnel + token created but the ingress rule for $HOSTNAME_REQ could not be configured; rolled back"; return; fi
  if ! _dns_upsert; then _rollback_tunnel "$mode"; _emit error "tunnel + ingress configured but the DNS CNAME for $HOSTNAME_REQ could not be created; rolled back"; return; fi
  _start_service "$mode" || _log "service start reported a problem (tunnel + ingress + DNS are in place)"
  _emit ok "provisioned $HOSTNAME_REQ -> http://$TARGET via tunnel '$TUNNEL_NAME'"
}

_rollback_tunnel() {  # <mode>
  local mode="${1:-cli}"; _log "rolling back partial provision of '$TUNNEL_NAME'"
  if _tunnel_exists 2>/dev/null; then
    if [ "$mode" = api ]; then local tok acct; tok="$(_cf_acct_token)"; acct="$(_cf_acct_id)"; [ -n "$acct" ] && _curl -fsS -X DELETE -H "Authorization: Bearer $tok" "$CF_API/accounts/$acct/cfd_tunnel/$TUNNEL_UUID" >/dev/null 2>&1 || true
    else _cf tunnel delete -f "$TUNNEL_NAME" >/dev/null 2>&1 || true; fi
  fi
  rm -f "$CONNECTOR_TOKEN_PATH" "$INGRESS_DIR/$TUNNEL_NAME.config.yml" 2>/dev/null || true
}

_apply_tunnel_deprovision() {
  local existed=0 problem=0 del_out del_rc
  if _tunnel_exists 2>/dev/null || [ -f "$CONNECTOR_TOKEN_PATH" ]; then existed=1; fi
  _dns_delete || { problem=1; _log "DNS CNAME delete reported a problem"; }
  _stop_service || true
  if _tunnel_exists 2>/dev/null; then
    local mode; mode="$(_tunnel_mode 2>/dev/null || echo cli)"
    if [ "$mode" = api ]; then local tok acct; tok="$(_cf_acct_token)"; acct="$(_cf_acct_id)"
      del_out="$(_curl -fsS -X DELETE -H "Authorization: Bearer $tok" "$CF_API/accounts/$acct/cfd_tunnel/$TUNNEL_UUID" 2>&1)"; del_rc=$?
    else del_out="$(_cf tunnel delete -f "$TUNNEL_NAME" 2>&1)"; del_rc=$?; fi
    if [ $del_rc -ne 0 ]; then
      case "$del_out" in
        *[Aa]uth*|*cert.pem*|*credential*|*[Ff]orbidden*|*403*) _emit blocked_scope "DNS + token removed, but tunnel delete needs account scope. Owner fix below." "$(_remediation_scope)"; return;;
        *) problem=1; _log "tunnel delete: $del_out";;
      esac
    fi
  fi
  [ -f "$CONNECTOR_TOKEN_PATH" ] && rm -f "$CONNECTOR_TOKEN_PATH"
  rm -f "$INGRESS_DIR/$TUNNEL_NAME.config.yml" 2>/dev/null || true
  if [ "$existed" = 0 ]; then _emit not_found "nothing to deprovision for '$TUNNEL_NAME'"
  elif [ "$problem" = 1 ]; then _emit partial "deprovisioned '$TUNNEL_NAME' with one or more non-fatal warnings (see logs)"
  else _emit ok "deprovisioned '$TUNNEL_NAME' (tunnel + CNAME + token removed)"; fi
}

# tunnel ingress-rule config (maps the public hostname to http://<target>).
_ingress_config_yml() { printf '%s' "$INGRESS_DIR/$TUNNEL_NAME.config.yml"; }
_configure_tunnel_ingress() {  # <mode>
  local mode="${1:-cli}"
  if [ "$mode" = api ]; then
    case "$INGRESS_DNS_MODE" in skip) _log "DNS_MODE=skip — ingress config PUT skipped"; return 0;; esac
    local tok acct body; tok="$(_cf_acct_token)"; acct="$(_cf_acct_id)"
    [ -n "$acct" ] && [ -n "$TUNNEL_UUID" ] || { _log "ingress config: no account id / tunnel uuid"; return 1; }
    body="$(jq -cn --arg h "$HOSTNAME_REQ" --arg s "http://$TARGET" '{config:{ingress:[{hostname:$h,service:$s},{service:"http_status:404"}]}}')"
    _curl -fsS -X PUT -H "Authorization: Bearer $tok" -H "Content-Type: application/json" \
      "$CF_API/accounts/$acct/cfd_tunnel/$TUNNEL_UUID/configurations" --data "$body" >/dev/null 2>&1; return $?
  fi
  # cli: a locally-managed tunnel runs from a config.yml with its credentials file. Guard
  # that the credentials file the connector will need actually exists (else it crash-loops).
  local yml cred; yml="$(_ingress_config_yml)"; cred="$HOME/.cloudflared/$TUNNEL_UUID.json"
  [ -n "$TUNNEL_UUID" ] || { _log "ingress config: no tunnel uuid"; return 1; }
  [ -f "$cred" ] || { _log "ingress config: credentials file $cred not found (cloudflared wrote it elsewhere?)"; return 1; }
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

_dns_upsert() {
  case "$INGRESS_DNS_MODE" in
    skip) _log "INGRESS_DNS_MODE=skip — DNS upsert skipped"; return 0;;
    cli)  _cf tunnel route dns "$TUNNEL_NAME" "$HOSTNAME_REQ" >/dev/null 2>&1; return $?;;
  esac
  local tok zid uuid target rid
  tok="$(_cf_dns_token)" || { _log "no DNS token"; return 1; }
  zid="$(_cf_zone_id)" || { _log "no zone id"; return 1; }; [ -n "$zid" ] || return 1
  uuid="${TUNNEL_UUID:-}"; [ -n "$uuid" ] || { _tunnel_exists 2>/dev/null && uuid="$TUNNEL_UUID"; }
  [ -n "$uuid" ] || { _log "no tunnel uuid"; return 1; }; target="$uuid.cfargotunnel.com"
  rid="$(_curl -fsS -H "Authorization: Bearer $tok" "$CF_API/zones/$zid/dns_records?type=CNAME&name=$HOSTNAME_REQ" 2>/dev/null | jq -r '.result[0].id // empty')"
  local body; body="$(jq -cn --arg n "$HOSTNAME_REQ" --arg c "$target" '{type:"CNAME",name:$n,content:$c,proxied:true,ttl:1}')"
  if [ -n "$rid" ]; then _curl -fsS -X PUT -H "Authorization: Bearer $tok" -H "Content-Type: application/json" "$CF_API/zones/$zid/dns_records/$rid" --data "$body" >/dev/null 2>&1
  else _curl -fsS -X POST -H "Authorization: Bearer $tok" -H "Content-Type: application/json" "$CF_API/zones/$zid/dns_records" --data "$body" >/dev/null 2>&1; fi
}
_dns_delete() {
  case "$INGRESS_DNS_MODE" in skip) return 0;; cli) return 0;; esac
  local tok zid rid; tok="$(_cf_dns_token)" || return 1; zid="$(_cf_zone_id)" || return 1; [ -n "$zid" ] || return 1
  rid="$(_curl -fsS -H "Authorization: Bearer $tok" "$CF_API/zones/$zid/dns_records?type=CNAME&name=$HOSTNAME_REQ" 2>/dev/null | jq -r '.result[0].id // empty')"
  [ -n "$rid" ] || return 0
  _curl -fsS -X DELETE -H "Authorization: Bearer $tok" "$CF_API/zones/$zid/dns_records/$rid" >/dev/null 2>&1
}

_unit_name() { printf '%s.service' "$TUNNEL_NAME"; }
_start_service() {  # <mode>
  local mode="${1:-cli}"
  [ "$INGRESS_SUPERVISOR" = "systemd" ] || { _log "supervisor=$INGRESS_SUPERVISOR — start skipped"; return 0; }
  _have systemctl || { _log "no systemctl — start skipped"; return 0; }
  local unit_dir="$HOME/.config/systemd/user"; mkdir -p "$unit_dir" 2>/dev/null || true
  local cfbin; cfbin="$(command -v "$CLOUDFLARED_BIN" 2>/dev/null || printf '%s' "$CLOUDFLARED_BIN")"
  local envline execline
  if [ "$mode" = api ]; then envline="EnvironmentFile=$CONNECTOR_TOKEN_PATH"; execline="ExecStart=$cfbin tunnel --no-autoupdate run"
  else envline="# (cli mode: credentials + ingress from the config file)"; execline="ExecStart=$cfbin tunnel --no-autoupdate --config $(_ingress_config_yml) run $TUNNEL_NAME"; fi
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
  [ "$INGRESS_SUPERVISOR" = "systemd" ] || return 0; _have systemctl || return 0
  systemctl --user disable --now "$(_unit_name)" 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/$(_unit_name)" 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
}

# --- Help / Main -------------------------------------------------------------------------
_usage() { sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
main() {
  if ! _have jq; then _log "jq is required"; exit 1; fi
  _read_args "$@"; local ra=$?
  if [ "$ra" = 2 ] || [ "$OP" = "--help" ] || [ "$OP" = "-h" ]; then _usage; exit 0; fi
  case "$OP" in provision|deprovision) : ;; *) _log "op must be provision|deprovision"; _usage; exit 1;; esac
  case "$MODE" in plan|apply) : ;; *) _log "mode must be --plan|--apply"; exit 1;; esac
  case "$INGRESS_MODE" in haproxy|tunnel) : ;; *) _log "INGRESS_MODE must be haproxy|tunnel"; exit 1;; esac

  if ! _load_request; then _emit invalid "request must be a JSON object on stdin/--in/--json"; exit 0; fi
  _derive; _validate_or_die $?

  # OWNER-CONFIRMATION GATE (defense-in-depth). --apply mutates public ingress, so it
  # refuses unless the owner sets INGRESS_APPLY_CONFIRM=1. The capability-scoped processor
  # runs ONLY --plan and must NOT set this; copying the plan command verbatim therefore
  # yields a safe refusal, not a provision.
  if [ "$MODE" = apply ] && [ "${INGRESS_APPLY_CONFIRM:-}" != "1" ]; then
    _emit blocked_confirm "refusing to --apply without owner confirmation: this mutates public ingress. The OWNER re-runs with INGRESS_APPLY_CONFIRM=1 after reviewing the --plan. The capability-scoped processor must NOT set this."
    exit 0
  fi

  if [ "$INGRESS_MODE" = haproxy ]; then
    case "$OP:$MODE" in
      provision:plan)    _plan_haproxy;;
      provision:apply)   _apply_haproxy;;
      deprovision:plan)  _haproxy_exists 2>/dev/null && _emit planned "would deregister '$HOSTNAME_REQ' from haproxy" || _emit not_found "no haproxy registration for '$HOSTNAME_REQ' (idempotent)";;
      deprovision:apply) _deprovision_haproxy;;
    esac
  else
    case "$OP:$MODE" in
      provision:plan)    _plan_tunnel;;
      provision:apply)   _apply_tunnel;;
      deprovision:plan)  _plan_tunnel_deprovision;;
      deprovision:apply) _apply_tunnel_deprovision;;
    esac
  fi
}
main "$@"
