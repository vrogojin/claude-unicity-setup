#!/bin/bash
# Hermetic test suite for the turnkey A2A layer:
#   (A) a2a.sh dispatcher — resolution (whoami), ticket issue/list, the manual daemon-path
#       ingest wrapper {from,body}, and a full v2 issue→ingest-redeem mutual-auth round-trip.
#   (B) daemon-session.sh — session refcount lifecycle: start (no double-start / adopt),
#       concurrent sessions, last-one-out stop, TTL reap. Uses a FAKE daemon (node stub) so
#       no relay/network is touched.
# Real schnorr + AES-GCM crypto IS exercised for the ticket path, so a resolvable node_modules
# is required (SKIP otherwise, like the sibling suites). Emits are TEAM_DRY_RUN=1; the v2 relay
# publish/fetch goes through TICKET_RELAY_STUB (file-drop, same JSON contract as the ws path).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
HOOKS="$REPO/claude_conf/hooks"
HELPER="$REPO/lib/sphere-helper.mjs"
A2A="$HOOKS/a2a.sh"
TICKET="$HOOKS/ticket.sh"
DS="$HOOKS/daemon-session.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT
mkdir -p "$SBX/proj/.claude/agent" "$SBX/coord"
export CLAUDE_PROJECT_DIR="$SBX/proj" COORD_ROOT="$SBX/coord" \
  TEAM_SPHERE_HELPER="$HELPER" TEAM_IDENTITY_FILE="$SBX/proj/.claude/agent/identity.json" \
  AGENT_REGISTRY_FILE="$SBX/registry.json" TEAM_SELF_NAME="test-coord" TEAM_DRY_RUN=1 \
  TICKET_RELAY_STUB="$SBX/relay"
NP="$(cd "$(dirname "$HELPER")/.." && pwd)/node_modules"
helper() { NODE_PATH="$NP:${NODE_PATH:-}" node "$HELPER" "$@"; }
sha12() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }

helper create-identity > "$SBX/proj/.claude/agent/identity.json" 2>/dev/null
printf '{"agent_nametag":"test-coord","transport":{"helper_path":"%s"}}' "$HELPER" > "$SBX/proj/.claude/agent/config.json"
if ! jq -e .npub "$SBX/proj/.claude/agent/identity.json" >/dev/null 2>&1; then
  echo "SKIP: sphere-helper/SDK not resolvable (node_modules missing) — cannot run crypto tests"; exit 0
fi

echo "== (A) a2a.sh dispatcher =="

# 1. whoami resolves self + helper + coord-root.
WHO="$(bash "$A2A" whoami 2>/dev/null)"
[ "$(echo "$WHO" | jq -r '.self.npub')" != "" ] && [ "$(echo "$WHO" | jq -r '.helper.present')" = "yes" ] \
  && [ "$(echo "$WHO" | jq -r '.identity.present')" = "yes" ] \
  && ok "whoami resolves self npub + helper + identity" || bad "whoami resolution"

# 2. caps enum is the registry's live list.
bash "$A2A" caps 2>/dev/null | grep -q "consult" && ok "caps lists the live enum" || bad "caps"

# 3. ingest wrapper rejects a non-hex --from (fail-closed). Capture first: a2a exits non-zero
# by design, which under `set -o pipefail` would otherwise mask the matched grep.
IHEX_OUT="$(bash "$A2A" ingest-redeem --from "not-hex" --body '{"kind":"ticket.redeem"}' 2>&1 || true)"
echo "$IHEX_OUT" | grep -qi 'must be a 64-hex' \
  && ok "ingest-redeem rejects non-hex --from" || bad "ingest-redeem hex validation"

# 4. Full v2 issue → ingest-redeem mutual-auth round-trip (the daemon-path handler, wrapped).
REDEEMER_ID="$SBX/redeemer.json"; helper create-identity > "$REDEEMER_ID" 2>/dev/null
RNPUB="$(jq -r .npub "$REDEEMER_ID")"; RHEX="$(helper npub-to-hex "$RNPUB" 2>/dev/null | jq -r .hex)"
# Issue a default (v2) ticket → the printed ut2_ line IS the bearer secret.
TICKET_STR="$(bash "$A2A" issue --caps consult,claim-area --ttl 30m --name "smoke-peer" 2>/dev/null | grep -E '^ut2_' | head -1)"
if printf '%s' "$TICKET_STR" | grep -Eq '^ut2_[A-Za-z0-9]{43}$'; then ok "issue mints a v2 ut2_ ticket"; else bad "issue v2 ($TICKET_STR)"; fi
SECRET="${TICKET_STR#ut2_}"; TID="t$(sha12 "$SECRET" | cut -c1-12)"
# The issuer's ledger holds it pending.
bash "$A2A" tickets pending 2>/dev/null | jq -e --arg t "$TID" 'any(.[]?; .tid==$t)' >/dev/null \
  && ok "tickets pending shows the freshly-issued ticket" || bad "tickets pending"
# Craft the inbound redeem exactly as the daemon delivers it and feed it through a2a ingest-redeem.
REDEEM_ENV="$(jq -nc --arg tid "$TID" --arg secret "$SECRET" --arg npub "$RNPUB" --arg name "smoke-peer" \
  '{a2a:"1", kind:"ticket.redeem", payload:{tid:$tid, secret:$secret, npub:$npub, name:$name}}')"
bash "$A2A" ingest-redeem --from "$RHEX" --body "$REDEEM_ENV" >/dev/null 2>&1
# The issuer must now have AUTHORIZED the redeemer's transport hex with the ticket caps.
ST="$(bash "$HOOKS/agent-registry.sh" status "$RHEX" 2>/dev/null)"
[ "$ST" = "authorized" ] && ok "ingest-redeem authorizes the redeemer (mutual-auth issuer side)" || bad "ingest-redeem authorize (status=$ST)"
# And the ticket flips to redeemed.
bash "$A2A" tickets redeemed 2>/dev/null | jq -e --arg t "$TID" 'any(.[]?; .tid==$t)' >/dev/null \
  && ok "ticket flips to redeemed after ingest" || bad "ticket status after redeem"

echo "== (B) daemon-session.sh lifecycle (fake daemon, no network) =="

# A fake sphere-daemon.mjs: start/status/stop against a marker file, so the refcount DECISION
# logic is exercised without a relay. daemon-session derives it as <helper dir>/sphere-daemon.mjs.
mkdir -p "$SBX/fakelib"
FAKE_HELPER="$SBX/fakelib/sphere-helper.mjs"; : > "$FAKE_HELPER"
cat > "$SBX/fakelib/sphere-daemon.mjs" <<'FAKE'
import { existsSync, writeFileSync, unlinkSync } from 'node:fs';
const cmd = process.argv[2];
const marker = process.env.FAKE_DAEMON_MARKER;
if (cmd === 'start') { writeFileSync(marker, String(process.pid)); console.log('Daemon running (PID '+process.pid+')'); }
else if (cmd === 'stop') { try { unlinkSync(marker); } catch {} console.log('Stopped daemon'); }
else if (cmd === 'status') { console.log(existsSync(marker) ? 'Daemon is running (PID 1)' : 'Daemon is not running.'); }
FAKE
export FAKE_DAEMON_MARKER="$SBX/fake-daemon.running"
# Point the daemon-session resolver at the fake, and give it its own state dir via a distinct
# project root (state-dir keys off the repo root == project dir).
dsenv() { env TEAM_SPHERE_HELPER="$FAKE_HELPER" FAKE_DAEMON_MARKER="$FAKE_DAEMON_MARKER" \
  CLAUDE_PROJECT_DIR="$SBX/proj" A2A_SESSION_ID="$1" bash "$DS" "$2"; }

# daemon.json must exist for the manager to act.
printf '{"relays":[],"hooks":{}}' > "$SBX/proj/.claude/agent/daemon.json"

# Session A starts → daemon should come up (detached spawn; give it a moment).
dsenv "sessA" start </dev/null >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8; do [ -f "$FAKE_DAEMON_MARKER" ] && break; sleep 0.3; done
[ -f "$FAKE_DAEMON_MARKER" ] && ok "SessionStart brings the daemon up (detached)" || bad "SessionStart did not start daemon"

# Session B starts → adopts (no second daemon; marker unchanged, no error). One live becomes two.
BEFORE="$(cat "$FAKE_DAEMON_MARKER" 2>/dev/null)"
dsenv "sessB" start </dev/null >/dev/null 2>&1
sleep 0.3
AFTER="$(cat "$FAKE_DAEMON_MARKER" 2>/dev/null)"
[ "$BEFORE" = "$AFTER" ] && [ -f "$FAKE_DAEMON_MARKER" ] && ok "second SessionStart adopts (no double-start)" || bad "double-start not prevented"

# Session A ends → B still live → daemon MUST remain.
dsenv "sessA" stop </dev/null >/dev/null 2>&1
[ -f "$FAKE_DAEMON_MARKER" ] && ok "one session out, another live → daemon kept" || bad "daemon killed while a session still live"

# Session B ends → last one out → daemon MUST stop.
dsenv "sessB" stop </dev/null >/dev/null 2>&1
[ ! -f "$FAKE_DAEMON_MARKER" ] && ok "last session out → daemon stopped" || bad "daemon not stopped on last-out"

# TTL reap: a stale mark from a crashed session must not pin the daemon forever.
SDIR="$(env CLAUDE_PROJECT_DIR="$SBX/proj" bash -c '. "'"$HOOKS"'/state-dir.sh"; printf "%s" "$STATE_DIR"')/daemon-sessions"
mkdir -p "$SDIR"; : > "$SDIR/ghost.mark"; touch -d '48 hours ago' "$SDIR/ghost.mark" 2>/dev/null || touch -t 202001010000 "$SDIR/ghost.mark"
dsenv "sessC" start </dev/null >/dev/null 2>&1; sleep 0.5
dsenv "sessC" stop  </dev/null >/dev/null 2>&1
[ ! -f "$FAKE_DAEMON_MARKER" ] && [ ! -f "$SDIR/ghost.mark" ] \
  && ok "stale (crashed) session mark reaped by TTL → not pinned alive" || bad "TTL reap of stale session"

echo ""
echo "── a2a-daemon-lifecycle: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
