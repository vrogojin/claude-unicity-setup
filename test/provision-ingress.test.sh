#!/usr/bin/env bash
# provision-ingress.test.sh — hermetic contract test for the provision-ingress verb backend.
#
# Proves, with cloudflared + the Cloudflare API fully STUBBED (no network, no real tunnels):
#   • the JSON response contract: always {hostname, connector_token_path, tunnel_name, status}
#   • input validation: zone-escape, non-loopback target, bad port, non-JSON → status:invalid
#   • deterministic + idempotent tunnel-name derivation
#   • the KNOWN scope gap → status:blocked_scope with remediation (never faked success)
#   • idempotency: an existing tunnel+token → status:exists (no duplicate)
#   • apply provisions end-to-end when the create path is available (stubbed cert.pem)
#   • the connector TOKEN VALUE never appears in the response; token file is 0600
#   • deprovision removes tunnel + CNAME + token file
#
# Run:  bash test/provision-ingress.test.sh
set -uo pipefail

FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }
chk()  { if eval "$2"; then pass "$1"; else fail "$1 — [$2]"; fi; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SH="$REPO/claude_conf/hooks/provision-ingress.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/provingress.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- Hermetic env ------------------------------------------------------------------------
export INGRESS_PROJECT_DIR="$TMP/proj"
export INGRESS_SECRETS_DIR="$TMP/proj/.secrets"
export INGRESS_TOKEN_DIR="$TMP/proj/.secrets/ingress"
export INGRESS_CF_INI="$TMP/proj/.secrets/staging-tls/cloudflare.ini"
export INGRESS_ZONE="concierge-dev.app"
export INGRESS_DNS_MODE="skip"       # do not touch the Cloudflare API
export INGRESS_SUPERVISOR="none"     # do not touch systemd
export HOME="$TMP/home"              # controls whether cert.pem "exists"
mkdir -p "$INGRESS_TOKEN_DIR" "$TMP/proj/.secrets/staging-tls" "$HOME"
printf 'dns_cloudflare_api_token = testtoken\n' > "$INGRESS_CF_INI"

# --- Stub cloudflared. State dir tracks "created" tunnels so list/token/delete cohere. ---
STUB="$TMP/bin"; mkdir -p "$STUB"
export CF_STATE="$TMP/cfstate"; mkdir -p "$CF_STATE"
cat > "$STUB/cloudflared" <<'EOF'
#!/usr/bin/env bash
# Minimal cloudflared stub driven by env:
#   CF_STATE            dir of created tunnel marker files
#   CF_CREATE_FAILS=1   make `tunnel create` fail with an AUTH error (scope gap)
set -u
sub="${1:-}"; act="${2:-}"
case "$sub $act" in
  "--version "*|"--version") echo "cloudflared version 0.0.0-stub"; exit 0;;
  "tunnel create")
    name="$3"
    if [ "${CF_CREATE_FAILS:-0}" = "1" ]; then
      echo "failed to create tunnel: Unauthorized: cert.pem not found / please run cloudflared tunnel login" >&2
      exit 1
    fi
    : > "$CF_STATE/$name"; echo "Created tunnel $name with id 00000000-0000-4000-8000-000000000000"; exit 0;;
  "tunnel list")
    # supports:  tunnel list --name NAME --output json   |  tunnel list --output json
    name=""; while [ $# -gt 0 ]; do [ "$1" = "--name" ] && name="${2:-}"; shift; done
    if [ -n "$name" ]; then
      if [ -f "$CF_STATE/$name" ]; then
        printf '[{"id":"00000000-0000-4000-8000-000000000000","name":"%s"}]' "$name"
      else printf '[]'; fi
    else
      printf '['; first=1; for f in "$CF_STATE"/*; do [ -e "$f" ] || continue; b="$(basename "$f")"; [ $first = 1 ] || printf ','; first=0; printf '{"id":"00000000-0000-4000-8000-000000000000","name":"%s"}' "$b"; done; printf ']'
    fi
    exit 0;;
  "tunnel token") echo "eyJTdHViQ29ubmVjdG9yVG9rZW5WYWx1ZSJ9"; exit 0;;
  "tunnel delete") dn="${!#}"; rm -f "$CF_STATE/$dn" 2>/dev/null; echo "Deleted $dn"; exit 0;;
  "tunnel route") echo "route ok"; exit 0;;
  *) echo "stub: unhandled: $*" >&2; exit 1;;
esac
EOF
chmod +x "$STUB/cloudflared"
export CLOUDFLARED_BIN="$STUB/cloudflared"

REQ='{"hostname":"track-42.concierge-dev.app","target":"127.0.0.1:8931","purpose":"spawned track","ttl_hint":"6h"}'
TOKEN_VALUE="eyJTdHViQ29ubmVjdG9yVG9rZW5WYWx1ZSJ9"

j() { jq -r "$1"; }   # read a field from a captured response

# ========================================================================================
echo "— contract shape + canonical fields —"
OUT="$(printf '%s' "$REQ" | HOME="$TMP/home" bash "$SH" provision --plan)"
chk "response is a single JSON object"          "printf '%s' \"\$OUT\" | jq -e 'type==\"object\"' >/dev/null"
chk "has hostname key"                          "printf '%s' \"\$OUT\" | jq -e 'has(\"hostname\")' >/dev/null"
chk "has connector_token_path key"              "printf '%s' \"\$OUT\" | jq -e 'has(\"connector_token_path\")' >/dev/null"
chk "has tunnel_name key"                        "printf '%s' \"\$OUT\" | jq -e 'has(\"tunnel_name\")' >/dev/null"
chk "has status key"                            "printf '%s' \"\$OUT\" | jq -e 'has(\"status\")' >/dev/null"
chk "tunnel_name derived deterministically"     "[ \"\$(printf '%s' \"\$OUT\" | j .tunnel_name)\" = 'ingress-track-42' ]"
chk "token path under .secrets/ingress 0600 loc" "printf '%s' \"\$OUT\" | j .connector_token_path | grep -q '/.secrets/ingress/ingress-track-42.env'"

# ========================================================================================
echo "— scope gap: no cert.pem, no api token → blocked_scope —"
chk "plan with no create path → blocked_scope"  "[ \"\$(printf '%s' \"\$OUT\" | j .status)\" = 'blocked_scope' ]"
chk "blocked_scope carries remediation (2 opts)" "printf '%s' \"\$OUT\" | jq -e '.remediation|length==2' >/dev/null"
chk "remediation names the token-scope fix"      "printf '%s' \"\$OUT\" | jq -e '.remediation|any(test(\"Cloudflare Tunnel\"))' >/dev/null"
chk "remediation names the login fix"            "printf '%s' \"\$OUT\" | jq -e '.remediation|any(test(\"tunnel login\"))' >/dev/null"

OUT_APPLY="$(printf '%s' "$REQ" | HOME="$TMP/home" bash "$SH" provision --apply)"
chk "apply with no create path → blocked_scope"  "[ \"\$(printf '%s' \"\$OUT_APPLY\" | j .status)\" = 'blocked_scope' ]"
chk "blocked apply creates NO token file"         "[ ! -f \"$INGRESS_TOKEN_DIR/ingress-track-42.env\" ]"

# ========================================================================================
echo "— create path fails on auth (CF_CREATE_FAILS) → blocked_scope, never faked —"
mkdir -p "$TMP/home/.cloudflared"; : > "$TMP/home/.cloudflared/cert.pem"
OUT_AF="$(printf '%s' "$REQ" | CF_CREATE_FAILS=1 HOME="$TMP/home" bash "$SH" provision --apply)"
chk "cloudflared create-fail → blocked_scope"    "[ \"\$(printf '%s' \"\$OUT_AF\" | j .status)\" = 'blocked_scope' ]"
chk "create-fail creates NO token file"           "[ ! -f \"$INGRESS_TOKEN_DIR/ingress-track-42.env\" ]"

# ========================================================================================
echo "— happy path: cert.pem present, create succeeds → ok —"
OUT_OK="$(printf '%s' "$REQ" | HOME="$TMP/home" bash "$SH" provision --apply)"
chk "apply → status ok"                          "[ \"\$(printf '%s' \"\$OUT_OK\" | j .status)\" = 'ok' ]"
chk "token file created"                          "[ -f \"$INGRESS_TOKEN_DIR/ingress-track-42.env\" ]"
chk "token file is 0600"                          "[ \"\$(stat -c '%a' \"$INGRESS_TOKEN_DIR/ingress-track-42.env\")\" = '600' ]"
chk "token VALUE not in response"                 "! printf '%s' \"\$OUT_OK\" | grep -q \"$TOKEN_VALUE\""
chk "token file DOES hold the value (0600 path)"  "grep -q \"$TOKEN_VALUE\" \"$INGRESS_TOKEN_DIR/ingress-track-42.env\""

# ========================================================================================
echo "— idempotency: re-provision existing → exists, no duplicate —"
OUT_IDEM="$(printf '%s' "$REQ" | HOME="$TMP/home" bash "$SH" provision --apply)"
chk "re-provision → status exists"               "[ \"\$(printf '%s' \"\$OUT_IDEM\" | j .status)\" = 'exists' ]"
chk "still exactly one tunnel marker"             "[ \"\$(ls \"$CF_STATE\" | wc -l | tr -d ' ')\" = '1' ]"

# ========================================================================================
echo "— input validation → status invalid —"
BADZONE="$(printf '{\"hostname\":\"evil.example.com\",\"target\":\"127.0.0.1:80\"}' | HOME="$TMP/home" bash "$SH" provision --plan | j .status)"
chk "wrong zone → invalid"                        "[ \"$BADZONE\" = 'invalid' ]"
BADHOST="$(printf '{\"hostname\":\"ok.concierge-dev.app\",\"target\":\"10.0.0.5:80\"}' | HOME="$TMP/home" bash "$SH" provision --plan | j .status)"
chk "non-loopback target → invalid"               "[ \"$BADHOST\" = 'invalid' ]"
BADPORT="$(printf '{\"hostname\":\"ok.concierge-dev.app\",\"target\":\"127.0.0.1:nope\"}' | HOME="$TMP/home" bash "$SH" provision --plan | j .status)"
chk "bad port → invalid"                          "[ \"$BADPORT\" = 'invalid' ]"
BADJSON="$(printf 'not json' | HOME="$TMP/home" bash "$SH" provision --plan | j .status)"
chk "non-JSON body → invalid"                     "[ \"$BADJSON\" = 'invalid' ]"
APEX="$(printf '{\"hostname\":\"concierge-dev.app\",\"target\":\"127.0.0.1:80\"}' | HOME="$TMP/home" bash "$SH" provision --plan | j .status)"
chk "bare zone apex → invalid"                     "[ \"$APEX\" = 'invalid' ]"

# ========================================================================================
echo "— deprovision: removes tunnel + token, idempotent —"
OUT_DEP="$(printf '%s' "$REQ" | HOME="$TMP/home" bash "$SH" deprovision --apply)"
chk "deprovision → status ok"                     "[ \"\$(printf '%s' \"\$OUT_DEP\" | j .status)\" = 'ok' ]"
chk "token file removed"                          "[ ! -f \"$INGRESS_TOKEN_DIR/ingress-track-42.env\" ]"
chk "tunnel marker removed"                       "[ \"\$(ls \"$CF_STATE\" | wc -l | tr -d ' ')\" = '0' ]"
OUT_DEP2="$(printf '%s' "$REQ" | HOME="$TMP/home" bash "$SH" deprovision --apply)"
chk "deprovision again → not_found (idempotent)"  "[ \"\$(printf '%s' \"\$OUT_DEP2\" | j .status)\" = 'not_found' ]"

# ========================================================================================
echo "— API path (owner fix A): no cert.pem, account-scoped token → real API lifecycle —"
# Fresh hermetic sub-scope with a stubbed Cloudflare API (curl) + tunnel/dns state.
API_STATE="$TMP/apistate"; mkdir -p "$API_STATE/tunnels" "$API_STATE/dns"
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
# Minimal Cloudflare API stub. Understands the exact endpoints provision-ingress.sh calls.
set -u
method=GET; url=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift;;
    --data) data="$2"; shift;;
    http*://*) url="$1";;
  esac; shift
done
S="${API_STATE:?}"
path="${url#*client/v4}"; path="${path%%\?*}"; q="${url#*\?}"
case "$method $path" in
  "GET /accounts") echo '{"result":[{"id":"acct-TEST"}]}';;
  "GET /zones")    echo '{"result":[{"id":"zone-TEST"}]}';;
  "GET /accounts/acct-TEST/cfd_tunnel")
    name="$(printf '%s' "$q" | sed -n 's/.*name=\([^&]*\).*/\1/p')"
    if [ -f "$S/tunnels/$name" ]; then echo "{\"result\":[{\"id\":\"$(cat "$S/tunnels/$name")\"}]}"; else echo '{"result":[]}'; fi;;
  "POST /accounts/acct-TEST/cfd_tunnel")
    name="$(printf '%s' "$data" | jq -r .name)"; id="tid-$name"
    printf '%s' "$id" > "$S/tunnels/$name"
    echo "{\"result\":{\"id\":\"$id\",\"token\":\"APITOKENVALUE-$name\"}}";;
  "DELETE /accounts/acct-TEST/cfd_tunnel/"*)
    tid="${path##*/}"; for f in "$S/tunnels"/*; do [ -e "$f" ] || continue; [ "$(cat "$f")" = "$tid" ] && rm -f "$f"; done; echo '{"result":null}';;
  "GET /zones/zone-TEST/dns_records")
    n="$(printf '%s' "$q" | sed -n 's/.*name=\([^&]*\).*/\1/p')"
    if [ -f "$S/dns/$n" ]; then echo "{\"result\":[{\"id\":\"rec-$n\"}]}"; else echo '{"result":[]}'; fi;;
  "POST /zones/zone-TEST/dns_records") n="$(printf '%s' "$data" | jq -r .name)"; : > "$S/dns/$n"; echo '{"result":{"id":"rec-new"}}';;
  "PUT /zones/zone-TEST/dns_records/"*) echo '{"result":{"id":"rec-upd"}}';;
  "DELETE /zones/zone-TEST/dns_records/"*) rid="${path##*/}"; n="${rid#rec-}"; rm -f "$S/dns/$n" 2>/dev/null; echo '{"result":null}';;
  *) echo "curl-stub: unhandled $method $path" >&2; exit 22;;
esac
EOF
chmod +x "$STUB/curl"

api_run() { # runs the hook in API mode (no cert.pem, account token set), stubbed curl
  API_STATE="$API_STATE" INGRESS_CURL="$STUB/curl" INGRESS_DNS_MODE=api \
    INGRESS_TUNNEL_MODE=api CLOUDFLARED_API_TOKEN=acct-scoped-tok HOME="$TMP/nohomecert" \
    bash "$SH" "$@"
}
mkdir -p "$TMP/nohomecert"   # deliberately NO ~/.cloudflared/cert.pem here
OUT_API="$(printf '%s' "$REQ" | api_run provision --apply)"
chk "API apply → ok"                              "[ \"\$(printf '%s' \"\$OUT_API\" | j .status)\" = 'ok' ]"
chk "API created tunnel via /cfd_tunnel"          "[ -f \"$API_STATE/tunnels/ingress-track-42\" ]"
chk "API created the CNAME record"                "[ -f \"$API_STATE/dns/track-42.concierge-dev.app\" ]"
chk "API token file 0600"                          "[ \"\$(stat -c '%a' \"$INGRESS_TOKEN_DIR/ingress-track-42.env\")\" = '600' ]"
chk "API token value not in response"             "! printf '%s' \"\$OUT_API\" | grep -q 'APITOKENVALUE'"
OUT_API2="$(printf '%s' "$REQ" | api_run provision --apply)"
chk "API re-provision → exists (idempotent)"      "[ \"\$(printf '%s' \"\$OUT_API2\" | j .status)\" = 'exists' ]"
OUT_APIDEP="$(printf '%s' "$REQ" | api_run deprovision --apply)"
chk "API deprovision → ok"                        "[ \"\$(printf '%s' \"\$OUT_APIDEP\" | j .status)\" = 'ok' ]"
chk "API tunnel removed"                          "[ ! -f \"$API_STATE/tunnels/ingress-track-42\" ]"
chk "API CNAME removed"                            "[ ! -f \"$API_STATE/dns/track-42.concierge-dev.app\" ]"

echo
if [ "$FAIL" = 0 ]; then printf '\033[32mALL PASS\033[0m\n'; else printf '\033[31mSOME FAILED\033[0m\n'; fi
exit $FAIL
