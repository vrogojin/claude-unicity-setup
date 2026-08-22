#!/bin/bash
# npub-rotation.test.sh — hermetic proof of npub ROTATION (the second half of the A2A
# threat-model prereq). Covers, with REAL secp256k1/schnorr crypto:
#   A. rotate-sign / rotate-verify — the chain-of-trust attestation (old key signs new npub);
#      forged/tampered attestations fail closed.
#   B. registry `rotate` — retire the old key (caps stripped), seed the successor; default-deny
#      preserved (successor PENDING unless --owner; a DENIED identity can't rotate to a fresh slot).
#   C. classify-inbound drops traffic from a RETIRED key (a harvested old npub is a dead end).
#   D. classify-inbound `identity.rotate` ingest — a valid attested rotation retires the sender's
#      old key and seeds the successor pending; a rotation not signed by the sender is rejected;
#      an unauthorized sender's rotation is inert.
#   E. `a2a rotate --yes --no-announce` — local swap: new key live, old key archived 0600,
#      old npub recorded in config.previous_npubs.
# Real crypto ⇒ a resolvable node_modules is required (SKIP otherwise, like the sibling suites).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SRC_HOOKS="$REPO/claude_conf/hooks"
HELPER="$REPO/lib/sphere-helper.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

cd "$REPO"  # ESM resolves @unicitylabs/* by walking up from the helper dir → worktree node_modules

TMP="$(mktemp -d)"
HOOKS="$TMP/hooks"; cp -r "$SRC_HOOKS" "$HOOKS"
PROJ="$TMP/proj"; mkdir -p "$PROJ/.claude/agent"
REG="$HOOKS/agent-registry.sh"
A2A="$HOOKS/a2a.sh"

export CLAUDE_PROJECT_DIR="$PROJ"
export AGENT_REGISTRY_FILE="$PROJ/.claude/agent/agent-registry.json"
export TEAM_SPHERE_HELPER="$HELPER"
export TEAM_IDENTITY_FILE="$PROJ/.claude/agent/identity.json"
export TEAM_SELF_NAME="rot-test"
export TEAM_DRY_RUN=1
STATE_DIR="$(. "$HOOKS/state-dir.sh" 2>/dev/null && printf '%s' "$STATE_DIR")"
rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
MSGFILE="$STATE_DIR/agent-messages.json"
trap 'rm -rf "$TMP" "$STATE_DIR"' EXIT

helper() { node "$HELPER" "$@"; }
mkid()   { helper create-identity; }              # → identity JSON on stdout
hexof()  { helper npub-to-hex "$1" 2>/dev/null | jq -r .hex; }

# self identity/config for the a2a-rotate path
mkid > "$PROJ/.claude/agent/identity.json" 2>/dev/null
if ! jq -e .npub "$PROJ/.claude/agent/identity.json" >/dev/null 2>&1; then
  echo "SKIP: sphere-helper/SDK not resolvable (node_modules missing) — cannot run rotation crypto test"; exit 0
fi
printf '{"agent_nametag":"rot-test","owner_npub":"","owner_nametag":""}' > "$PROJ/.claude/agent/config.json"

# Deliver a crafted inbound DM through the REAL classifier (as on-dm.sh → classify-inbound would).
deliver() { # <from_hex> <body-json-string>
  local from="$1" body="$2"
  [ -f "$MSGFILE" ] || printf '{"unread":false,"unread_count":0,"priority_count":0,"messages":[]}' > "$MSGFILE"
  local t="$MSGFILE.t"
  jq --arg from "$from" --arg body "$body" --arg ts "$(date -u +%FT%TZ)" \
    '.messages += [{type:"dm",from:$from,from_name:"",body:$body,timestamp:$ts,priority:false,read:false,authz:null}]' \
    "$MSGFILE" > "$t" && mv "$t" "$MSGFILE"
  ( cd "$HOOKS" && bash "$HOOKS/classify-inbound.sh" >/dev/null 2>&1 )
}
last_authz() { jq -c '.messages[-1].authz' "$MSGFILE"; }

echo "== A. rotate-sign / rotate-verify (chain-of-trust) =="
OLD="$TMP/old.json"; NEW="$TMP/new.json"; ATT="$TMP/att.json"
mkid > "$OLD" 2>/dev/null; mkid > "$NEW" 2>/dev/null
OLD_NPUB="$(jq -r .npub "$OLD")"; NEW_NPUB="$(jq -r .npub "$NEW")"
helper rotate-sign --identity "$OLD" --new-npub "$NEW_NPUB" --reason "harvested" > "$ATT" 2>/dev/null
V="$(cat "$ATT" | helper rotate-verify 2>/dev/null)"
[ "$(echo "$V" | jq -r .valid)" = "true" ] && [ "$(echo "$V" | jq -r .new_npub)" = "$NEW_NPUB" ] \
  && ok "legit attestation verifies (old key authorized the new npub)" || bad "legit attestation failed to verify ($V)"

# forgery: tamper new_npub after signing → signature breaks
ATTACKER="$TMP/att.json.bad"; cp "$ATT" "$ATTACKER"
ATT_NPUB="$(jq -r .npub "$NEW")"
node -e 'const fs=require("fs");const e=JSON.parse(fs.readFileSync(process.argv[1]));const p=JSON.parse(e.content);p.new_npub="npub1attackerXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX";e.content=JSON.stringify(p);fs.writeFileSync(process.argv[1],JSON.stringify(e));' "$ATTACKER"
VB="$(cat "$ATTACKER" | helper rotate-verify 2>/dev/null || true)"
[ "$(echo "$VB" | jq -r '.valid // false')" = "false" ] && ok "tampered attestation is rejected (fail-closed)" || bad "tampered attestation accepted!"

# forgery: someone else signs claiming to be old_npub → old-npub-mismatch / bad-signature
OTHER="$TMP/other.json"; mkid > "$OTHER" 2>/dev/null
helper rotate-sign --identity "$OTHER" --new-npub "$NEW_NPUB" > "$TMP/att.other" 2>/dev/null
node -e 'const fs=require("fs");const e=JSON.parse(fs.readFileSync(process.argv[1]));const p=JSON.parse(e.content);p.old_npub=process.argv[2];e.content=JSON.stringify(p);fs.writeFileSync(process.argv[1],JSON.stringify(e));' "$TMP/att.other" "$OLD_NPUB"
VO="$(cat "$TMP/att.other" | helper rotate-verify 2>/dev/null || true)"
[ "$(echo "$VO" | jq -r '.valid // false')" = "false" ] && ok "a bystander cannot forge a rotation for our npub" || bad "bystander rotation forgery accepted!"

echo "== B. registry rotate (retire old, seed successor; default-deny) =="
PA="$TMP/pa.json"; PB="$TMP/pb.json"; mkid > "$PA" 2>/dev/null; mkid > "$PB" 2>/dev/null
PA_NPUB="$(jq -r .npub "$PA")"; PA_HEX="$(hexof "$PA_NPUB")"; PB_NPUB="$(jq -r .npub "$PB")"; PB_HEX="$(hexof "$PB_NPUB")"
bash "$REG" upsert-pending --pubkey "$PA_HEX" --npub "$PA_NPUB" --name "peer-a" >/dev/null 2>&1
bash "$REG" authorize "$PA_HEX" consult,chat --owner >/dev/null 2>&1
# non-owner rotate → old retired (caps []), successor pending (caps [])
bash "$REG" rotate "$PA_HEX" --to "$PB_NPUB" >/dev/null 2>&1
[ "$(bash "$REG" status "$PA_HEX")" = "retired" ] && ok "old key becomes RETIRED after rotate" || bad "old key not retired ($(bash "$REG" status "$PA_HEX"))"
[ "$(bash "$REG" get "$PA_HEX" | jq -c '.capabilities')" = "[]" ] && ok "retired key has NO capabilities" || bad "retired key kept caps"
[ "$(bash "$REG" status "$PB_HEX")" = "pending" ] && ok "successor is PENDING (owner must re-authorize — default-deny)" || bad "successor not pending ($(bash "$REG" status "$PB_HEX"))"
[ "$(bash "$REG" get "$PB_HEX" | jq -c '.capabilities')" = "[]" ] && ok "successor carries NO caps without --owner" || bad "successor auto-inherited caps (leak!)"
[ "$(bash "$REG" get "$PB_HEX" | jq -r '.rotatedFrom')" = "$PA_HEX" ] && ok "successor records rotatedFrom" || bad "successor missing rotatedFrom"

# owner rotate → successor carries status+caps
PC="$TMP/pc.json"; mkid > "$PC" 2>/dev/null; PC_NPUB="$(jq -r .npub "$PC")"; PC_HEX="$(hexof "$PC_NPUB")"
bash "$REG" rotate "$PB_HEX" --to "$PC_NPUB" --owner >/dev/null 2>&1
# PB was pending → owner rotate carries pending forward (still not a cap grant); assert retired old + successor present
[ "$(bash "$REG" status "$PB_HEX")" = "retired" ] && ok "owner rotate also retires the prior key" || bad "owner rotate did not retire prior key"

# denied identity cannot rotate into a fresh pending slot
PD="$TMP/pd.json"; PE="$TMP/pe.json"; mkid > "$PD" 2>/dev/null; mkid > "$PE" 2>/dev/null
PD_NPUB="$(jq -r .npub "$PD")"; PD_HEX="$(hexof "$PD_NPUB")"; PE_NPUB="$(jq -r .npub "$PE")"; PE_HEX="$(hexof "$PE_NPUB")"
bash "$REG" upsert-pending --pubkey "$PD_HEX" --npub "$PD_NPUB" --name "bad" >/dev/null 2>&1
bash "$REG" deny "$PD_HEX" >/dev/null 2>&1
bash "$REG" rotate "$PD_HEX" --to "$PE_NPUB" >/dev/null 2>&1
[ "$(bash "$REG" status "$PE_HEX")" = "denied" ] && ok "a DENIED identity stays denied across rotation (no escape)" || bad "denied identity escaped via rotation ($(bash "$REG" status "$PE_HEX"))"

echo "== C. classify-inbound drops RETIRED-key traffic =="
deliver "$PA_HEX" "hello from the retired key"
[ "$(last_authz | jq -r '.status')" = "retired" ] && ok "message from retired key classified 'retired' (inert)" || bad "retired-key message not dropped ($(last_authz))"
# no workitem should have been produced for the retired sender
WI=$(ls "$STATE_DIR/agent-workitems"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "${WI:-0}" = "0" ] && ok "retired-key message produced NO work item" || bad "retired-key message produced a work item"

echo "== D. classify-inbound identity.rotate ingest =="
# authorized sender rotates itself with a valid attestation → old retired, successor pending
RA="$TMP/ra.json"; RB="$TMP/rb.json"; mkid > "$RA" 2>/dev/null; mkid > "$RB" 2>/dev/null
RA_NPUB="$(jq -r .npub "$RA")"; RA_HEX="$(hexof "$RA_NPUB")"; RB_NPUB="$(jq -r .npub "$RB")"; RB_HEX="$(hexof "$RB_NPUB")"
bash "$REG" upsert-pending --pubkey "$RA_HEX" --npub "$RA_NPUB" --name "rotator" >/dev/null 2>&1
bash "$REG" authorize "$RA_HEX" consult,chat --owner >/dev/null 2>&1
RATT="$(helper rotate-sign --identity "$RA" --new-npub "$RB_NPUB" 2>/dev/null)"
RENV="$(jq -nc --argjson att "$RATT" --arg f "$RA_NPUB" '{kind:"identity.rotate",attestation:$att,fromNpub:$f}')"
deliver "$RA_HEX" "$RENV"
[ "$(last_authz | jq -r '.rotated')" = "true" ] && ok "valid attested rotation is accepted (rotated=true)" || bad "attested rotation not accepted ($(last_authz))"
[ "$(bash "$REG" status "$RA_HEX")" = "retired" ] && ok "sender's old key retired by ingest" || bad "old key not retired by ingest"
[ "$(bash "$REG" status "$RB_HEX")" = "pending" ] && ok "successor seeded PENDING (owner re-authorizes)" || bad "successor not pending after ingest"

# attestation NOT signed by the sender → rejected, nothing retired
RC="$TMP/rc.json"; RD="$TMP/rd.json"; mkid > "$RC" 2>/dev/null; mkid > "$RD" 2>/dev/null
RC_NPUB="$(jq -r .npub "$RC")"; RC_HEX="$(hexof "$RC_NPUB")"; RD_NPUB="$(jq -r .npub "$RD")"
bash "$REG" upsert-pending --pubkey "$RC_HEX" --npub "$RC_NPUB" --name "victimauth" >/dev/null 2>&1
bash "$REG" authorize "$RC_HEX" consult --owner >/dev/null 2>&1
# attestation signed by OLD (unrelated) key, delivered as if from RC → old_hex != RC_HEX
FENV="$(jq -nc --argjson att "$RATT" --arg f "$RC_NPUB" '{kind:"identity.rotate",attestation:$att,fromNpub:$f}')"
deliver "$RC_HEX" "$FENV"
[ "$(last_authz | jq -r '.rotated')" = "false" ] && ok "rotation not signed by the sender is REJECTED" || bad "cross-identity rotation accepted!"
[ "$(bash "$REG" status "$RC_HEX")" = "authorized" ] && ok "the wrongly-attested sender stays authorized (untouched)" || bad "sender wrongly retired"

# unauthorized sender's rotation is inert
RU="$TMP/ru.json"; RV="$TMP/rv.json"; mkid > "$RU" 2>/dev/null; mkid > "$RV" 2>/dev/null
RU_NPUB="$(jq -r .npub "$RU")"; RU_HEX="$(hexof "$RU_NPUB")"; RV_NPUB="$(jq -r .npub "$RV")"
UATT="$(helper rotate-sign --identity "$RU" --new-npub "$RV_NPUB" 2>/dev/null)"
UENV="$(jq -nc --argjson att "$UATT" --arg f "$RU_NPUB" '{kind:"identity.rotate",attestation:$att,fromNpub:$f}')"
deliver "$RU_HEX" "$UENV"
[ "$(last_authz | jq -r '.rotated')" = "false" ] && [ "$(last_authz | jq -r '.reason')" = "sender-not-authorized:unknown" ] \
  && ok "an unauthorized sender's rotation is inert (default-deny)" || bad "unauthorized rotation not inert ($(last_authz))"

echo "== E. a2a rotate --yes --no-announce (local swap) =="
SELF_OLD="$(jq -r .npub "$PROJ/.claude/agent/identity.json")"
OUT="$(bash "$A2A" rotate --yes --no-announce --reason "self-test" 2>&1)"
SELF_NEW="$(jq -r .npub "$PROJ/.claude/agent/identity.json")"
[ -n "$SELF_NEW" ] && [ "$SELF_NEW" != "$SELF_OLD" ] && ok "identity.json now holds a NEW npub" || bad "identity npub did not change ($OUT)"
ls "$PROJ/.claude/agent/"identity.json.rotated-*.bak >/dev/null 2>&1 && ok "old key archived to a .rotated-*.bak" || bad "no archived old key"
BAKPERM="$(stat -c '%a' "$PROJ/.claude/agent/"identity.json.rotated-*.bak 2>/dev/null | head -1)"
[ "$BAKPERM" = "600" ] && ok "archived old key is 0600 (secret-safe)" || bad "archived key perms = $BAKPERM (want 600)"
[ "$(jq -r '.previous_npubs[0] // ""' "$PROJ/.claude/agent/config.json")" = "$SELF_OLD" ] && ok "config records the retired npub in previous_npubs" || bad "config did not record previous npub"
[ "$(jq -r '.agent_npub // ""' "$PROJ/.claude/agent/config.json")" = "$SELF_NEW" ] && ok "config agent_npub updated to the successor" || bad "config agent_npub not updated"
# the attestation persisted for re-announce
ls "$PROJ/.claude/agent/"rotation-*.attestation.json >/dev/null 2>&1 && ok "rotation attestation persisted for re-announce" || bad "attestation not persisted"

echo
echo "npub-rotation: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
