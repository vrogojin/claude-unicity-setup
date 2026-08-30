#!/usr/bin/env bash
# a2a-session-arm.test.sh — the SessionStart auto-process NUDGE + the event-driven queue
# watcher (feat/a2a-auto-process).
#
# Self-contained: builds a throwaway hooks dir with tiny STUBS for the siblings the scripts
# source (state-dir.sh) or call (classify-inbound.sh, remote-coord.sh), plus a fake
# .claude/agent/config.json so the install-guard passes. Covers the invariants that matter:
#   NUDGE (a2a-session-arm.sh)
#     • drain-once nudge fires for queued work items      → /process-agent-requests
#     • COORDINATION queue is first-class: consults+team+rc → /coordinator-advise + /team-work
#     • SAFETY block always present (request-only, default-deny) and never weakened
#     • event-driven WATCHER is armed (Monitor over a2a-queue-watch.sh), NOT a /loop interval
#     • a fresh watcher heartbeat suppresses re-arming (normally one watcher per repo)
#     • per-session debounce; done/skipped not counted; empty+no-arm → silent; no framework → silent
#   WATCHER (a2a-queue-watch.sh)
#     • primes (no emit for pre-existing backlog), emits once on a NEW queued id (names the skill),
#       and a pre-claimed id is NOT re-emitted (cross-watcher dedup)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"          # the real .claude/hooks with the scripts under test
FAIL=0
pass(){ echo "  ok   $1"; }
fail(){ echo "  FAIL $1"; FAIL=1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
H="$WORK/repo/.claude/hooks"; mkdir -p "$H/test" "$WORK/repo/.claude/agent"
cp "$SRC/a2a-session-arm.sh" "$SRC/a2a-queue-watch.sh" "$H/"
chmod +x "$H"/*.sh

# --- stub siblings ----------------------------------------------------------------------
SD="$WORK/state"; mkdir -p "$SD/agent-workitems" "$SD/agent-consult-events" "$SD/agent-team-events"
cat > "$H/state-dir.sh" <<EOF
STATE_DIR="$SD"; mkdir -p "\$STATE_DIR" 2>/dev/null || true
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$H/classify-inbound.sh"                       # no-op classify
printf '#!/usr/bin/env bash\ncase "$1" in consult-list) echo "[]";; *) echo "[]";; esac\nexit 0\n' > "$H/remote-coord.sh"
chmod +x "$H"/*.sh
printf '{"owner_npub":"x"}' > "$WORK/repo/.claude/agent/config.json"

export CLAUDE_PROJECT_DIR="$WORK/repo"
HOOK="$H/a2a-session-arm.sh"
run(){ printf '{"session_id":"%s","source":"startup","cwd":"%s"}' "$1" "$CLAUDE_PROJECT_DIR" | bash "$HOOK" 2>/dev/null; }
ctx(){ echo "$1" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null; }

echo "── drain-once nudge for a queued work item ──"
printf '{"id":"w1","status":"queued","unicityName":"krugol"}' > "$SD/agent-workitems/w1.json"
OUT="$(run sess-A)"; C="$(ctx "$OUT")"
echo "$C" | grep -q '/process-agent-requests'  && pass "→ /process-agent-requests" || fail "no process nudge: $OUT"
echo "$C" | grep -q '1 authorized 1:1'         && pass "counts the queued work item" || fail "count wrong: $C"
echo "$C" | grep -qi 'REQUEST-ONLY'            && pass "SAFETY: request-only present" || fail "safety block missing"
echo "$C" | grep -qi 'DEFAULT-DENY'            && pass "SAFETY: default-deny present" || fail "default-deny missing"
echo "$OUT" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null 2>&1 && pass "SessionStart output shape" || fail "bad output shape"

echo "── per-session debounce (same session_id → no re-nag) ──"
OUT2="$(run sess-A)"; [ -z "$OUT2" ] && pass "second SessionStart for sess-A is silent" || fail "re-nagged: $OUT2"

echo "── COORDINATION queue is first-class (consult + NON-consult kinds + team) ──"
rm -f "$SD/agent-workitems/"*.json
printf '{"id":"c1","status":"queued","kind":"consult.request"}' > "$SD/agent-consult-events/c1.json"
printf '{"id":"c2","status":"queued","kind":"conflict.open"}'   > "$SD/agent-consult-events/c2.json"
printf '{"id":"t1","status":"queued"}' > "$SD/agent-team-events/t1.json"
C3="$(ctx "$(run sess-B)")"
echo "$C3" | grep -q '/coordinator-advise' && pass "→ /coordinator-advise" || fail "no coordinator nudge: $C3"
echo "$C3" | grep -q '/team-work'          && pass "→ /team-work"          || fail "no team-work nudge"
echo "$C3" | grep -q '3 coordination'      && pass "counts ALL queued consult events incl conflict.open (2) + team (1)" || fail "coord count wrong (kind filter regressed?): $C3"

echo "── remote-coord OPEN consults are counted too ──"
rm -f "$SD/agent-consult-events/"*.json "$SD/agent-team-events/"*.json
cat > "$H/remote-coord.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in consult-list) echo '[{"id":"o1"},{"id":"o2"}]';; *) echo '[]';; esac
exit 0
EOF
chmod +x "$H/remote-coord.sh"
C4="$(ctx "$(run sess-Bo)")"
echo "$C4" | grep -q '2 coordination'      && pass "rc open consults counted (2)" || fail "rc_open not counted: $C4"
cat > "$H/remote-coord.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in consult-list) echo '[]';; *) echo '[]';; esac
exit 0
EOF
chmod +x "$H/remote-coord.sh"

echo "── event-driven WATCHER armed (Monitor, not /loop) ──"
rm -f "$SD/agent-consult-events/"*.json "$SD/agent-team-events/"*.json "$SD/a2a-queue-watch.heartbeat"
C5="$(ctx "$(run sess-C)")"
echo "$C5" | grep -q 'Monitor'                 && pass "arms via Monitor tool" || fail "no Monitor arm: $C5"
echo "$C5" | grep -q 'a2a-queue-watch.sh'       && pass "names the watcher script" || fail "no watcher script"
echo "$C5" | grep -qi 'do NOT set up an unconditional /loop' && pass "explicitly forbids /loop interval" || fail "no anti-loop note"

echo "── fresh heartbeat suppresses re-arming; empty queue → silent ──"
date -u +%s > "$SD/a2a-queue-watch.heartbeat"
OUT6="$(run sess-D)"; [ -z "$OUT6" ] && pass "fresh heartbeat + empty → silent (one watcher)" || fail "re-armed with live watcher: $OUT6"

echo "── watch disabled: done/skipped not counted, empty → silent ──"
export A2A_SESSION_ARM_WATCH=0
printf '{"id":"w2","status":"done"}' > "$SD/agent-workitems/w2.json"
printf '{"id":"w3","status":"skipped"}' > "$SD/agent-workitems/w3.json"
OUT7="$(run sess-E)"; [ -z "$OUT7" ] && pass "only done/skipped → silent" || fail "acted on non-queued: $OUT7"
rm -f "$SD/agent-workitems/"*.json
OUT8="$(run sess-F)"; [ -z "$OUT8" ] && pass "empty + watch off → silent" || fail "spurious output: $OUT8"
unset A2A_SESSION_ARM_WATCH

echo "── no framework installed → silent ──"
mv "$WORK/repo/.claude/agent/config.json" "$WORK/repo/.claude/agent/config.json.off"
printf '{"id":"w1","status":"queued"}' > "$SD/agent-workitems/w1.json"
OUT9="$(run sess-G)"; [ -z "$OUT9" ] && pass "no config.json → install-guard silent" || fail "acted without framework: $OUT9"
mv "$WORK/repo/.claude/agent/config.json.off" "$WORK/repo/.claude/agent/config.json"

echo "── watcher: prime (no backlog emit) + emit on NEW id + dedup ──"
WSD="$WORK/wstate"; mkdir -p "$WSD/agent-workitems" "$WSD/agent-consult-events" "$WSD/agent-team-events"
WH="$WORK/whooks"; mkdir -p "$WH"; cp "$SRC/a2a-queue-watch.sh" "$WH/"
cat > "$WH/state-dir.sh" <<EOF
STATE_DIR="$WSD"; mkdir -p "\$STATE_DIR" 2>/dev/null || true
EOF
chmod +x "$WH"/*.sh
export A2A_QUEUE_WATCH_INTERVAL=1
printf '{"id":"w-old","status":"queued"}' > "$WSD/agent-workitems/w-old.json"   # backlog present BEFORE start
mkdir -p "$WSD/a2a-queue-watch-seen/wi-w-race"                                    # pretend another watcher claimed w-race (scope-keyed)
( timeout 6 bash "$WH/a2a-queue-watch.sh" > "$WORK/watch.log" 2>/dev/null ) &
WPID=$!
sleep 2                                                                           # let it prime the backlog
printf '{"id":"w-new","status":"queued"}' > "$WSD/agent-workitems/w-new.json"     # NEW arrival
printf '{"id":"c-new","status":"queued","kind":"consult.request"}' > "$WSD/agent-consult-events/c-new.json"
printf '{"id":"w-race","status":"queued"}' > "$WSD/agent-workitems/w-race.json"   # new file, but id pre-claimed
sleep 3
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
WLOG="$(cat "$WORK/watch.log" 2>/dev/null)"
echo "$WLOG" | grep -q 'id w-new'  && echo "$WLOG" | grep -q '/process-agent-requests' && pass "emits WORK on new id" || fail "no new-work emit: $WLOG"
echo "$WLOG" | grep -q 'id c-new'  && echo "$WLOG" | grep -q '/coordinator-advise'      && pass "emits CONSULT on new id" || fail "no new-consult emit: $WLOG"
echo "$WLOG" | grep -q 'w-old'   && fail "emitted for primed backlog (should be silent)" || pass "primed backlog NOT emitted"
echo "$WLOG" | grep -q 'w-race'  && fail "emitted a pre-claimed id (dedup broken)"       || pass "pre-claimed id deduped (not emitted)"
unset A2A_QUEUE_WATCH_INTERVAL

echo ""
[ "$FAIL" -eq 0 ] && { echo "PASS a2a-session-arm"; exit 0; } || { echo "FAIL a2a-session-arm"; exit 1; }
