#!/usr/bin/env bash
# Hermetic tests for the rc_emit / team_emit hardening pass:
#   (1) rc_emit reaches the transport helper and reports its REAL result (no more
#       silent >/dev/null 2>&1 that turned a live send failure into an undiagnosable
#       "FAILED send" with no cause).
#   (2) OK/NACK surfacing: failure reason is captured + printed; fire-and-forget verbs
#       are labelled "sent (unconfirmed)"; reply-awaited verbs stay plain "sent".
#   (3) side-aware advise-skill: coordinator → /coordinator-advise, remote → /consult-coordinator.
#   (4) event-queue TTL reap of done consult + team events.
#
# A NODE STUB stands in for sphere-helper.mjs so the send path is exercised without a
# relay; a final OPTIONAL block does a real testnet send when RC_LIVE_TEST=1.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="$REPO/claude_conf/hooks"
RC="$HOOKS/remote-coord.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
chk() { local d="$1"; shift; if eval "$@"; then printf '  \033[32mPASS\033[0m %s\n' "$d"; PASS=$((PASS+1)); else printf '  \033[31mFAIL\033[0m %s\n' "$d"; FAIL=$((FAIL+1)); fi; }

# --- Node stub: emulates `send-dm` success/failure via STUB_FAIL ---------------
STUB="$TMP/stub-helper.mjs"
cat > "$STUB" <<'JS'
const a = process.argv.slice(2);
if (a[0] === 'send-dm') {
  if (process.env.STUB_FAIL === '1') { console.error('Error: No connected relays'); process.exit(1); }
  console.log(JSON.stringify({ status: 'sent', to: a[1] }));
  process.exit(0);
}
process.exit(0);
JS

# A throwaway identity file (contents unused by the stub, but the preflight requires it).
IDENT="$TMP/identity.json"; printf '{"npub":"npub1self","hex":"deadbeef"}' > "$IDENT"

# Shared env for driving the engine in isolation.
export COORD_ROOT="$TMP/coord"
export TEAM_ROOT="$TMP/team"
export TEAM_SPHERE_HELPER="$STUB"
export TEAM_IDENTITY_FILE="$IDENT"
export TEAM_SELF_NPUB="npub1self"
export TEAM_SELF_NAME="tester"
RECIP="npub1peerAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

echo "── (1)+(2) rc_emit surfacing + labeling (stubbed transport) ──"

# consult.advise is fire-and-forget → must be "sent (unconfirmed)".
ENV_ADVISE="$(bash "$RC" envelope consult.advise --consult c1 --payload '{}' 2>/dev/null)"
OUT="$(TEAM_DRY_RUN=0 STUB_FAIL=0 bash "$RC" emit "$ENV_ADVISE" --to "$RECIP" 2>&1)"; RC1=$?
chk "fire-and-forget send exits 0"                 '[ "'"$RC1"'" -eq 0 ]'
chk "fire-and-forget labelled sent (unconfirmed)"  'printf %s "'"$OUT"'" | grep -q "sent (unconfirmed) →"'
chk "fire-and-forget NOT labelled plain sent"      '! printf %s "'"$OUT"'" | grep -Eq "^sent → "'

# consult.request awaits a reply → plain "sent".
ENV_REQ="$(bash "$RC" envelope consult.request --consult c2 --payload '{}' 2>/dev/null)"
OUT2="$(TEAM_DRY_RUN=0 STUB_FAIL=0 bash "$RC" emit "$ENV_REQ" --to "$RECIP" 2>&1)"
chk "reply-awaited verb labelled plain sent"       'printf %s "'"$OUT2"'" | grep -Eq "sent → .*consult.request"'
chk "reply-awaited verb NOT marked unconfirmed"    '! printf %s "'"$OUT2"'" | grep -q "unconfirmed"'

# Forced failure → non-zero AND the helper's reason is surfaced (not swallowed).
OUT3="$(TEAM_DRY_RUN=0 STUB_FAIL=1 bash "$RC" emit "$ENV_ADVISE" --to "$RECIP" 2>&1)"; RC3=$?
chk "failed send exits non-zero"                   '[ "'"$RC3"'" -ne 0 ]'
chk "failed send prints FAILED"                    'printf %s "'"$OUT3"'" | grep -q "FAILED send →"'
chk "failed send SURFACES the relay reason"        'printf %s "'"$OUT3"'" | grep -q "No connected relays"'

# DRY-RUN still suppressed.
OUT4="$(TEAM_DRY_RUN=1 bash "$RC" emit "$ENV_ADVISE" --to "$RECIP" 2>&1)"
chk "TEAM_DRY_RUN=1 still dry-runs"                 'printf %s "'"$OUT4"'" | grep -q "DRY-RUN send →"'

echo "── (3) side-aware advise-skill ──"
# Default (fresh store, no threads) → coordinator.
chk "default side is coordinator"                  '[ "$(bash "'"$RC"'" self-side 2>/dev/null)" = "coordinator" ]'
chk "default advise-skill is /coordinator-advise"  '[ "$(bash "'"$RC"'" advise-skill 2>/dev/null)" = "/coordinator-advise" ]'
# Explicit override.
chk "RC_SELF_SIDE=remote → /consult-coordinator"   '[ "$(RC_SELF_SIDE=remote bash "'"$RC"'" advise-skill 2>/dev/null)" = "/consult-coordinator" ]'
chk "RC_SELF_SIDE=coordinator → /coordinator-advise" '[ "$(RC_SELF_SIDE=coordinator bash "'"$RC"'" advise-skill 2>/dev/null)" = "/coordinator-advise" ]'
# Derived remote: a side:local consult thread with no side:remote thread.
mkdir -p "$COORD_ROOT/consults"
printf '{"cid":"cL","side":"local","status":"sent"}' > "$COORD_ROOT/consults/cL.json"
chk "derived remote from a side:local thread"      '[ "$(bash "'"$RC"'" self-side 2>/dev/null)" = "remote" ]'
# A side:remote thread present → coordinator wins.
printf '{"cid":"cR","side":"remote","status":"open"}' > "$COORD_ROOT/consults/cR.json"
chk "a side:remote thread → coordinator"           '[ "$(bash "'"$RC"'" self-side 2>/dev/null)" = "coordinator" ]'

echo "── (4) event-queue TTL reap (consult + team) ──"
# Drive the reaper directly against isolated dirs (STATE_DIR is repo-derived, so we test
# the function on explicit dirs to stay hermetic).
( set +u
  . "$HOOKS/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"
  . "$RC" 2>/dev/null
  CE="$TMP/ce"; TE="$TMP/te"; mkdir -p "$CE" "$TE"
  OLD="$(date -u -d '-48 hours' +%Y-%m-%dT%H:%M:%SZ)"
  NEW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"id":"a","status":"done","processedAt":"%s"}' "$OLD" > "$CE/a.json"
  printf '{"id":"b","status":"done","processedAt":"%s"}' "$NEW" > "$CE/b.json"
  printf '{"id":"c","status":"queued"}'                        > "$CE/c.json"
  printf '{"id":"d","status":"done"}'                          > "$CE/d.json"   # legacy done, no ts
  printf '{"id":"t","status":"done","processedAt":"%s"}' "$OLD" > "$TE/t.json"
  CUT="$(date -u -d '-24 hours' +%Y-%m-%dT%H:%M:%SZ)"
  _rc_reap_event_dir "$CE" "$CUT"
  _rc_reap_event_dir "$TE" "$CUT"
  [ ! -f "$CE/a.json" ] || { echo "REAP-FAIL old-done kept"; exit 1; }
  [   -f "$CE/b.json" ] || { echo "REAP-FAIL fresh-done removed"; exit 1; }
  [   -f "$CE/c.json" ] || { echo "REAP-FAIL queued removed"; exit 1; }
  [ ! -f "$CE/d.json" ] || { echo "REAP-FAIL legacy-done kept"; exit 1; }
  [ ! -f "$TE/t.json" ] || { echo "REAP-FAIL team old-done kept"; exit 1; }
  echo "REAP-OK"
) > "$TMP/reap.out" 2>&1
chk "reap deletes aged/legacy done, keeps fresh+queued (consult+team)" 'grep -q "REAP-OK" "'"$TMP/reap.out"'"'

# --- OPTIONAL live send (real testnet relay) ----------------------------------
if [ "${RC_LIVE_TEST:-0}" = "1" ] && [ -n "${RC_LIVE_HELPER:-}" ] && [ -n "${RC_LIVE_IDENTITY:-}" ] && [ -n "${RC_LIVE_NPUB:-}" ]; then
  echo "── (live) real relay send to a throwaway npub ──"
  ENVL="$(bash "$RC" envelope consult.advise --consult live --payload '{}' 2>/dev/null)"
  LOUT="$(TEAM_SPHERE_HELPER="$RC_LIVE_HELPER" TEAM_IDENTITY_FILE="$RC_LIVE_IDENTITY" TEAM_DRY_RUN=0 \
          bash "$RC" emit "$ENVL" --to "$RC_LIVE_NPUB" 2>&1)"; LRC=$?
  chk "live send exits 0"                          '[ "'"$LRC"'" -eq 0 ]'
  chk "live send reports sent"                     'printf %s "'"$LOUT"'" | grep -q "sent"'
fi

echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] && { echo "ALL CHECKS PASSED"; exit 0; } || { echo "FAILURES"; exit 1; }
