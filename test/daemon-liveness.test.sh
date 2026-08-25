#!/usr/bin/env bash
# daemon-liveness.test.sh — L2.3 subscription-liveness safeguards.
# Covers the PURE heartbeat-staleness classifier and the `status --probe` exit-code contract
# (0 = OK, 3 = not running, 4 = DEGRADED). No relay / node_modules needed — status only reads
# the PID + heartbeat files.
set -u
FAIL=0
DIR="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON="$DIR/lib/sphere-daemon.mjs"
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; FAIL=1; }

echo "── heartbeatStale (pure) ──"
node --input-type=module -e '
  import { heartbeatStale } from "'"$DAEMON"'";
  const now = 1000000;
  const A = heartbeatStale(null, now) === true;                                   // missing → stale
  const B = heartbeatStale({ ts: now, effectiveIntervalSecs: 60 }, now) === false; // fresh → not stale
  const C = heartbeatStale({ ts: now - 200, effectiveIntervalSecs: 60 }, now) === true;  // 200 > 3*60 → stale
  const D = heartbeatStale({ ts: now - 100, effectiveIntervalSecs: 60 }, now) === false; // 100 < 180 → fresh
  const E = heartbeatStale({ ts: now - 20 }, now) === false;                       // default 60s interval → fresh
  if (A && B && C && D && E) { console.log("PURE_OK"); } else {
    console.log("PURE_FAIL", { A, B, C, D, E }); process.exit(1);
  }
' && ok "heartbeatStale classifies missing/fresh/stale" || bad "heartbeatStale"

echo "── status --probe exit codes ──"
PROJ="$(mktemp -d)"
mkdir -p "$PROJ/.claude/agent"
echo '{"hooks":{}}' > "$PROJ/.claude/agent/daemon.json"
echo '{}' > "$PROJ/.claude/agent/identity.json"
echo '{}' > "$PROJ/.claude/agent/config.json"
KEY="$(node -e 'const c=require("crypto");const p=require("path");process.stdout.write(c.createHash("sha1").update(p.resolve(process.argv[1])).digest("hex").slice(0,12))' "$PROJ")"
SD="/tmp/claude/$KEY"; mkdir -p "$SD"
NOW="$(date +%s)"

# (1) no PID file → exit 3
rm -f "$SD/sphere-daemon.pid"
node "$DAEMON" status --probe --project "$PROJ" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "no PID → exit 3" || bad "no PID exit was $rc (want 3)"

# (2) live PID + fresh heartbeat → exit 0, prints probe: OK
echo "$$" > "$SD/sphere-daemon.pid"    # this test shell is alive → kill -0 succeeds
printf '{"ts":%s,"pid":%s,"live":true,"watcher":true,"effectiveIntervalSecs":60}' "$NOW" "$$" > "$SD/daemon-heartbeat.json"
OUT="$(node "$DAEMON" status --probe --project "$PROJ" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && echo "$OUT" | grep -q "probe: OK"; } && ok "live + fresh hb → exit 0 (probe: OK)" || bad "live+fresh exit=$rc out='$OUT'"

# (3) live PID + STALE heartbeat → exit 4, prints DEGRADED
printf '{"ts":%s,"pid":%s,"live":true,"watcher":false,"effectiveIntervalSecs":60}' "$((NOW-1000))" "$$" > "$SD/daemon-heartbeat.json"
OUT="$(node "$DAEMON" status --probe --project "$PROJ" 2>&1)"; rc=$?
{ [ "$rc" -eq 4 ] && echo "$OUT" | grep -q "DEGRADED"; } && ok "live + stale hb → exit 4 (DEGRADED)" || bad "live+stale exit=$rc out='$OUT'"

# (4) plain status (no --probe) still works → exit 0, no probe line
OUT="$(node "$DAEMON" status --project "$PROJ" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && echo "$OUT" | grep -q "is running" && ! echo "$OUT" | grep -q "probe:"; } && ok "plain status unchanged" || bad "plain status exit=$rc out='$OUT'"

rm -f "$SD/sphere-daemon.pid" "$SD/daemon-heartbeat.json"; rmdir "$SD" 2>/dev/null; rm -rf "$PROJ"

if [ "$FAIL" -eq 0 ]; then echo "PASS daemon-liveness"; else echo "FAIL daemon-liveness"; exit 1; fi
