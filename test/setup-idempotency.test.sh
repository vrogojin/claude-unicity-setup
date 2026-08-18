#!/bin/bash
# Hermetic tests for setup.sh's idempotency / non-interactive / dry-run contract:
#   T1  bash -n clean
#   T2  --dry-run on a CONFIGURED project previews KEEPING the identity (not
#       regenerating it) and writes NOTHING anywhere in the project
#   T3  non-interactive re-run (--yes) on a configured project preserves the
#       identity byte-for-byte, every config value, unknown/extra config keys,
#       and hand-added daemon.json entries — and never prompts
#   T4  a second --yes run converges (config identical to after the first run)
#   T5  an explicit SETUP_* override changes exactly that one value
#   T6  FORCE_NEW_IDENTITY=1 --dry-run previews regeneration (faithful preview)
#       but still writes nothing
#   T7  fresh non-interactive install bootstraps: mints an identity, default
#       nametag, exits 0  [needs resolvable @unicitylabs/sphere-sdk — SKIP else]
#
# No network is touched: seeded group ids are non-placeholder (join skipped),
# SETUP_SKIP_VERIFY=1 skips the relay round-trip, docker is stubbed out, and
# HOME is sandboxed so the memory seed stays in the sandbox.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SETUP="$REPO/setup.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check() { if eval "$1"; then ok "$2"; else bad "$2"; fi }

SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT
export HOME="$SBX/home"; mkdir -p "$HOME"

# Stub docker so deploy_serena_mcp fails fast without touching host images/volumes.
mkdir -p "$SBX/bin"
printf '#!/bin/sh\nexit 1\n' > "$SBX/bin/docker"; chmod +x "$SBX/bin/docker"
export PATH="$SBX/bin:$PATH"

# Never hit the relay from tests.
export SETUP_SKIP_VERIFY=1

SDK_OK=true
( cd "$REPO/lib" && node -e "require.resolve('@unicitylabs/sphere-sdk')" ) >/dev/null 2>&1 || SDK_OK=false

seed_configured() { # $1 = project dir
  local p="$1"
  mkdir -p "$p/.git" "$p/.claude/agent"
  cat > "$p/.claude/agent/identity.json" <<'EOF'
{"created_at":"2026-01-01T00:00:00Z","mnemonic":"seed seed seed","public_key":"deadbeef","npub":"npub1seededagent","nsec":"nsec1seededsecret","derivation_path":"m/44'/0'/0'/0/0","nametag":"seeded-agent"}
EOF
  chmod 600 "$p/.claude/agent/identity.json"
  cat > "$p/.claude/agent/config.json" <<EOF
{
  "agent_nametag": "seeded-agent",
  "owner_npub": "npub1owner",
  "owner_nametag": "boss",
  "notification_url": "https://ntfy.sh/seeded-topic",
  "network": "testnet",
  "group": {"name": "UNICITY_DEV_AGENTS", "id": "realgroup123", "relays": ["wss://custom.relay.example"]},
  "transport": {"helper_path": "/old/clone/lib/sphere-helper.mjs"},
  "dep_tracking": {"enabled": true, "selected_deps": ["sphere-sdk"]},
  "custom_key": "KEEPME"
}
EOF
  cat > "$p/.claude/agent/daemon.json" <<EOF
{
  "relays": ["wss://custom.relay.example"],
  "subscriptions": {
    "groups": [{"id": "realgroup123", "name": "UNICITY_DEV_AGENTS"}],
    "dm_contacts": ["npub1owner", "npub1extracontact"]
  },
  "hooks": {"on_dm": ".claude/hooks/on-dm.sh", "on_group_message": ".claude/hooks/on-group-message.sh", "custom_hook": "keep.sh"}
}
EOF
}

echo "== T1: bash -n =="
check "bash -n '$SETUP' 2>/dev/null" "setup.sh parses clean (bash -n)"

echo "== T2: --dry-run on configured project is faithful + writes nothing =="
P2="$SBX/proj2"; seed_configured "$P2"
cp -a "$P2" "$SBX/proj2.before"
OUT2="$(bash "$SETUP" "$P2" --dry-run </dev/null 2>&1)"; RC2=$?
check "[ $RC2 -eq 0 ]" "dry-run exits 0"
check "grep -q 'Keeping existing identity' <<< \"\$OUT2\"" "dry-run previews KEEPING the existing identity"
check "! grep -q 'Generating identity' <<< \"\$OUT2\"" "dry-run does NOT preview minting a new identity"
check "! grep -q '\[Y/n\]' <<< \"\$OUT2\"" "dry-run (no TTY) asked no prompts"
check "diff -r '$P2' '$SBX/proj2.before' >/dev/null" "dry-run wrote nothing"

echo "== T3: non-interactive re-run preserves everything =="
P3="$SBX/proj3"; seed_configured "$P3"
cp "$P3/.claude/agent/identity.json" "$SBX/id3.before"
OUT3="$(bash "$SETUP" "$P3" --yes </dev/null 2>&1)"; RC3=$?
C3="$P3/.claude/agent/config.json"; D3="$P3/.claude/agent/daemon.json"
check "[ $RC3 -eq 0 ]" "non-interactive run exits 0"
check "cmp -s '$P3/.claude/agent/identity.json' '$SBX/id3.before'" "identity.json untouched byte-for-byte"
check "grep -q 'Keeping existing identity' <<< \"\$OUT3\"" "identity reported as kept"
check "! grep -q '\[Y/n\]' <<< \"\$OUT3\"" "no prompts were shown"
check "[ \"\$(jq -r .agent_nametag '$C3')\" = seeded-agent ]" "agent_nametag preserved"
check "[ \"\$(jq -r .owner_npub '$C3')\" = npub1owner ]" "owner_npub preserved"
check "[ \"\$(jq -r .owner_nametag '$C3')\" = boss ]" "owner_nametag preserved"
check "[ \"\$(jq -r .notification_url '$C3')\" = https://ntfy.sh/seeded-topic ]" "notification_url preserved"
check "[ \"\$(jq -r .network '$C3')\" = testnet ]" "network preserved"
check "[ \"\$(jq -r '.group.id' '$C3')\" = realgroup123 ]" "group id preserved (join skipped)"
check "[ \"\$(jq -r '.group.relays[0]' '$C3')\" = wss://custom.relay.example ]" "custom relay preserved (network unchanged)"
check "[ \"\$(jq -r .custom_key '$C3')\" = KEEPME ]" "unknown config key survives (deep-merge, not rebuild)"
check "[ \"\$(jq -c '.dep_tracking.selected_deps' '$C3')\" = '[\"sphere-sdk\"]' ]" "dep tracking preserved"
check "[ \"\$(jq -r '.transport.helper_path' '$C3')\" = '$REPO/lib/sphere-helper.mjs' ]" "helper_path refreshed to this clone (framework-owned)"
check "jq -e '.subscriptions.dm_contacts | index(\"npub1extracontact\")' '$D3' >/dev/null" "hand-added daemon dm_contact kept"
check "jq -e '.relays | index(\"wss://custom.relay.example\")' '$D3' >/dev/null" "daemon relay kept"
check "[ \"\$(jq -r '.hooks.custom_hook' '$D3')\" = keep.sh ]" "extra daemon hook key kept"

echo "== T3b: user-accumulated settings survive the framework refresh =="
P3B="$SBX/proj3b"; seed_configured "$P3B"
mkdir -p "$P3B/.claude"
echo '{"permissions":{"allow":["Bash(my-custom-tool:*)"]},"userScalar":true}' > "$P3B/.claude/settings.local.json"
echo '{"env":{"MY_CUSTOM_ENV":"keepme"}}' > "$P3B/.claude/settings.json"
bash "$SETUP" "$P3B" --yes </dev/null >/dev/null 2>&1
SL3B="$P3B/.claude/settings.local.json"; SJ3B="$P3B/.claude/settings.json"
check "jq -e '.permissions.allow | index(\"Bash(my-custom-tool:*)\")' '$SL3B' >/dev/null" "user permission approval survives refresh"
check "jq -e '.permissions.allow | index(\"WebSearch\")' '$SL3B' >/dev/null" "template permissions also present (union)"
check "[ \"\$(jq -r .userScalar '$SL3B')\" = true ]" "unknown settings.local.json key survives"
check "[ \"\$(jq -r '.env.MY_CUSTOM_ENV' '$SJ3B')\" = keepme ]" "user env key in settings.json survives"
check "jq -e '.hooks' '$SJ3B' >/dev/null" "template settings.json content deployed"

echo "== T3c: malformed settings values cannot clobber user data =="
P3C="$SBX/proj3c"; seed_configured "$P3C"
mkdir -p "$P3C/.claude"
# "deny" is a SCALAR (user typo) — the merge must not throw, and the custom
# allow entry + deny list + unknown key must survive the framework refresh.
echo '{"permissions":{"allow":["Bash(my-tool:*)"],"deny":"Bash(rm:*)","ask":["Bash(sudo:*)"]},"userScalar":42}' > "$P3C/.claude/settings.local.json"
echo '{"env":"not-an-object"}' > "$P3C/.claude/settings.json"
OUT3C="$(bash "$SETUP" "$P3C" --yes </dev/null 2>&1)"; RC3C=$?
SL3C="$P3C/.claude/settings.local.json"
check "[ $RC3C -eq 0 ]" "run with malformed settings exits 0"
check "jq -e 'type == \"object\"' '$SL3C' >/dev/null" "settings.local.json still valid JSON"
check "jq -e '.permissions.allow | index(\"Bash(my-tool:*)\")' '$SL3C' >/dev/null" "custom allow entry survives despite malformed sibling"
check "jq -e '.permissions.ask | index(\"Bash(sudo:*)\")' '$SL3C' >/dev/null" "ask list survives (union)"
check "[ \"\$(jq -r .userScalar '$SL3C')\" = 42 ]" "unknown key survives despite malformed values"
check "jq -e '.env | type == \"object\"' '$P3C/.claude/settings.json' >/dev/null" "scalar env coerced, settings.json valid"
check "! ls '$P3C/.claude/'*.tmp 2>/dev/null | grep -q tmp" "no leftover .tmp files"

echo "== T3d: deny/ask permission union + multi-relay + relay-without-network =="
P3D="$SBX/proj3d"; seed_configured "$P3D"
mkdir -p "$P3D/.claude"
echo '{"permissions":{"deny":["Bash(dd:*)"]}}' > "$P3D/.claude/settings.local.json"
# multi-relay config + NO network field: both must survive a --yes re-run.
jq 'del(.network) | .group.relays = ["wss://custom.relay.example","wss://second.relay.example"]' \
  "$P3D/.claude/agent/config.json" > "$P3D/.claude/agent/config.json.new" \
  && mv "$P3D/.claude/agent/config.json.new" "$P3D/.claude/agent/config.json"
bash "$SETUP" "$P3D" --yes </dev/null >/dev/null 2>&1
C3D="$P3D/.claude/agent/config.json"
check "jq -e '.permissions.deny | index(\"Bash(dd:*)\")' '$P3D/.claude/settings.local.json' >/dev/null" "user deny entry survives refresh"
check "[ \"\$(jq -c '.group.relays' '$C3D')\" = '[\"wss://custom.relay.example\",\"wss://second.relay.example\"]' ]" "multi-relay array preserved untruncated"
check "[ \"\$(jq -r '.group.relays[0]' '$C3D')\" = wss://custom.relay.example ]" "custom relay preserved even with no network field"

echo "== T3e: identity nametag fill converges =="
P3E="$SBX/proj3e"; seed_configured "$P3E"
# identity has NO nametag; config does — first run fills it (additive), second
# run must then be byte-for-byte untouched.
jq 'del(.nametag)' "$P3E/.claude/agent/identity.json" > "$P3E/.claude/agent/identity.json.new" \
  && mv "$P3E/.claude/agent/identity.json.new" "$P3E/.claude/agent/identity.json"
bash "$SETUP" "$P3E" --yes </dev/null >/dev/null 2>&1
check "[ \"\$(jq -r .nametag '$P3E/.claude/agent/identity.json')\" = seeded-agent ]" "missing identity nametag filled from config"
check "[ \"\$(jq -r .npub '$P3E/.claude/agent/identity.json')\" = npub1seededagent ]" "keypair untouched by the fill"
cp "$P3E/.claude/agent/identity.json" "$SBX/id3e.after1"
bash "$SETUP" "$P3E" --yes </dev/null >/dev/null 2>&1
check "cmp -s '$P3E/.claude/agent/identity.json' '$SBX/id3e.after1'" "identity byte-for-byte on the following run"

echo "== T4: second run converges (idempotent) =="
cp "$C3" "$SBX/cfg.after1"
bash "$SETUP" "$P3" --yes </dev/null >/dev/null 2>&1
check "[ \"\$(jq -S . '$C3')\" = \"\$(jq -S . '$SBX/cfg.after1')\" ]" "config.json identical after a second run"
check "cmp -s '$P3/.claude/agent/identity.json' '$SBX/id3.before'" "identity.json still untouched after a second run"

echo "== T5: explicit SETUP_* override changes exactly that value =="
SETUP_OWNER_NPUB="npub1newowner" bash "$SETUP" "$P3" --yes </dev/null >/dev/null 2>&1
check "[ \"\$(jq -r .owner_npub '$C3')\" = npub1newowner ]" "SETUP_OWNER_NPUB applied"
check "[ \"\$(jq -r .owner_nametag '$C3')\" = boss ]" "other values (owner_nametag) untouched"
check "cmp -s '$P3/.claude/agent/identity.json' '$SBX/id3.before'" "identity untouched by an override run"

echo "== T6: FORCE_NEW_IDENTITY=1 --dry-run previews regeneration, writes nothing =="
P6="$SBX/proj6"; seed_configured "$P6"
cp -a "$P6" "$SBX/proj6.before"
OUT6="$(FORCE_NEW_IDENTITY=1 bash "$SETUP" "$P6" --dry-run </dev/null 2>&1)"
check "grep -q 'FORCE_NEW_IDENTITY=1' <<< \"\$OUT6\"" "destructive intent surfaced loudly"
check "grep -q 'Generating identity' <<< \"\$OUT6\"" "dry-run faithfully previews the regeneration"
check "diff -r '$P6' '$SBX/proj6.before' >/dev/null" "still wrote nothing under --dry-run"

echo "== T7: fresh non-interactive install bootstraps =="
if [ "$SDK_OK" = "true" ]; then
  P7="$SBX/fresh-proj"
  mkdir -p "$P7/.git" "$P7/.claude/agent"
  # Seed ONLY a group id so Phase 7 skips the live join (keeps the test hermetic).
  echo '{"group":{"id":"pretendgroup456","name":"UNICITY_DEV_AGENTS"}}' > "$P7/.claude/agent/config.json"
  OUT7="$(bash "$SETUP" "$P7" --yes </dev/null 2>&1)"; RC7=$?
  I7="$P7/.claude/agent/identity.json"
  check "[ $RC7 -eq 0 ]" "fresh install exits 0"
  check "[ -f '$I7' ]" "identity.json created"
  check "[ -n \"\$(jq -r '.npub // empty' '$I7' 2>/dev/null)\" ]" "minted identity has an npub"
  check "[ \"\$(jq -r '.nametag' '$I7')\" = claude-fresh-proj ]" "default nametag stamped"
  check "grep -q 'Generating identity' <<< \"\$OUT7\"" "identity was minted (none existed)"
  check "! grep -q '\[Y/n\]' <<< \"\$OUT7\"" "no prompts during fresh non-interactive install"
else
  echo "  SKIP: @unicitylabs/sphere-sdk not resolvable — run npm install in $REPO"
fi

echo "== T8: a malformed daemon.json groups member does not hard-abort the upgrade =="
P8="$SBX/proj8"; seed_configured "$P8"
# Poison subscriptions.groups with a non-object member (a bare string) — must NOT
# throw in unique_by(.id) and abort the whole --yes upgrade; it is filtered out.
cat > "$P8/.claude/agent/daemon.json" <<'EOF'
{
  "relays": ["wss://custom.relay.example"],
  "subscriptions": {
    "groups": ["oops-a-bare-string", {"id": "realgroup123", "name": "UNICITY_DEV_AGENTS"}],
    "dm_contacts": ["npub1owner"]
  },
  "hooks": {"on_dm": ".claude/hooks/on-dm.sh"}
}
EOF
OUT8="$(bash "$SETUP" "$P8" --yes </dev/null 2>&1)"; RC8=$?
D8="$P8/.claude/agent/daemon.json"
check "[ $RC8 -eq 0 ]" "malformed groups member did not abort the upgrade (exit 0)"
check "! grep -q 'daemon.json merge failed' <<< \"\$OUT8\"" "no daemon.json merge-failed die was reached"
check "jq -e '.subscriptions.groups | index(\"oops-a-bare-string\")' '$D8' >/dev/null; [ \$? -ne 0 ]" "bare-string groups member filtered out"
check "jq -e '.subscriptions.groups | map(select(type==\"object\")) | any(.id == \"realgroup123\")' '$D8' >/dev/null" "valid group object preserved"

echo ""
echo "== setup-idempotency: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
