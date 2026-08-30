#!/usr/bin/env bash
# provision-ingress.test.sh — hermetic contract test for the provision-ingress verb backend.
# Covers BOTH modes with all network fully STUBBED (no real haproxy, tunnels, or Cloudflare):
#   A. haproxy mode (PRIMARY) — Registration API register/deregister, idempotency,
#      target-pin (container not loopback), zone-pin, blocked_config, response shape.
#   B. tunnel mode (FALLBACK) — scope gap (blocked_scope), CLI + API backends, Option-A
#      token auto-read from cloudflare.ini, ingress-rule config, rollback, token never
#      emitted, deprovision, idempotency.
#   C. validation (both modes) · D. owner-confirm gate · E. per-project config.
# Run:  bash test/provision-ingress.test.sh
set -uo pipefail

FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }
chk()  { if eval "$2"; then pass "$1"; else fail "$1 — [$2]"; fi; }
j()    { jq -r "$1"; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SH="$REPO/claude_conf/hooks/provision-ingress.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/provingress.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/bin"; mkdir -p "$STUB"

# ========================================================================================
echo "== A. haproxy mode (primary) =="
export HP_STATE="$TMP/hpstate"; mkdir -p "$HP_STATE"
# docker stub for the existence-based container allowlist (primary target pin).
cat > "$STUB/docker" <<'EOF'
#!/usr/bin/env bash
set -u
name="${!#}"
case " ${DOCKER_NET_MEMBERS:-} " in *" $name "*) printf 'bridge\nhaproxy-net\n'; exit 0;; esac
case " ${DOCKER_OFFNET:-} " in *" $name "*) printf 'bridge\n'; exit 0;; esac
exit 1
EOF
chmod +x "$STUB/docker"
export DOCKER_BIN="$STUB/docker"
export DOCKER_NET_MEMBERS="track42-web c1"   # containers attached to haproxy-net
export DOCKER_OFFNET="offnet-svc"            # exists but NOT on haproxy-net
cat > "$STUB/curl-haproxy" <<'EOF'
#!/usr/bin/env bash
# Stub of the haproxy Registration API. Honors -X, --data, and -w '%{http_code}' (prints code).
set -u
method=GET; url=""; want_code=0
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift;;
    -w) want_code=1;;
    --data) shift;;
    http*://*) url="$1";;
  esac; shift
done
S="${HP_STATE:?}"; path="${url#*:*/}"; dom="${url##*/v1/backends/}"; [ "$dom" = "$url" ] && dom=""
code=200
case "$method" in
  GET)    [ -n "$dom" ] && { [ -f "$S/$dom" ] && code=200 || code=404; };;
  POST)   : > "$S/${dom:-_last}";;  # POST has no domain in path; body carries it — track via _mark below
  DELETE) if [ -n "$dom" ] && [ -f "$S/$dom" ]; then rm -f "$S/$dom"; code=200; else code=404; fi;;
esac
printf '%s' "$code"
EOF
chmod +x "$STUB/curl-haproxy"
# The POST body carries the domain; a stub can't read the fd body from -w mode easily, so
# use a tiny wrapper that records the domain from --data before delegating.
cat > "$STUB/curl-haproxy-post" <<'EOF'
#!/usr/bin/env bash
# haproxy Registration API stub. Stores the POST body per domain; serves it on GET (body)
# or a code on GET -w; honors DELETE. Ignores leading --connect-timeout/--max-time flags.
set -u
data=""; method=GET; url=""; want_code=0
while [ $# -gt 0 ]; do case "$1" in -X) method="$2"; shift;; --data) data="$2"; shift;; -w) want_code=1;; http*://*) url="$1";; esac; shift; done
S="${HP_STATE:?}"
if [ "$method" = POST ]; then d="$(printf '%s' "$data" | jq -r .domain)"; printf '%s' "$data" > "$S/$d"; printf '200'; exit 0; fi
dom="${url##*/v1/backends/}"
case "$method" in
  GET) if [ "$want_code" = 1 ]; then { [ -f "$S/$dom" ] && printf '200' || printf '404'; }
       else { [ -f "$S/$dom" ] && cat "$S/$dom" || exit 22; }; fi;;
  DELETE) if [ -f "$S/$dom" ]; then rm -f "$S/$dom"; printf '200'; else printf '404'; fi;;
esac
EOF
chmod +x "$STUB/curl-haproxy-post"

hp() { INGRESS_MODE=haproxy INGRESS_HAPROXY_HOST=haproxy-test INGRESS_CURL="$STUB/curl-haproxy-post" \
         INGRESS_PROJECT_DIR="$TMP/noproj" INGRESS_APPLY_CONFIRM=1 bash "$SH" "$@"; }
REQ_HP='{"hostname":"track-42.staging.concierge-dev.app","target":"track42-web:8080","https_port":443,"purpose":"spawned track"}'

OUT="$(printf '%s' "$REQ_HP" | INGRESS_MODE=haproxy INGRESS_HAPROXY_HOST=haproxy-test INGRESS_CURL="$STUB/curl-haproxy-post" INGRESS_PROJECT_DIR="$TMP/noproj" bash "$SH" provision --plan)"
chk "haproxy plan → planned"                 "[ \"\$(printf '%s' \"\$OUT\" | j .status)\" = 'planned' ]"
chk "response mode=haproxy"                   "[ \"\$(printf '%s' \"\$OUT\" | j .mode)\" = 'haproxy' ]"
chk "response backend=container:port"         "[ \"\$(printf '%s' \"\$OUT\" | j .backend)\" = 'track42-web:8080' ]"
chk "no tunnel/token fields leak a value"     "[ \"\$(printf '%s' \"\$OUT\" | j .connector_token_path)\" = '' ]"

OUT_A="$(printf '%s' "$REQ_HP" | hp provision --apply)"
chk "haproxy apply → ok"                       "[ \"\$(printf '%s' \"\$OUT_A\" | j .status)\" = 'ok' ]"
chk "haproxy registered the domain"           "[ -f \"$HP_STATE/track-42.staging.concierge-dev.app\" ]"
OUT_I="$(printf '%s' "$REQ_HP" | hp provision --apply)"
chk "haproxy re-provision same target → exists" "[ \"\$(printf '%s' \"\$OUT_I\" | j .status)\" = 'exists' ]"
chk "still exactly one registration"          "[ \"\$(ls \"$HP_STATE\" | wc -l | tr -d ' ')\" = '1' ]"
# retarget the SAME hostname to a DIFFERENT target → must REFUSE with 'conflict', no repoint
OUT_C="$(printf '{\"hostname\":\"track-42.staging.concierge-dev.app\",\"target\":\"track42-web:9090\"}' | hp provision --apply)"
chk "haproxy retarget → conflict (refuse)"     "[ \"\$(printf '%s' \"\$OUT_C\" | j .status)\" = 'conflict' ]"
chk "conflict did NOT repoint the route"        "jq -e '.http_port==8080' \"$HP_STATE/track-42.staging.concierge-dev.app\" >/dev/null"
OUT_CP="$(printf '{\"hostname\":\"track-42.staging.concierge-dev.app\",\"target\":\"track42-web:7000\"}' | hp provision --plan)"
chk "haproxy plan retarget → conflict"          "[ \"\$(printf '%s' \"\$OUT_CP\" | j .status)\" = 'conflict' ]"
OUT_D="$(printf '%s' "$REQ_HP" | hp deprovision --apply)"
chk "haproxy deprovision → ok"                 "[ \"\$(printf '%s' \"\$OUT_D\" | j .status)\" = 'ok' ]"
chk "registration removed"                     "[ ! -f \"$HP_STATE/track-42.staging.concierge-dev.app\" ]"
OUT_D2="$(printf '%s' "$REQ_HP" | hp deprovision --apply)"
chk "haproxy deprovision again → not_found"    "[ \"\$(printf '%s' \"\$OUT_D2\" | j .status)\" = 'not_found' ]"

# target-pin: haproxy rejects loopback (unreachable from the proxy container)
LB="$(printf '{\"hostname\":\"x.staging.concierge-dev.app\",\"target\":\"127.0.0.1:8080\"}' | INGRESS_MODE=haproxy INGRESS_HAPROXY_HOST=h bash "$SH" provision --plan | j .status)"
chk "haproxy loopback target → invalid"        "[ \"$LB\" = 'invalid' ]"
BADC="$(printf '{\"hostname\":\"x.staging.concierge-dev.app\",\"target\":\"bad name:80\"}' | INGRESS_MODE=haproxy INGRESS_HAPROXY_HOST=h bash "$SH" provision --plan | j .status)"
chk "haproxy invalid container chars → invalid" "[ \"$BADC\" = 'invalid' ]"
# EXISTENCE-BASED ALLOWLIST (primary) + IP-literal reject (belt-and-suspenders).
ipchk(){ printf '{"hostname":"x.staging.concierge-dev.app","target":"%s"}' "$1" | INGRESS_MODE=haproxy INGRESS_HAPROXY_HOST=haproxy-test INGRESS_CURL="$STUB/curl-haproxy-post" bash "$SH" provision --plan | j .status; }
chk "haproxy public IP target → invalid"       "[ \"\$(ipchk '8.8.8.8:80')\" = 'invalid' ]"
chk "haproxy metadata IP target → invalid"     "[ \"\$(ipchk '169.254.169.254:80')\" = 'invalid' ]"
chk "haproxy docker-gw IP target → invalid"    "[ \"\$(ipchk '172.17.0.1:80')\" = 'invalid' ]"
chk "haproxy numeric host → invalid"           "[ \"\$(ipchk '2130706433:80')\" = 'invalid' ]"
chk "haproxy hex IP → invalid"                 "[ \"\$(ipchk '0x7f000001:80')\" = 'invalid' ]"
chk "haproxy octal-dotted IP → invalid"        "[ \"\$(ipchk '0300.0250.0.01:80')\" = 'invalid' ]"
chk "haproxy on-net container → planned"       "[ \"\$(ipchk 'track42-web:80')\" = 'planned' ]"
# the real control: a name that is NOT a container on haproxy-net is rejected regardless of spelling
chk "haproxy off-net container → invalid"      "[ \"\$(ipchk 'offnet-svc:80')\" = 'invalid' ]"
chk "haproxy nonexistent container → invalid"  "[ \"\$(ipchk 'ghost-svc:80')\" = 'invalid' ]"
# belt-and-suspenders: with the existence check OFF (no-docker fallback), the IP-literal
# reject alone must still block IPs in every inet_aton notation incl. mixed-radix hex octets.
bchk(){ printf '{"hostname":"x.staging.concierge-dev.app","target":"%s"}' "$1" | INGRESS_VERIFY_CONTAINER=off INGRESS_MODE=haproxy INGRESS_HAPROXY_HOST=haproxy-test INGRESS_CURL="$STUB/curl-haproxy-post" bash "$SH" provision --plan | j .status; }
chk "belt: mixed-radix hex IP → invalid"       "[ \"\$(bchk '169.254.0xA9.0xFE:80')\" = 'invalid' ]"
chk "belt: hex 2nd-octet IP → invalid"         "[ \"\$(bchk '172.0x11.0.1:80')\" = 'invalid' ]"
chk "belt: canonical IP → invalid"             "[ \"\$(bchk '8.8.8.8:80')\" = 'invalid' ]"
chk "belt: legit name still OK (verify off)"   "[ \"\$(bchk 'track42-web:80')\" = 'planned' ]"
# DEFAULT is fail-closed: no docker → blocked_config, never a silent blacklist-only pass.
DEF="$(printf '{\"hostname\":\"x.staging.concierge-dev.app\",\"target\":\"track42-web:80\"}' | env -u INGRESS_VERIFY_CONTAINER -u DOCKER_BIN DOCKER_BIN=/nonexistent-docker INGRESS_MODE=haproxy INGRESS_HAPROXY_HOST=h bash "$SH" provision --plan | j .status)"
chk "DEFAULT + no docker → blocked_config (fail-closed)" "[ \"$DEF\" = 'blocked_config' ]"
RC="$(printf '{\"hostname\":\"x.staging.concierge-dev.app\",\"target\":\"track42-web:80\"}' | env -u DOCKER_BIN DOCKER_BIN=/nonexistent-docker INGRESS_VERIFY_CONTAINER=require INGRESS_MODE=haproxy INGRESS_HAPROXY_HOST=h bash "$SH" provision --plan | j .status)"
chk "explicit require + no docker → blocked_config" "[ \"$RC\" = 'blocked_config' ]"
# auto is the explicit weaker opt-in: no docker → passes on blacklist BUT marked UNVERIFIED,
# and IPs (incl. mixed-radix) are still rejected by the blacklist even in this fallback.
AUV="$(printf '{\"hostname\":\"x.staging.concierge-dev.app\",\"target\":\"track42-web:80\"}' | env -u DOCKER_BIN DOCKER_BIN=/nonexistent-docker INGRESS_VERIFY_CONTAINER=auto INGRESS_MODE=haproxy INGRESS_HAPROXY_HOST=haproxy-test INGRESS_CURL="$STUB/curl-haproxy-post" bash "$SH" provision --plan)"
chk "auto + no docker → planned"                "[ \"\$(printf '%s' \"\$AUV\" | j .status)\" = 'planned' ]"
chk "auto + no docker → reason marked UNVERIFIED" "printf '%s' \"\$AUV\" | jq -e '.reason|test(\"UNVERIFIED\")' >/dev/null"
AIV="$(printf '{\"hostname\":\"x.staging.concierge-dev.app\",\"target\":\"169.254.0xA9.0xFE:80\"}' | env -u DOCKER_BIN DOCKER_BIN=/nonexistent-docker INGRESS_VERIFY_CONTAINER=auto INGRESS_MODE=haproxy INGRESS_HAPROXY_HOST=h bash "$SH" provision --plan | j .status)"
chk "auto + no docker + mixed-radix IP → invalid" "[ \"$AIV\" = 'invalid' ]"
# zone-pin under staging.concierge-dev.app
WZ="$(printf '{\"hostname\":\"x.evil.net\",\"target\":\"c:80\"}' | INGRESS_MODE=haproxy INGRESS_HAPROXY_HOST=h bash "$SH" provision --plan | j .status)"
chk "haproxy wrong zone → invalid"             "[ \"$WZ\" = 'invalid' ]"
# blocked_config when HAPROXY_HOST unresolvable
BC="$(printf '%s' "$REQ_HP" | env -u HAPROXY_HOST INGRESS_MODE=haproxy INGRESS_HAPROXY_HOST= INGRESS_PROJECT_DIR=$TMP/noproj bash "$SH" provision --plan | j .status)"
chk "haproxy no HAPROXY_HOST → blocked_config"  "[ \"$BC\" = 'blocked_config' ]"
# confirm gate applies in haproxy mode too
NC="$(printf '%s' "$REQ_HP" | env -u INGRESS_APPLY_CONFIRM INGRESS_MODE=haproxy INGRESS_HAPROXY_HOST=haproxy-test INGRESS_CURL="$STUB/curl-haproxy-post" INGRESS_PROJECT_DIR=$TMP/noproj bash "$SH" provision --apply | j .status)"
chk "haproxy unconfirmed apply → blocked_confirm" "[ \"$NC\" = 'blocked_confirm' ]"
chk "haproxy needs ZERO cloudflare/secret"     "printf '%s' \"\$OUT_A\" | jq -e '.mode==\"haproxy\" and .connector_token_path==\"\" and (.reason|test(\"[Cc]loudflare\")|not)' >/dev/null"

# ========================================================================================
echo "== B. tunnel mode (fallback) =="
export INGRESS_MODE="tunnel"
export INGRESS_PROJECT_DIR="$TMP/proj"
export INGRESS_SECRETS_DIR="$TMP/proj/.secrets"
export INGRESS_TOKEN_DIR="$TMP/proj/.secrets/ingress"
export INGRESS_CF_INI="$TMP/proj/.secrets/staging-tls/cloudflare.ini"
export INGRESS_ZONE="concierge-dev.app"
export INGRESS_DNS_MODE="skip"
export INGRESS_SUPERVISOR="none"
export INGRESS_APPLY_CONFIRM="1"
export HOME="$TMP/home"
mkdir -p "$INGRESS_TOKEN_DIR" "$TMP/proj/.secrets/staging-tls" "$HOME"
printf 'dns_cloudflare_api_token = testtoken\n' > "$INGRESS_CF_INI"
export CF_STATE="$TMP/cfstate"; mkdir -p "$CF_STATE"
REQ='{"hostname":"track-42.concierge-dev.app","target":"127.0.0.1:8931","purpose":"spawned track","ttl_hint":"6h"}'
TOKEN_VALUE="eyJTdHViQ29ubmVjdG9yVG9rZW5WYWx1ZSJ9"

cat > "$STUB/cloudflared" <<'EOF'
#!/usr/bin/env bash
set -u
sub="${1:-}"; act="${2:-}"
case "$sub $act" in
  "--version "*|"--version") echo "cloudflared version 0.0.0-stub"; exit 0;;
  "tunnel create") name="$3"
    [ "${CF_CREATE_FAILS:-0}" = 1 ] && { echo "Unauthorized: cert.pem not found / cloudflared tunnel login" >&2; exit 1; }
    : > "$CF_STATE/$name"; mkdir -p "$HOME/.cloudflared"; : > "$HOME/.cloudflared/00000000-0000-4000-8000-000000000000.json"
    echo "Created tunnel $name"; exit 0;;
  "tunnel list") name=""; while [ $# -gt 0 ]; do [ "$1" = "--name" ] && name="${2:-}"; shift; done
    if [ -n "$name" ]; then [ -f "$CF_STATE/$name" ] && printf '[{"id":"00000000-0000-4000-8000-000000000000","name":"%s"}]' "$name" || printf '[]'
    else printf '['; f1=1; for f in "$CF_STATE"/*; do [ -e "$f" ] || continue; b="$(basename "$f")"; [ $f1 = 1 ]||printf ','; f1=0; printf '{"id":"00000000-0000-4000-8000-000000000000","name":"%s"}' "$b"; done; printf ']'; fi; exit 0;;
  "tunnel token") echo "eyJTdHViQ29ubmVjdG9yVG9rZW5WYWx1ZSJ9"; exit 0;;
  "tunnel delete") dn="${!#}"; rm -f "$CF_STATE/$dn" 2>/dev/null; echo "Deleted $dn"; exit 0;;
  *) echo "stub: $*" >&2; exit 1;;
esac
EOF
chmod +x "$STUB/cloudflared"
export CLOUDFLARED_BIN="$STUB/cloudflared"

# --- B1: scope gap — no cert.pem AND no token at all → blocked_scope, cheaply (no network)
OUT="$(printf '%s' "$REQ" | INGRESS_CF_INI=/nonexistent-ini HOME="$TMP/home" bash "$SH" provision --plan)"
chk "no cert + no token → blocked_scope"       "[ \"\$(printf '%s' \"\$OUT\" | j .status)\" = 'blocked_scope' ]"
chk "blocked_scope carries 2 remediations"     "printf '%s' \"\$OUT\" | jq -e '.remediation|length==2' >/dev/null"
chk "remediation A is zero-touch (auto-read)"  "printf '%s' \"\$OUT\" | jq -e '.remediation|any(test(\"no export needed\"))' >/dev/null"
OA="$(printf '%s' "$REQ" | INGRESS_CF_INI=/nonexistent-ini HOME="$TMP/home" bash "$SH" provision --apply)"
chk "no-cred apply → blocked_scope"            "[ \"\$(printf '%s' \"\$OA\" | j .status)\" = 'blocked_scope' ]"
chk "no-cred apply wrote NO token file"        "[ ! -f \"$INGRESS_TOKEN_DIR/ingress-track-42.env\" ]"

# --- CF API stub (honors -w '%{http_code}' → prints code; else JSON body) --------------
API_STATE="$TMP/apistate"; mkdir -p "$API_STATE/tunnels" "$API_STATE/dns"
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
set -u
method=GET; url=""; data=""; want_code=0
while [ $# -gt 0 ]; do case "$1" in -X) method="$2"; shift;; --data) data="$2"; shift;; -w) want_code=1;; http*://*) url="$1";; esac; shift; done
S="${API_STATE:?}"; path="${url#*client/v4}"; path="${path%%\?*}"; q="${url#*\?}"
emit(){ if [ "$want_code" = 1 ]; then printf '%s' "${2:-200}"; else printf '%s' "$1"; fi; }
case "$method $path" in
  "GET /accounts") emit '{"result":[{"id":"acct-TEST"}]}' 200;;
  "GET /zones")    emit '{"result":[{"id":"zone-TEST"}]}' 200;;
  "GET /accounts/acct-TEST/cfd_tunnel")
    # scope probe uses -w (want code); existence check parses JSON
    if [ "${CF_SCOPE_403:-0}" = 1 ]; then emit '{"success":false}' 403; exit 0; fi
    name="$(printf '%s' "$q" | sed -n 's/.*name=\([^&]*\).*/\1/p')"
    if [ -n "$name" ] && [ -f "$S/tunnels/$name" ]; then emit "{\"result\":[{\"id\":\"$(cat "$S/tunnels/$name")\"}]}" 200
    else emit '{"result":[]}' 200; fi;;
  "POST /accounts/acct-TEST/cfd_tunnel")
    [ "${CF_SCOPE_403:-0}" = 1 ] && { echo '{"success":false,"errors":[{"code":9109}],"messages":["Forbidden"]}'; exit 0; }
    name="$(printf '%s' "$data" | jq -r .name)"; id="tid-$name"; printf '%s' "$id" > "$S/tunnels/$name"
    echo "{\"result\":{\"id\":\"$id\",\"token\":\"APITOKENVALUE-$name\"}}";;
  "PUT /accounts/acct-TEST/cfd_tunnel/"*"/configurations") tid="${path%/configurations}"; tid="${tid##*/}"; printf '%s' "$data" > "$S/config-$tid"; echo '{"result":{}}';;
  "DELETE /accounts/acct-TEST/cfd_tunnel/"*) tid="${path##*/}"; for f in "$S/tunnels"/*; do [ -e "$f" ]||continue; [ "$(cat "$f")" = "$tid" ] && rm -f "$f"; done; echo '{"result":null}';;
  "GET /zones/zone-TEST/dns_records") n="$(printf '%s' "$q" | sed -n 's/.*name=\([^&]*\).*/\1/p')"; [ -f "$S/dns/$n" ] && echo "{\"result\":[{\"id\":\"rec-$n\"}]}" || echo '{"result":[]}';;
  "POST /zones/zone-TEST/dns_records") n="$(printf '%s' "$data" | jq -r .name)"; : > "$S/dns/$n"; echo '{"result":{"id":"rec-new"}}';;
  "DELETE /zones/zone-TEST/dns_records/"*) rid="${path##*/}"; n="${rid#rec-}"; rm -f "$S/dns/$n" 2>/dev/null; echo '{"result":null}';;
  *) echo "curl-stub: unhandled $method $path" >&2; exit 22;;
esac
EOF
chmod +x "$STUB/curl"

# --- B2: happy CLI path (cert.pem present) → ok + ingress config.yml --------------------
mkdir -p "$TMP/home/.cloudflared"; : > "$TMP/home/.cloudflared/cert.pem"
OK="$(printf '%s' "$REQ" | INGRESS_CURL="$STUB/curl" HOME="$TMP/home" bash "$SH" provision --apply)"
chk "cli apply → ok"                           "[ \"\$(printf '%s' \"\$OK\" | j .status)\" = 'ok' ]"
chk "cli token file 0600"                       "[ \"\$(stat -c '%a' \"$INGRESS_TOKEN_DIR/ingress-track-42.env\")\" = '600' ]"
chk "token VALUE not in response"               "! printf '%s' \"\$OK\" | grep -q \"$TOKEN_VALUE\""
chk "cli ingress config.yml written"            "[ -f \"$INGRESS_TOKEN_DIR/ingress-track-42.config.yml\" ]"
chk "cli config maps host -> target"            "grep -q 'service: http://127.0.0.1:8931' \"$INGRESS_TOKEN_DIR/ingress-track-42.config.yml\""
IDEM="$(printf '%s' "$REQ" | INGRESS_CURL="$STUB/curl" HOME="$TMP/home" bash "$SH" provision --apply)"
chk "cli re-provision → exists"                 "[ \"\$(printf '%s' \"\$IDEM\" | j .status)\" = 'exists' ]"
DEP="$(printf '%s' "$REQ" | INGRESS_CURL="$STUB/curl" HOME="$TMP/home" bash "$SH" deprovision --apply)"
chk "cli deprovision → ok"                       "[ \"\$(printf '%s' \"\$DEP\" | j .status)\" = 'ok' ]"
chk "cli token removed"                          "[ ! -f \"$INGRESS_TOKEN_DIR/ingress-track-42.env\" ]"

# --- B3: API path via Option-A token AUTO-READ (no CLOUDFLARED_API_TOKEN, no cert) ------
api() { env -u CLOUDFLARED_API_TOKEN API_STATE="$API_STATE" INGRESS_CURL="$STUB/curl" \
          INGRESS_DNS_MODE=api INGRESS_TUNNEL_MODE=api HOME="$TMP/nohome" bash "$SH" "$@"; }
mkdir -p "$TMP/nohome"
APIOK="$(printf '%s' "$REQ" | api provision --apply)"
chk "api apply (ini token auto-read) → ok"      "[ \"\$(printf '%s' \"\$APIOK\" | j .status)\" = 'ok' ]"
chk "api created tunnel"                         "[ -f \"$API_STATE/tunnels/ingress-track-42\" ]"
chk "api configured ingress rule"               "[ -f \"$API_STATE/config-tid-ingress-track-42\" ]"
chk "api ingress maps host -> target"           "jq -e '.config.ingress[0].service==\"http://127.0.0.1:8931\"' \"$API_STATE/config-tid-ingress-track-42\" >/dev/null"
chk "api token value not in response"           "! printf '%s' \"\$APIOK\" | grep -q 'APITOKENVALUE'"
DEPI="$(printf '%s' "$REQ" | api deprovision --apply)"
chk "api deprovision → ok"                        "[ \"\$(printf '%s' \"\$DEPI\" | j .status)\" = 'ok' ]"

# --- B4: token present but LACKS tunnel scope → blocked_scope (plan probe + apply 403) --
SP="$(printf '%s' "$REQ" | env -u CLOUDFLARED_API_TOKEN CF_SCOPE_403=1 API_STATE="$API_STATE" INGRESS_CURL="$STUB/curl" INGRESS_TUNNEL_MODE=api HOME="$TMP/nohome" bash "$SH" provision --plan | j .status)"
chk "plan: token w/o tunnel scope → blocked_scope" "[ \"$SP\" = 'blocked_scope' ]"
SA="$(printf '%s' "$REQ" | env -u CLOUDFLARED_API_TOKEN CF_SCOPE_403=1 API_STATE="$API_STATE" INGRESS_CURL="$STUB/curl" INGRESS_TUNNEL_MODE=api HOME="$TMP/nohome" bash "$SH" provision --apply | j .status)"
chk "apply: token w/o tunnel scope → blocked_scope" "[ \"$SA\" = 'blocked_scope' ]"

# ========================================================================================
echo "== C. validation (tunnel mode) =="
V(){ printf '%s' "$1" | INGRESS_CURL="$STUB/curl" HOME="$TMP/home" bash "$SH" provision --plan | j .status; }
chk "wrong zone → invalid"        "[ \"\$(V '{\"hostname\":\"evil.example.com\",\"target\":\"127.0.0.1:80\"}')\" = 'invalid' ]"
chk "non-loopback target → invalid" "[ \"\$(V '{\"hostname\":\"ok.concierge-dev.app\",\"target\":\"10.0.0.5:80\"}')\" = 'invalid' ]"
chk "bad port → invalid"          "[ \"\$(V '{\"hostname\":\"ok.concierge-dev.app\",\"target\":\"127.0.0.1:nope\"}')\" = 'invalid' ]"
chk "non-JSON → invalid"          "[ \"\$(V 'not json')\" = 'invalid' ]"
chk "bare apex → invalid"         "[ \"\$(V '{\"hostname\":\"concierge-dev.app\",\"target\":\"127.0.0.1:80\"}')\" = 'invalid' ]"

# ========================================================================================
echo "== D. owner-confirm gate (tunnel) =="
CF2="$TMP/cfstate2"; mkdir -p "$CF2"
NC="$(printf '%s' "$REQ" | env -u INGRESS_APPLY_CONFIRM CF_STATE="$CF2" INGRESS_CURL="$STUB/curl" HOME="$TMP/home" bash "$SH" provision --apply | j .status)"
chk "unconfirmed --apply → blocked_confirm"     "[ \"$NC\" = 'blocked_confirm' ]"
chk "unconfirmed --apply created NO tunnel"     "[ \"\$(ls \"$CF2\" | wc -l | tr -d ' ')\" = '0' ]"
NCP="$(printf '%s' "$REQ" | env -u INGRESS_APPLY_CONFIRM CF_STATE="$CF2" INGRESS_CURL="$STUB/curl" HOME="$TMP/home" bash "$SH" provision --plan | j .status)"
chk "--plan needs no confirmation"              "[ \"$NCP\" != 'blocked_confirm' ]"

# ========================================================================================
echo "== E. per-project config (mode + zone from .claude/agent/config.json) =="
PROJ2="$TMP/proj2"; mkdir -p "$PROJ2/.claude/agent"
cat > "$PROJ2/.claude/agent/config.json" <<EOF
{ "ingress": { "mode": "haproxy", "zone": "apps.example.net", "haproxy_host": "hp2" } }
EOF
cfg() { env -u INGRESS_MODE -u INGRESS_ZONE -u INGRESS_HAPROXY_HOST -u INGRESS_TOKEN_DIR -u INGRESS_SECRETS_DIR -u INGRESS_CF_INI \
          INGRESS_PROJECT_DIR="$PROJ2" INGRESS_CURL="$STUB/curl-haproxy-post" HP_STATE="$HP_STATE" bash "$SH" "$@"; }
CM="$(printf '{"hostname":"foo.apps.example.net","target":"c1:80"}' | cfg provision --plan)"
chk "config selects haproxy mode"               "[ \"\$(printf '%s' \"\$CM\" | j .mode)\" = 'haproxy' ]"
chk "config zone accepted"                       "[ \"\$(printf '%s' \"\$CM\" | j .status)\" != 'invalid' ]"
CMB="$(printf '{"hostname":"foo.concierge-dev.app","target":"c1:80"}' | cfg provision --plan | j .status)"
chk "default zone rejected when config overrides" "[ \"$CMB\" = 'invalid' ]"

echo
if [ "$FAIL" = 0 ]; then printf '\033[32mALL PASS\033[0m\n'; else printf '\033[31mSOME FAILED\033[0m\n'; fi
exit $FAIL
