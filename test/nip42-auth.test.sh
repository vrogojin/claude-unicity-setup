#!/bin/bash
# Hermetic self-test for NIP-42 relay authentication on the sphere-helper RAW WebSocket paths
# (relay-fetch / relay-publish — the same auth machine also backs check-messages / watch). It
# stands up a minimal relay stub (test/nip42-relay-stub.mjs) that ENFORCES NIP-42: it gates
# every REQ/EVENT behind a schnorr-verified kind-22242 AUTH echoing its own challenge. The suite
# proves the property the A2A coord-harvest fix depends on:
#   • WITH an identity, the helper authenticates and the relay serves it.
#   • WITHOUT an identity, an anonymous client is GATED — it reads nothing / cannot publish.
#   • A FORGED AUTH (tampered signature) is rejected, so the gate is real, not cosmetic.
#   • Both AUTH orderings work: proactive (challenge on connect) and reactive (CLOSED→challenge).
# Real crypto is exercised, so a resolvable node_modules is required (SKIP otherwise, like the
# sibling suites).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
HELPER="$REPO/lib/sphere-helper.mjs"
STUB="$REPO/test/nip42-relay-stub.mjs"
FORGE="$REPO/test/nip42-forge-client.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

SBX="$(mktemp -d)"
STUB_PIDS=()
cleanup() { for p in "${STUB_PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$SBX"; }
trap cleanup EXIT

cd "$REPO"  # ESM resolves @unicitylabs/* by walking up from the helper dir → worktree node_modules
node "$HELPER" create-identity > "$SBX/id.json" 2>/dev/null
if ! jq -e .npub "$SBX/id.json" >/dev/null 2>&1; then
  echo "SKIP: sphere-helper/SDK not resolvable (node_modules missing) — cannot run NIP-42 crypto test"; exit 0
fi

# A stored kind-30777 event (d = sha256(secret)) built by the helper's own signer.
SECRET="ut2_$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 43)"
DTAG="$(printf '%s' "$SECRET" | sha256sum | awk '{print $1}')"
SIGNIN="$(jq -nc --arg s "$SECRET" '{secret:$s, payload:{iss:"npub1stub", caps:["consult"]}}')"
printf '%s' "$SIGNIN" | node "$HELPER" ticket2-sign --identity "$SBX/id.json" > "$SBX/ev.json" 2>/dev/null
jq -s '.' "$SBX/ev.json" > "$SBX/store.json"
[ "$(jq 'length' "$SBX/store.json" 2>/dev/null)" = "1" ] || { echo "SETUP FAIL: could not build stored ticket event"; exit 1; }

# start_stub <mode> <store.json> <log> → echoes the ws:// URL
start_stub() {
  local mode="$1" store="$2" log="$3" urlf; urlf="$(mktemp)"
  node "$STUB" --store "$store" --mode "$mode" --events-log "$log" > "$urlf" 2>/dev/null &
  STUB_PIDS+=("$!")
  local url="" i=0
  while [ $i -lt 50 ]; do url="$(grep -o 'ws://[^ ]*' "$urlf" 2>/dev/null)"; [ -n "$url" ] && break; sleep 0.1; i=$((i+1)); done
  printf '%s' "$url"
}

echo "== NIP-42 relay AUTH — raw WebSocket read/write paths =="

# 1. Proactive relay: WITH identity → authenticates → reads the stored event.
LOG1="$SBX/log1.jsonl"; : > "$LOG1"
URL1="$(start_stub proactive "$SBX/store.json" "$LOG1")"
[ -n "$URL1" ] || bad "stub (proactive) did not start"
N="$(node "$HELPER" relay-fetch --relay "$URL1" --dtag "$DTAG" --identity "$SBX/id.json" 2>/dev/null | jq '.events|length' 2>/dev/null)"
[ "$N" = "1" ] && ok "relay-fetch WITH identity authenticates and reads (1 event)" || bad "relay-fetch WITH identity got '$N' events (want 1)"
grep -q '"ev":"auth","accepted":true' "$LOG1" && ok "stub verified our AUTH (kind-22242, challenge, schnorr sig)" || bad "stub did not record an accepted AUTH"

# 2. Proactive relay: WITHOUT identity → gated → reads nothing.
LOG2="$SBX/log2.jsonl"; : > "$LOG2"
URL2="$(start_stub proactive "$SBX/store.json" "$LOG2")"
N="$(node "$HELPER" relay-fetch --relay "$URL2" --dtag "$DTAG" 2>/dev/null | jq '.events|length' 2>/dev/null)"
[ "$N" = "0" ] && ok "relay-fetch WITHOUT identity is GATED (0 events — harvester shut out)" || bad "anonymous relay-fetch got '$N' events (want 0 — gate leaked!)"
grep -q '"ev":"auth"' "$LOG2" && bad "anonymous client somehow sent an AUTH" || ok "anonymous client never authenticated (no AUTH recorded)"

# 3. Reactive relay (AUTH only after a CLOSED auth-required): WITH identity still authenticates.
LOG3="$SBX/log3.jsonl"; : > "$LOG3"
URL3="$(start_stub reactive "$SBX/store.json" "$LOG3")"
N="$(node "$HELPER" relay-fetch --relay "$URL3" --dtag "$DTAG" --identity "$SBX/id.json" 2>/dev/null | jq '.events|length' 2>/dev/null)"
[ "$N" = "1" ] && ok "relay-fetch handles the reactive CLOSED→AUTH→resub path (1 event)" || bad "reactive relay-fetch got '$N' events (want 1)"

# 4. relay-publish WITH identity → authenticates → relay accepts the EVENT.
LOG4="$SBX/log4.jsonl"; : > "$LOG4"
URL4="$(start_stub proactive "$SBX/store2.json" "$LOG4")"   # empty store; publish adds to it
PUBSECRET="ut2_$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 43)"
PUBIN="$(jq -nc --arg s "$PUBSECRET" '{secret:$s, payload:{iss:"npub1pub", caps:["chat"]}}')"
PUBEV="$(printf '%s' "$PUBIN" | node "$HELPER" ticket2-sign --identity "$SBX/id.json" 2>/dev/null)"
PUBOUT="$(printf '%s' "$PUBEV" | node "$HELPER" relay-publish --relay "$URL4" --identity "$SBX/id.json" --timeout 5000 2>/dev/null)"
[ "$(printf '%s' "$PUBOUT" | jq -r '.published' 2>/dev/null)" = "true" ] && ok "relay-publish WITH identity authenticates and publishes" || bad "relay-publish WITH identity did not succeed ($PUBOUT)"
grep -q '"ev":"event-accepted"' "$LOG4" && ok "stub accepted the published EVENT after AUTH" || bad "stub never recorded event-accepted"

# 5. relay-publish WITHOUT identity → gated (relay rejects with auth-required).
LOG5="$SBX/log5.jsonl"; : > "$LOG5"
URL5="$(start_stub proactive "$SBX/store3.json" "$LOG5")"
PUBOUT2="$(printf '%s' "$PUBEV" | node "$HELPER" relay-publish --relay "$URL5" --timeout 3000 2>/dev/null)"
[ "$(printf '%s' "$PUBOUT2" | jq -r '.published // "false"' 2>/dev/null)" = "true" ] && bad "anonymous relay-publish SUCCEEDED (gate leaked!)" || ok "relay-publish WITHOUT identity is GATED (rejected)"
grep -q '"ev":"event-accepted"' "$LOG5" && bad "stub accepted an unauthenticated EVENT" || ok "stub never accepted the unauthenticated EVENT"

# 6. Adversarial: a FORGED AUTH (tampered signature) is rejected → REQ stays gated.
LOG6="$SBX/log6.jsonl"; : > "$LOG6"
URL6="$(start_stub proactive "$SBX/store.json" "$LOG6")"
FRES="$(node "$FORGE" "$URL6" "$DTAG" 2>/dev/null)"
[ "$(printf '%s' "$FRES" | jq -r '.events' 2>/dev/null)" = "0" ] && ok "forged AUTH is rejected — REQ stays gated (0 events)" || bad "forged AUTH leaked events ($FRES)"
[ "$(printf '%s' "$FRES" | jq -r '.okAccepted' 2>/dev/null)" = "false" ] && ok "relay signalled the forged AUTH as rejected (OK …,false)" || bad "relay did not reject the forged AUTH ($FRES)"
grep -q '"ev":"auth","accepted":false' "$LOG6" && ok "stub's schnorr check caught the tampered signature" || bad "stub did not record a rejected AUTH"

echo
echo "NIP-42 AUTH: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
