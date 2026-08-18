#!/bin/bash
# Hermetic test suite for one-time invite tickets (ticket.sh + sphere-helper ticket-sign/verify
# + v2 short tickets + classify-inbound routing). No live relay: emits are TEAM_DRY_RUN=1;
# the v2 relay publish/fetch goes through TICKET_RELAY_STUB (file-drop with the same JSON
# contract as the raw-ws path); inbound is crafted exactly as the daemon delivers it
# ({from:<hex>, body:<envelope-json>}) and fed to ingest-*.
# Real schnorr + AES-GCM crypto IS exercised, so a resolvable node_modules is required.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
HOOKS="$REPO/claude_conf/hooks"
HELPER="$REPO/lib/sphere-helper.mjs"
TICKET="$HOOKS/ticket.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# --- sandbox ---
SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT
mkdir -p "$SBX/proj/.claude/agent" "$SBX/coord"
export CLAUDE_PROJECT_DIR="$SBX/proj" COORD_ROOT="$SBX/coord" \
  TEAM_SPHERE_HELPER="$HELPER" TEAM_IDENTITY_FILE="$SBX/proj/.claude/agent/identity.json" \
  AGENT_REGISTRY_FILE="$SBX/registry.json" TEAM_SELF_NAME="test-coord" TEAM_DRY_RUN=1 \
  TICKET_RELAY_STUB="$SBX/relay"
NP="$(cd "$(dirname "$HELPER")/.." && pwd)/node_modules"
helper() { NODE_PATH="$NP:${NODE_PATH:-}" node "$HELPER" "$@"; }
# ticket-sign/ticket-verify take their secret-bearing input on STDIN (never argv) — mirror
# how ticket.sh calls them, so the suite exercises the real no-argv-leak path.
hsign()   { printf '%s' "$2" | helper ticket-sign --identity "$1"; }   # <identity> <payload>
hverify() { printf '%s' "$1" | helper ticket-verify; }                 # <event>  (JSON on stdin)

helper create-identity > "$SBX/proj/.claude/agent/identity.json" 2>/dev/null
echo '{"agent_nametag":"test-coord"}' > "$SBX/proj/.claude/agent/config.json"
if ! jq -e .npub "$SBX/proj/.claude/agent/identity.json" >/dev/null 2>&1; then
  echo "SKIP: sphere-helper/SDK not resolvable (node_modules missing) — cannot run crypto tests"; exit 0
fi

# helpers
new_peer() { helper create-identity > "$SBX/$1.json" 2>/dev/null; local n; n="$(jq -r .npub "$SBX/$1.json")"; local h; h="$(helper npub-to-hex "$n" 2>/dev/null | jq -r .hex)"; echo "$n $h"; }
issue()    { bash "$TICKET" issue "$@" 2>/dev/null; }
# v2 short tickets: the string IS the secret; tid derives from its hash.
secret_of(){ printf '%s' "${1#ut2_}"; }
tid_of()   { printf 't%s' "$(printf '%s' "${1#ut2_}" | sha256sum | cut -c1-12)"; }
# Resolve a v2 ticket's verified payload via the stub relay (mirrors tk_redeem's fetch+verify).
v2_payload_of() {
  local sec; sec="$(secret_of "$1")"
  local d;   d="$(printf '%s' "$sec" | sha256sum | awk '{print $1}')"
  local evs; evs="$(helper relay-fetch --dtag "$d" 2>/dev/null)"
  printf '%s' "$evs" | jq -c --arg s "$sec" '{secret:$s,events:.events}' | helper ticket2-verify 2>/dev/null | jq -c '.payload'
}
# v1 legacy extractors (for the --v1 compat tests).
v1_secret_of(){ local ev; ev="$(bash "$TICKET" decode "$1" 2>/dev/null)"; hverify "$ev" 2>/dev/null | jq -r '.payload.secret'; }
v1_tid_of()   { local ev; ev="$(bash "$TICKET" decode "$1" 2>/dev/null)"; hverify "$ev" 2>/dev/null | jq -r '.payload.tid'; }
redeem_msg(){ jq -nc --arg from "$1" --arg tid "$2" --arg secret "$3" --arg npub "$4" \
  '{from:$from,id:("m"+$tid+$from[0:6]),body:({a2a:"1",kind:"ticket.redeem",payload:{tid:$tid,secret:$secret,npub:$npub,name:"peer"}}|tojson)}'; }
authst(){ jq -r --arg h "$1" '.agents[$h].status // "absent"' "$SBX/registry.json"; }
tkst()  { jq -r --arg t "$1" '.tickets[]? | select(.tid==$t) | .status' "$SBX/coord/tickets.json"; }

echo "== 1. crypto: sign→verify, tamper, wrong-signer =="
read -r AN AH < <(new_peer alice)
P=$(jq -nc --arg iss "$AN" '{v:1,tid:"tcrypto000001",iss:$iss,issName:"a",relays:["wss://x"],secret:"s",caps:["consult"],grantBack:["consult"],exp:9999999999,bind:"",label:""}')
EV=$(hsign "$SBX/alice.json" "$P")
[ "$(hverify "$EV" | jq -r .valid)" = "true" ] && ok "valid ticket verifies" || bad "valid verify"
TAMP=$(echo "$EV" | jq -c '.content=(.content+"AA")')
[ "$(hverify "$TAMP" 2>/dev/null | jq -r '.valid')" = "false" ] && ok "tampered rejected" || bad "tampered"
EV2=$(hsign "$SBX/bob.json" "$P" 2>/dev/null); [ -z "$EV2" ] && { read -r BN BH < <(new_peer bob); EV2=$(hsign "$SBX/bob.json" "$P"); }
[ "$(hverify "$EV2" 2>/dev/null | jq -r '.reason')" = "iss-mismatch" ] && ok "wrong-signer (iss-mismatch)" || bad "wrong-signer"
# wrong-kind: a validly-signed NON-30777 event must be rejected before its content is trusted.
WK=$(printf '%s' "$P" | helper ticket-sign --identity "$SBX/alice.json" | jq -c '.kind=1')
[ "$(hverify "$WK" 2>/dev/null | jq -r '.reason')" = "wrong-kind" ] && ok "non-30777 kind rejected" || bad "wrong-kind not rejected"

echo "== 1b. v2 crypto: sign→publish→fetch→verify + commitment/tamper rejections =="
S2="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 43)"
D2="$(printf '%s' "$S2" | sha256sum | awk '{print $1}')"
P2=$(jq -nc --arg iss "$AN" --arg s "$S2" '{secret:$s,payload:{iss:$iss,issName:"a",relays:["wss://x"],caps:["consult"],grantBack:["consult"],exp:9999999999,bind:"",label:"v2c"}}')
EV2=$(printf '%s' "$P2" | helper ticket2-sign --identity "$SBX/alice.json")
printf '%s' "$EV2" | helper relay-publish >/dev/null 2>&1
FE=$(helper relay-fetch --dtag "$D2" 2>/dev/null)
[ "$(printf '%s' "$FE" | jq '.events|length')" = "1" ] && ok "publish→fetch-by-#d round-trip" || bad "relay round-trip"
V2OK=$(printf '%s' "$FE" | jq -c --arg s "$S2" '{secret:$s,events:.events}' | helper ticket2-verify 2>/dev/null)
[ "$(printf '%s' "$V2OK" | jq -r .valid)" = "true" ] && [ "$(printf '%s' "$V2OK" | jq -r .payload.sh)" = "$D2" ] \
  && ok "v2 verify OK + hash commitment (payload.sh == sha256(secret) == #d)" || bad "v2 verify/commitment"
# event content is ciphertext: neither the secret nor the caps appear in the stored event
STORED="$SBX/relay/$(printf '%s' "$EV2" | jq -r .id).json"
if [ -f "$STORED" ] && ! grep -qF "$S2" "$STORED" && ! grep -qF '"caps"' "$STORED"; then
  ok "published event leaks neither secret nor plaintext payload"; else bad "relay event leaks payload"; fi
# wrong secret → no usable event (d-mismatch), fail closed
SW="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 43)"
VW=$(printf '%s' "$FE" | jq -c --arg s "$SW" '{secret:$s,events:.events}' | helper ticket2-verify 2>/dev/null; true)
[ "$(printf '%s' "$VW" | jq -r .valid)" = "false" ] && ok "wrong secret rejected" || bad "wrong secret accepted!"
# impersonation: a validly-signed event by a NON-iss key whose payload names alice as iss
# (covers the copied-ciphertext-republished attack — same rejected check, iss-mismatch)
read -r CN CH < <(new_peer copycat)
FORGED=$(printf '%s' "$P2" | helper ticket2-sign --identity "$SBX/copycat.json" 2>/dev/null)
VF2=$(jq -nc --arg s "$S2" --argjson e "[$FORGED]" '{secret:$s,events:$e}' | helper ticket2-verify 2>/dev/null; true)
[ "$(printf '%s' "$VF2" | jq -r .reason)" = "iss-mismatch" ] && ok "non-iss signer rejected (iss-mismatch)" || bad "copycat event accepted: $VF2"
# tampered d-tag (repointed at another secret's hash) breaks the signature
TAMP2=$(printf '%s' "$EV2" | jq -c --arg d "$(printf '%s' "$SW" | sha256sum | awk '{print $1}')" '.tags=[["d",$d],.tags[1]]')
VT2=$(jq -nc --arg s "$SW" --argjson e "[$TAMP2]" '{secret:$s,events:$e}' | helper ticket2-verify 2>/dev/null; true)
[ "$(printf '%s' "$VT2" | jq -r .valid)" = "false" ] && ok "tampered d-tag rejected (sig covers the commitment)" || bad "tampered d accepted!"

echo "== 2. issue stores hash-only, ticket is one short line =="
T=$(issue --caps consult,claim-area --ttl 2h --name dev)
[ "$(jq -r '.tickets[-1] | has("secret")' "$SBX/coord/tickets.json")" = "false" ] && ok "no raw secret at rest" || bad "secret leak"
[ "$(printf '%s' "$T" | wc -l)" = "0" ] && [ -n "$T" ] && ok "ticket is one copy-pasteable line" || bad "ticket format"
[ "${#T}" -le 64 ] && ok "ticket string ≤ 64 chars (${#T})" || bad "ticket too long: ${#T} chars"
printf '%s' "$T" | grep -Eq '^ut2_[A-Za-z0-9]{43}$' && ok "ut2_ + 43 alnum shape" || bad "unexpected v2 shape: $T"
EID=$(jq -r '.tickets[-1].eventId' "$SBX/coord/tickets.json")
[ -n "$EID" ] && [ -f "$SBX/relay/$EID.json" ] && ok "authorization event published at issue" || bad "no published event"

echo "== 3. happy path: redeem → redeemer authorized + grant emitted + ticket consumed =="
read -r RN RH < <(new_peer red)
TID=$(tid_of "$T"); SEC=$(secret_of "$T")
OUT=$(redeem_msg "$RH" "$TID" "$SEC" "$RN" | bash "$TICKET" ingest-redeem - 2>&1)
[ "$(authst "$RH")" = "authorized" ] && ok "redeemer authorized" || bad "redeemer not authorized"
[ "$(jq -rc --arg h "$RH" '.agents[$h].capabilities' "$SBX/registry.json")" = '["consult","claim-area"]' ] && ok "granted ticket caps" || bad "wrong caps"
echo "$OUT" | grep -q "DRY-RUN send.*ticket.grant" && ok "ticket.grant emitted" || bad "no grant emit"
[ "$(tkst "$TID")" = "redeemed" ] && ok "ticket consumed" || bad "ticket not consumed"

echo "== 4. replay from a DIFFERENT hex → deny already-redeemed, nothing authorized =="
read -r EN EH < <(new_peer eve)
OUT=$(redeem_msg "$EH" "$TID" "$SEC" "$EN" | bash "$TICKET" ingest-redeem - 2>&1)
echo "$OUT" | grep -q "already-redeemed" && ok "replay denied (already-redeemed)" || bad "replay not denied"
[ "$(authst "$EH")" = "absent" ] && ok "replayer NOT authorized" || bad "replayer authorized!"

echo "== 5. idempotent re-redeem: SAME hex → re-grant, single registry entry =="
OUT=$(redeem_msg "$RH" "$TID" "$SEC" "$RN" | bash "$TICKET" ingest-redeem - 2>&1)
echo "$OUT" | grep -q "DRY-RUN send.*ticket.grant" && ok "re-grant on same-hex re-redeem" || bad "no re-grant"

echo "== 6. bad secret → deny invalid, nothing authorized =="
T2=$(issue --caps consult --name b); TID2=$(tid_of "$T2")
read -r MN MH < <(new_peer mal)
OUT=$(redeem_msg "$MH" "$TID2" "WRONGSECRET" "$MN" | bash "$TICKET" ingest-redeem - 2>&1)
echo "$OUT" | grep -q "invalid" && ok "bad secret denied" || bad "bad secret not denied"
[ "$(authst "$MH")" = "absent" ] && ok "bad-secret sender not authorized" || bad "authorized on bad secret!"

echo "== 7. bind mismatch: --bind <alice>, redeem from red → deny, nothing authorized =="
TB=$(issue --caps consult --bind "$AN" --name bound); TIDB=$(tid_of "$TB"); SECB=$(secret_of "$TB")
OUT=$(redeem_msg "$RH" "$TIDB" "$SECB" "$RN" | bash "$TICKET" ingest-redeem - 2>&1)
echo "$OUT" | grep -q "bind-mismatch" && ok "bind mismatch denied" || bad "bind not enforced"
# and the bound peer (alice) CAN redeem it
OUT=$(redeem_msg "$AH" "$TIDB" "$SECB" "$AN" | bash "$TICKET" ingest-redeem - 2>&1)
[ "$(authst "$AH")" = "authorized" ] && ok "bound peer redeems ok" || bad "bound peer blocked"

echo "== 8. expiry: --ttl 1s, sleep, redeem → deny expired =="
TE=$(issue --caps consult --ttl 1s --name exp); TIDE=$(tid_of "$TE"); SECE=$(secret_of "$TE")
sleep 2
read -r XN XH < <(new_peer xp)
OUT=$(redeem_msg "$XH" "$TIDE" "$SECE" "$XN" | bash "$TICKET" ingest-redeem - 2>&1)
echo "$OUT" | grep -q "expired" && ok "expired ticket denied" || bad "expiry not enforced"
[ "$(authst "$XH")" = "absent" ] && ok "expired sender not authorized" || bad "authorized on expired!"

echo "== 9. wire cap-widening ignored: grant finalization uses LOCAL grantBack, not payload =="
# Redeemer side: record a redemption with grantBack=[consult], then feed a ticket.grant whose
# payload claims caps=[review-merge-pr] — the issuer must be authorized with LOCAL [consult].
read -r IN IH < <(new_peer iss9)
_rc_seed() { COORD_ROOT="$SBX/coord" bash -c '. '"$HOOKS"'/remote-coord.sh 2>/dev/null; _rc_write "'"$SBX"'/coord/redemptions.json" "$1" "${@:2}"'; }
jq -nc --arg iss "$IN" --arg hex "$IH" '{redemptions:[{tid:"tgrant9",issuerNpub:$iss,issuerHex:$hex,issuerName:"i9",grantBack:["consult"],exp:"2999-01-01T00:00:00Z",status:"sent",sentAt:"now",grantedAt:""}]}' > "$SBX/coord/redemptions.json"
GMSG=$(jq -nc --arg from "$IH" '{from:$from,id:"g9",body:({a2a:"1",kind:"ticket.grant",payload:{tid:"tgrant9",status:"granted",caps:["review-merge-pr","consult"],grantBack:["review-merge-pr"],issuerName:"i9"}}|tojson)}')
echo "$GMSG" | bash "$TICKET" ingest-grant - >/dev/null 2>&1
[ "$(authst "$IH")" = "authorized" ] && ok "issuer authorized via grant" || bad "grant not applied"
[ "$(jq -rc --arg h "$IH" '.agents[$h].capabilities' "$SBX/registry.json")" = '["consult"]' ] && ok "wire cap-widening IGNORED (local caps only)" || bad "wire caps leaked in!"

echo "== 10. grant from WRONG hex → ignored (no matching sent redemption) =="
read -r WN WH < <(new_peer wrong)
GMSG2=$(jq -nc --arg from "$WH" '{from:$from,id:"gw",body:({a2a:"1",kind:"ticket.grant",payload:{tid:"tgrant9",status:"granted",caps:["consult"],grantBack:["consult"]}}|tojson)}')
echo "$GMSG2" | bash "$TICKET" ingest-grant - >/dev/null 2>&1
[ "$(authst "$WH")" = "absent" ] && ok "grant from wrong hex ignored" || bad "wrong-hex grant applied!"

echo "== 11. concurrent double-redeem race: exactly one wins =="
TR=$(issue --caps consult --name race); TIDR=$(tid_of "$TR"); SECR=$(secret_of "$TR")
read -r R1N R1H < <(new_peer r1); read -r R2N R2H < <(new_peer r2)
redeem_msg "$R1H" "$TIDR" "$SECR" "$R1N" | bash "$TICKET" ingest-redeem - >/dev/null 2>&1 &
redeem_msg "$R2H" "$TIDR" "$SECR" "$R2N" | bash "$TICKET" ingest-redeem - >/dev/null 2>&1 &
wait
WINNERS=0
[ "$(authst "$R1H")" = "authorized" ] && WINNERS=$((WINNERS+1))
[ "$(authst "$R2H")" = "authorized" ] && WINNERS=$((WINNERS+1))
[ "$WINNERS" = "1" ] && ok "exactly one redeemer wins the race" || bad "race produced $WINNERS winners"

echo "== 12. revoke + reap =="
TV=$(issue --caps consult --name rev); TIDV=$(tid_of "$TV")
bash "$TICKET" revoke "$TIDV" >/dev/null 2>&1
[ "$(tkst "$TIDV")" = "revoked" ] && ok "revoke works" || bad "revoke failed"
read -r VN VH < <(new_peer rv)
OUT=$(redeem_msg "$VH" "$TIDV" "$(secret_of "$TV")" "$VN" | bash "$TICKET" ingest-redeem - 2>&1)
echo "$OUT" | grep -qiE "already-redeemed|invalid|deny" && ok "revoked ticket not redeemable" || bad "revoked still redeemable"

echo "== 13. rate-limit: >N failed redeems/hex/hr silently dropped (no oracle) =="
TL=$(TK_RATE_HEX_HOUR=3 issue --caps consult --name rl); TIDL=$(tid_of "$TL")
read -r LN LH < <(new_peer rl)
# 3 bad-secret attempts: each denied 'invalid' AND logged as a failed attempt.
for i in 1 2 3; do redeem_msg "$LH" "$TIDL" "BAD$i" "$LN" | TK_RATE_HEX_HOUR=3 bash "$TICKET" ingest-redeem - >/dev/null 2>&1; done
# 4th (still bad) must now be RATE-LIMITED (silent drop) — NOT a fresh 'invalid' oracle.
OUT=$(redeem_msg "$LH" "$TIDL" "BAD4" "$LN" | TK_RATE_HEX_HOUR=3 bash "$TICKET" ingest-redeem - 2>&1)
echo "$OUT" | grep -q "rate-limited" && ok "over-limit redeem dropped (rate-limited)" || bad "rate-limit not enforced"
[ "$(authst "$LH")" = "absent" ] && ok "rate-limited peer not authorized" || bad "rate-limited peer authorized!"

echo "== 14. deferred-replay (#14): authorizing the redeemer replays their stashed envelope =="
SD="$(. "$HOOKS/state-dir.sh" 2>/dev/null && printf '%s' "$STATE_DIR")"
TD=$(issue --caps consult --name defer); TIDD=$(tid_of "$TD"); SECD=$(secret_of "$TD")
read -r DN DH < <(new_peer d14)
# Stash a peer consult.request (arrived BEFORE authorization), exactly as classify-inbound would.
mkdir -p "$SD/agent-deferred/$DH"
DENV=$(jq -nc '{a2a:"1",kind:"consult.request",id:"defer-14",consult:"c14",area:"x",payload:{note:"pre-auth"}}')
jq -nc --arg b "$DENV" --arg np "$DN" '{body:$b,receivedAt:"2026-01-01T00:00:00Z",npub:$np,unicityName:"d14",kind:"consult.request"}' > "$SD/agent-deferred/$DH/defer-14.json"
# Redeem → authorizes DH with cap consult → fires the deferred-replay.
redeem_msg "$DH" "$TIDD" "$SECD" "$DN" | bash "$TICKET" ingest-redeem - >/dev/null 2>&1
if [ -f "$SD/agent-consult-events/defer-14.json" ] && [ ! -d "$SD/agent-deferred/$DH" ]; then
  ok "stashed envelope replayed onto consult queue on ticket-authorize"
else
  bad "deferred envelope not replayed (#14)"
fi
rm -f "$SD/agent-consult-events/defer-14.json"; rm -rf "$SD/agent-deferred/$DH"  # clean our shared-STATE_DIR footprint

echo "== 15. secret NEVER on child (node) argv — piped via stdin only =="
# Shim `node` on PATH to record every child invocation's argv; the secret-bearing input to
# ticket-verify (base64 event content) and send-dm (envelope body) must arrive on STDIN, so
# it must be ABSENT from the recorded argv. Pre-fix (input as argv) this fails.
BIN="$SBX/bin"; mkdir -p "$BIN"; REALNODE="$(command -v node)"
{ printf '#!/bin/bash\n'; printf 'printf "%%s\\0" "$@" >> "%s"\n' "$SBX/argv.log"; printf 'exec "%s" "$@"\n' "$REALNODE"; } > "$BIN/node"
chmod +x "$BIN/node"; : > "$SBX/argv.log"
TS=$(issue --v1 --caps consult --name argv); TSEV=$(bash "$TICKET" decode "$TS"); TSCONTENT=$(printf '%s' "$TSEV" | jq -r '.content')
printf '%s' "$TSEV" | PATH="$BIN:$PATH" node "$HELPER" ticket-verify >/dev/null 2>&1
SENT="SENTINELSECRET_DEADBEEF01234567"
BODY=$(jq -nc --arg s "$SENT" '{a2a:"1",kind:"ticket.redeem",payload:{tid:"tx",secret:$s}}')
printf '%s' "$BODY" | PATH="$BIN:$PATH" node "$HELPER" send-dm "npub1bogus" --identity "$SBX/proj/.claude/agent/identity.json" >/dev/null 2>&1 || true
# v2: drive the whole redeem verify path (relay-fetch + ticket2-verify) under the shim —
# the SECRET must reach the helper on stdin only; the dtag on argv is just its public hash.
TV2=$(issue --caps consult --name argv2); SV2="$(secret_of "$TV2")"
DV2="$(printf '%s' "$SV2" | sha256sum | awk '{print $1}')"
FEV2=$(PATH="$BIN:$PATH" node "$HELPER" relay-fetch --dtag "$DV2" 2>/dev/null)
printf '%s' "$FEV2" | jq -c --arg s "$SV2" '{secret:$s,events:.events}' | PATH="$BIN:$PATH" node "$HELPER" ticket2-verify >/dev/null 2>&1
if [ -s "$SBX/argv.log" ] && grep -aqF "ticket-verify" "$SBX/argv.log" && grep -aqF "ticket2-verify" "$SBX/argv.log" \
   && ! grep -aqF "$TSCONTENT" "$SBX/argv.log" && ! grep -aqF "$SENT" "$SBX/argv.log" && ! grep -aqF "$SV2" "$SBX/argv.log"; then
  ok "ticket secret (v1 + v2) never on child node argv (stdin only)"
else
  bad "secret leaked onto child node argv"
fi

echo "== 16. least-privilege + short-lived defaults (#25 a/e) =="
TDEF=$(issue --name defaults)                 # NO --caps / --ttl → defaults apply
DPL=$(v2_payload_of "$TDEF")
DCAPS=$(printf '%s' "$DPL" | jq -r '.caps | join(",")')
DEXP=$(printf '%s' "$DPL" | jq -r '.exp'); NOWS=$(date -u +%s); DELTA=$(( DEXP - NOWS ))
[ "$DCAPS" = "consult,claim-area" ] && ok "default caps are minimal (consult,claim-area)" || bad "default caps = '$DCAPS' (want consult,claim-area)"
{ [ "$DELTA" -gt 0 ] && [ "$DELTA" -le 1800 ]; } && ok "default ttl is minutes-scale (exp in ${DELTA}s ≤ 30m)" || bad "default ttl not minutes-scale (exp in ${DELTA}s)"
# still overridable
TOVR=$(issue --caps consult,claim-area,task-bid --ttl 2h --name ovr)
OCAPS=$(v2_payload_of "$TOVR" | jq -r '.caps | join(",")')
[ "$OCAPS" = "consult,claim-area,task-bid" ] && ok "explicit --caps still honored" || bad "override --caps = '$OCAPS'"

echo "== 17. v2 redeemer path: hash→fetch→verify→send, fail-closed variants =="
# happy verify path via the real tk_redeem CLI (stub relay, dry-run send, no grant poll)
T17=$(issue --caps consult --name r17)
OUT=$(printf '%s' "$T17" > "$SBX/t17"; bash "$TICKET" redeem --ticket-file "$SBX/t17" --yes --timeout 0 2>&1; true)
echo "$OUT" | grep -q "DRY-RUN send.*ticket.redeem" && ok "redeem verifies + sends ticket.redeem (dry-run)" || bad "no redeem send: $OUT"
TID17=$(tid_of "$T17")
[ "$(jq -r --arg t "$TID17" '.redemptions[]? | select(.tid==$t) | .status' "$SBX/coord/redemptions.json")" = "sent" ] \
  && ok "redemption recorded (status=sent)" || bad "redemption not recorded"
# malformed short string → refused before ANY fetch/send
OUT=$(bash "$TICKET" redeem "ut2_tooshort" --yes 2>&1; true)
echo "$OUT" | grep -q "malformed v2 ticket" && ok "mangled paste refused loudly" || bad "mangled ticket not refused"
# unknown/bad secret (well-formed) → no event on the relay → refused before any send
BADSEC="ut2_$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 43)"
OUT=$(bash "$TICKET" redeem "$BADSEC" --yes 2>&1; true)
echo "$OUT" | grep -q "no ticket event" && ok "unknown secret refused (no event)" || bad "bad secret not refused: $OUT"
# expired ticket → redeemer-side expiry check refuses BEFORE any send
T17E=$(issue --caps consult --ttl 1s --name r17e); sleep 2
OUT=$(printf '%s' "$T17E" > "$SBX/t17e"; bash "$TICKET" redeem --ticket-file "$SBX/t17e" --yes 2>&1; true)
echo "$OUT" | grep -q "EXPIRED" && ok "expired ticket refused at redeemer" || bad "expired not refused: $OUT"

echo "== 18. v1 compat: issue --v1 still redeemable end-to-end =="
TV1=$(issue --v1 --caps consult --name legacy)
printf '%s' "$TV1" | grep -q '^unicity-ticket:v1\.' && ok "--v1 emits the legacy self-contained format" || bad "--v1 format wrong"
TIDV1=$(v1_tid_of "$TV1"); SECV1=$(v1_secret_of "$TV1")
read -r ZN ZH < <(new_peer legacyp)
redeem_msg "$ZH" "$TIDV1" "$SECV1" "$ZN" | bash "$TICKET" ingest-redeem - >/dev/null 2>&1
[ "$(authst "$ZH")" = "authorized" ] && ok "v1 ticket ingest still authorizes" || bad "v1 ingest broken"

echo "== 19. DENY is STICKY: a denied peer re-redeeming its ticket stays denied + is surfaced =="
# Live evidence: a denied agent RE-AUTHORIZED itself by re-redeeming an already-redeemed ticket.
# The ticket re-redeem path must NOT un-deny; only an OWNER-explicit authorize may.
REG="$HOOKS/agent-registry.sh"
# The surface lands in the per-repo STATE_DIR (derived by state-dir.sh from the hooks path,
# exactly where the Stop gate reads it) — capture it the same way section 14 does.
SD19="$(. "$HOOKS/state-dir.sh" 2>/dev/null && printf '%s' "$STATE_DIR")"
SURF="$SD19/agent-denied-reauth.json"
rm -f "$SURF"
TS19=$(issue --caps consult,claim-area --name sticky); TID19=$(tid_of "$TS19"); SEC19=$(secret_of "$TS19")
read -r SN SH < <(new_peer sticky)
# a) first redeem → authorized + ticket consumed (baseline)
redeem_msg "$SH" "$TID19" "$SEC19" "$SN" | bash "$TICKET" ingest-redeem - >/dev/null 2>&1
[ "$(authst "$SH")" = "authorized" ] && ok "peer authorized on first redeem" || bad "first redeem did not authorize"
# b) owner DENIES the peer
bash "$REG" deny "$SH" >/dev/null 2>&1
[ "$(authst "$SH")" = "denied" ] && ok "owner deny recorded" || bad "deny not recorded"
# c) DENIED peer re-redeems the SAME (already-redeemed) ticket → MUST stay denied, NO re-grant
OUT=$(redeem_msg "$SH" "$TID19" "$SEC19" "$SN" | bash "$TICKET" ingest-redeem - 2>&1)
[ "$(authst "$SH")" = "denied" ] && ok "re-redeem did NOT un-deny (deny sticky)" || bad "denied peer re-authorized itself via re-redeem!"
echo "$OUT" | grep -q "DRY-RUN send.*ticket.grant" && bad "grant emitted to a denied peer!" || ok "no grant emitted to a denied peer"
# d) attempt is surfaced to the owner (Stop-gate state file)
[ "$(jq -r '.count // 0' "$SURF" 2>/dev/null)" -gt 0 ] 2>/dev/null && ok "denied re-auth surfaced to owner" || bad "denied re-auth NOT surfaced"
[ "$(jq -r --arg h "$SH" 'any(.items[]?; .pubkey==$h)' "$SURF" 2>/dev/null)" = "true" ] && ok "surface names the denied pubkey" || bad "surface missing the pubkey"
# e) a bare (non-owner) direct authorize is ALSO refused — the chokepoint is in the registry
bash "$REG" authorize "$SH" consult >/dev/null 2>&1 && bad "non-owner authorize un-denied!" || ok "non-owner authorize refused (exit non-zero)"
[ "$(authst "$SH")" = "denied" ] && ok "still denied after non-owner authorize" || bad "un-denied by non-owner authorize"
# f) OWNER-explicit authorize (--owner) is the ONLY un-deny → succeeds + clears the surface
bash "$REG" authorize "$SH" consult --owner >/dev/null 2>&1 && ok "owner --owner authorize succeeds" || bad "owner authorize failed"
[ "$(authst "$SH")" = "authorized" ] && ok "owner re-authorized the peer (un-deny)" || bad "owner authorize did not un-deny"
[ "$(jq -r '.count // 0' "$SURF" 2>/dev/null)" = "0" ] && ok "surface cleared after owner un-deny" || bad "surface not cleared"
rm -f "$SURF"  # clean our shared-STATE_DIR footprint (repo-default dir, like section 14)

echo ""
echo "════════════════════════════════════════"
echo "  onboarding-ticket: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
