#!/bin/bash
# Hermetic tests for the T1 reverse-direction fence (consult-claude-mcp.mjs).
#
# Drives the wrapper as a real MCP stdio server with a scripted JSON-RPC client
# and a MOCK `claude` that records its argv — so we assert the SECURITY FENCE
# (read-only allowlist that config cannot widen, denylist, secret-deny, no
# --dangerously-skip-permissions, --strict-mcp-config) and the gating/caps
# (disabled-by-default, GPTBRIDGE_DISABLE kill-switch, size cap, single-flight)
# WITHOUT ever launching a real claude or codex. Node-only; no network.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
WRAPPER_SRC="$REPO_ROOT/claude_conf/hooks/gptbridge/consult-claude-mcp.mjs"
PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 0; }
[ -f "$WRAPPER_SRC" ] || { echo "FAIL: wrapper missing at $WRAPPER_SRC"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gptbridge-codex.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- shared scripted MCP client: initialize, then burst all requests, collect --
CLIENT="$WORK/mcp-client.mjs"
cat > "$CLIENT" <<'EOF'
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
const wrapper = process.argv[2];
const reqs = JSON.parse(readFileSync(process.argv[3], 'utf8')); // [{id, method, params}]
const child = spawn(process.execPath, [wrapper], { stdio: ['pipe', 'pipe', 'inherit'] });
const responses = {};
let buf = '';
const wantIds = new Set(reqs.map(r => r.id));
const send = (m) => child.stdin.write(JSON.stringify(m) + '\n');
child.stdout.on('data', (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.id === 1) { // init done → burst all real requests at once (tests concurrency)
      send({ jsonrpc: '2.0', method: 'notifications/initialized' });
      for (const r of reqs) send({ jsonrpc: '2.0', id: r.id, method: r.method, params: r.params });
      continue;
    }
    if (wantIds.has(m.id)) {
      responses[m.id] = m;
      if (Object.keys(responses).length === wantIds.size) finish();
    }
  }
});
const finish = () => { try { child.kill(); } catch {} process.stdout.write(JSON.stringify(responses)); process.exit(0); };
setTimeout(() => { finish(); }, 20000);
send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '0' } } });
EOF

# --- build a deployed-layout workspace: <ws>/.claude/hooks/gptbridge/wrapper ---
# args: $1 = ws dir, $2 = gptbridge JSON (config.gptbridge)
make_ws() {
  local ws="$1" gb="$2"
  mkdir -p "$ws/.claude/hooks/gptbridge" "$ws/.claude/agent"
  cp "$WRAPPER_SRC" "$ws/.claude/hooks/gptbridge/consult-claude-mcp.mjs"
  printf '{"gptbridge":%s}' "$gb" > "$ws/.claude/agent/config.json"
}

# --- mock claude: record argv, count invocations, optional sleep, emit result --
make_mock_claude() {
  local path="$1" argvlog="$2" countfile="$3" sleep_s="${4:-0}"
  cat > "$path" <<EOF
#!/bin/bash
# record full argv (NUL-safe-ish: one arg per line prefixed) then bump counter
printf '%s\n' "\$@" >> "$argvlog"
echo "---INVOCATION---" >> "$argvlog"
( flock 9; c=\$(cat "$countfile" 2>/dev/null || echo 0); echo \$((c+1)) > "$countfile"; ) 9>"$countfile.lock"
sleep "$sleep_s"
printf '{"type":"result","result":"MOCK-ANSWER"}\n'
EOF
  chmod +x "$path"
}

ENABLED='{"enabled":true,"codex":{"enabled":true,"consult_claude":{"max_turns":7,"timeout_s":30,"max_question_kb":8,"allowed_tools":["Read","Grep","Glob","LS"]}}}'

run_client() { # $1 ws, $2 requests-json-file → prints responses JSON ; env passed through
  local ws="$1" reqfile="$2"
  ( cd "$ws" && node "$CLIENT" "$ws/.claude/hooks/gptbridge/consult-claude-mcp.mjs" "$reqfile" )
}

echo "== gptbridge T1 reverse-wrapper fence =="

# ---------------------------------------------------------------------------
# 1. tools/list exposes exactly the single consult_claude tool
# ---------------------------------------------------------------------------
WS1="$WORK/ws1"; make_ws "$WS1" "$ENABLED"
echo '[{"id":2,"method":"tools/list","params":{}}]' > "$WORK/req1.json"
OUT="$(run_client "$WS1" "$WORK/req1.json")"
NTOOLS=$(printf '%s' "$OUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0));const t=r["2"].result.tools;console.log(t.length+":"+t.map(x=>x.name).join(","))')
[ "$NTOOLS" = "1:consult_claude" ] && ok "tools/list = [consult_claude]" || bad "tools/list wrong: $NTOOLS"

# ---------------------------------------------------------------------------
# 2. DISABLED by default (no gptbridge.enabled) → tool refuses, no claude spawn
# ---------------------------------------------------------------------------
WS2="$WORK/ws2"; make_ws "$WS2" '{"enabled":false,"codex":{"enabled":true}}'
MOCK2="$WORK/claude2"; ARGV2="$WORK/argv2.log"; CNT2="$WORK/cnt2"; : > "$ARGV2"; : > "$CNT2"
make_mock_claude "$MOCK2" "$ARGV2" "$CNT2" 0
echo '[{"id":3,"method":"tools/call","params":{"name":"consult_claude","arguments":{"question":"hi"}}}]' > "$WORK/req2.json"
OUT="$(CONSULT_CLAUDE_BIN="$MOCK2" run_client "$WS2" "$WORK/req2.json")"
ISERR=$(printf '%s' "$OUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0));const x=r["3"].result;console.log((x.isError?"1":"0")+":"+x.content[0].text.slice(0,60))')
case "$ISERR" in 1:*disabled*|1:*Enable*) ok "disabled config → refused ($ISERR)";; *) bad "disabled not refused: $ISERR";; esac
[ ! -s "$CNT2" ] && ok "disabled → claude never spawned" || bad "claude spawned while disabled (cnt=$(cat "$CNT2"))"

# ---------------------------------------------------------------------------
# 3. ENABLED happy path → spawns claude with the FENCED argv
# ---------------------------------------------------------------------------
WS3="$WORK/ws3"; make_ws "$WS3" "$ENABLED"
MOCK3="$WORK/claude3"; ARGV3="$WORK/argv3.log"; CNT3="$WORK/cnt3"; : > "$ARGV3"; : > "$CNT3"
make_mock_claude "$MOCK3" "$ARGV3" "$CNT3" 0
echo '[{"id":4,"method":"tools/call","params":{"name":"consult_claude","arguments":{"question":"what does the app do?"}}}]' > "$WORK/req3.json"
OUT="$(CONSULT_CLAUDE_BIN="$MOCK3" run_client "$WS3" "$WORK/req3.json")"
TEXT=$(printf '%s' "$OUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0));const x=r["4"].result;console.log((x.isError?"ERR":"OK")+":"+x.content[0].text)')
[ "$TEXT" = "OK:MOCK-ANSWER" ] && ok "enabled → returns claude result ($TEXT)" || bad "unexpected result: $TEXT"

ARGV_ONELINE=$(tr '\n' ' ' < "$ARGV3")
grep -q -- '--strict-mcp-config' "$ARGV3" && ok "argv has --strict-mcp-config (no MCP recursion)" || bad "missing --strict-mcp-config"
grep -q -- '--max-turns' "$ARGV3" && grep -qx '7' "$ARGV3" && ok "argv caps --max-turns 7 (from config)" || bad "max-turns not applied"
echo "$ARGV_ONELINE" | grep -q -- '--dangerously-skip-permissions' && bad "DANGER: --dangerously-skip-permissions present" || ok "no --dangerously-skip-permissions"
# allowlist line (exact) present, denylist names the dangerous tools
if grep -qx 'Read,Grep,Glob,LS' "$ARGV3"; then ok "allowedTools = Read,Grep,Glob,LS"; else bad "allowedTools wrong: $(grep -m1 Read "$ARGV3")"; fi
DENYLINE=$(grep -m1 'Bash' "$ARGV3" || true)
if echo "$DENYLINE" | grep -q 'Bash' && echo "$DENYLINE" | grep -q 'Write' && echo "$DENYLINE" | grep -q 'Edit' && echo "$DENYLINE" | grep -q 'WebFetch'; then
  ok "disallowedTools names Bash/Write/Edit/WebFetch"; else bad "denylist incomplete: $DENYLINE"; fi
# secret-deny reached the --settings payload
if echo "$ARGV_ONELINE" | grep -q '.secrets' && echo "$ARGV_ONELINE" | grep -q 'identity.json' && echo "$ARGV_ONELINE" | grep -q '.env'; then
  ok "secret denylist (.env/.secrets/identity.json) in --settings"; else bad "secret denylist missing from argv"; fi

# ---------------------------------------------------------------------------
# 4. Config CANNOT widen the allowlist (Bash requested → filtered out)
# ---------------------------------------------------------------------------
WS4="$WORK/ws4"
make_ws "$WS4" '{"enabled":true,"codex":{"enabled":true,"consult_claude":{"allowed_tools":["Bash","Read","Write","Grep"]}}}'
MOCK4="$WORK/claude4"; ARGV4="$WORK/argv4.log"; CNT4="$WORK/cnt4"; : > "$ARGV4"; : > "$CNT4"
make_mock_claude "$MOCK4" "$ARGV4" "$CNT4" 0
echo '[{"id":5,"method":"tools/call","params":{"name":"consult_claude","arguments":{"question":"q"}}}]' > "$WORK/req4.json"
CONSULT_CLAUDE_BIN="$MOCK4" run_client "$WS4" "$WORK/req4.json" >/dev/null
# the allowedTools value is the line equal to a comma-list of only-whitelisted tools
ALLOWVAL=$(grep -m1 -E '^(Read|Grep|Glob|LS)(,(Read|Grep|Glob|LS))*$' "$ARGV4" || true)
if [ -n "$ALLOWVAL" ] && ! echo "$ALLOWVAL" | grep -q 'Bash' && ! echo "$ALLOWVAL" | grep -q 'Write'; then
  ok "config widening blocked → allowedTools=$ALLOWVAL (Bash/Write filtered)"
else
  bad "config widening NOT blocked: allowVal='$ALLOWVAL'"
fi

# ---------------------------------------------------------------------------
# 5. empty question + oversized question → isError, no claude spawn
# ---------------------------------------------------------------------------
WS5="$WORK/ws5"; make_ws "$WS5" "$ENABLED"
MOCK5="$WORK/claude5"; ARGV5="$WORK/argv5.log"; CNT5="$WORK/cnt5"; : > "$ARGV5"; : > "$CNT5"
make_mock_claude "$MOCK5" "$ARGV5" "$CNT5" 0
BIG=$(node -e 'process.stdout.write("x".repeat(9*1024))')
node -e 'const fs=require("fs");const big=process.argv[1];fs.writeFileSync(process.argv[2],JSON.stringify([{id:6,method:"tools/call",params:{name:"consult_claude",arguments:{question:"   "}}},{id:7,method:"tools/call",params:{name:"consult_claude",arguments:{question:big}}}]))' "$BIG" "$WORK/req5.json"
OUT="$(CONSULT_CLAUDE_BIN="$MOCK5" run_client "$WS5" "$WORK/req5.json")"
E6=$(printf '%s' "$OUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0));console.log(r["6"].result.isError?"1":"0")')
E7=$(printf '%s' "$OUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0));const t=r["7"].result;console.log((t.isError?"1":"0")+":"+t.content[0].text.slice(0,40))')
[ "$E6" = "1" ] && ok "empty question → isError" || bad "empty question not rejected"
case "$E7" in 1:*too*large*) ok "oversized question → isError ($E7)";; *) bad "oversized not rejected: $E7";; esac
[ ! -s "$CNT5" ] && ok "bad inputs → claude never spawned" || bad "claude spawned on bad input (cnt=$(cat "$CNT5"))"

# ---------------------------------------------------------------------------
# 6. GPTBRIDGE_DISABLE=1 kills it mid-flight even with enabled config
# ---------------------------------------------------------------------------
WS6="$WORK/ws6"; make_ws "$WS6" "$ENABLED"
MOCK6="$WORK/claude6"; ARGV6="$WORK/argv6.log"; CNT6="$WORK/cnt6"; : > "$ARGV6"; : > "$CNT6"
make_mock_claude "$MOCK6" "$ARGV6" "$CNT6" 0
echo '[{"id":8,"method":"tools/call","params":{"name":"consult_claude","arguments":{"question":"hi"}}}]' > "$WORK/req6.json"
OUT="$(GPTBRIDGE_DISABLE=1 CONSULT_CLAUDE_BIN="$MOCK6" run_client "$WS6" "$WORK/req6.json")"
KILLED=$(printf '%s' "$OUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0));const x=r["8"].result;console.log((x.isError?"1":"0")+":"+x.content[0].text)')
case "$KILLED" in 1:*GPTBRIDGE_DISABLE*) ok "GPTBRIDGE_DISABLE=1 → refused ($KILLED)";; *) bad "kill-switch ignored: $KILLED";; esac
[ ! -s "$CNT6" ] && ok "kill-switch → claude never spawned" || bad "claude spawned despite kill-switch"

# ---------------------------------------------------------------------------
# 7. single-flight: two concurrent consults → exactly one runs, one is busy
# ---------------------------------------------------------------------------
WS7="$WORK/ws7"; make_ws "$WS7" "$ENABLED"
MOCK7="$WORK/claude7"; ARGV7="$WORK/argv7.log"; CNT7="$WORK/cnt7"; : > "$ARGV7"; : > "$CNT7"
make_mock_claude "$MOCK7" "$ARGV7" "$CNT7" 3   # sleep 3s so the 2nd arrives mid-flight
export GPTBRIDGE_STATE_DIR="$WORK/state7"
echo '[{"id":9,"method":"tools/call","params":{"name":"consult_claude","arguments":{"question":"a"}}},{"id":10,"method":"tools/call","params":{"name":"consult_claude","arguments":{"question":"b"}}}]' > "$WORK/req7.json"
OUT="$(CONSULT_CLAUDE_BIN="$MOCK7" run_client "$WS7" "$WORK/req7.json")"
unset GPTBRIDGE_STATE_DIR
SUMMARY=$(printf '%s' "$OUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0));let ok=0,busy=0;for(const id of ["9","10"]){const t=r[id].result;if(t.isError&&/single-flight|in flight/.test(t.content[0].text))busy++;else if(!t.isError)ok++;}console.log(ok+"/"+busy)')
CNT=$(cat "$CNT7" 2>/dev/null || echo 0)
[ "$SUMMARY" = "1/1" ] && ok "single-flight → 1 answered, 1 busy" || bad "single-flight wrong (ok/busy=$SUMMARY)"
[ "$CNT" = "1" ] && ok "single-flight → claude spawned exactly once" || bad "claude spawned $CNT times (expected 1)"

# ---------------------------------------------------------------------------
# 8. argv-injection defense: a question STARTING WITH `-` must reach claude on
#    stdin, NEVER as an argv flag (else "--dangerously-skip-permissions" as the
#    question text would defeat the whole fence).
# ---------------------------------------------------------------------------
WS8="$WORK/ws8"; make_ws "$WS8" "$ENABLED"
MOCK8="$WORK/claude8"; ARGV8="$WORK/argv8.log"; CNT8="$WORK/cnt8"; : > "$ARGV8"; : > "$CNT8"
make_mock_claude "$MOCK8" "$ARGV8" "$CNT8" 0
node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify([{id:11,method:"tools/call",params:{name:"consult_claude",arguments:{question:"--dangerously-skip-permissions --allowedTools Bash"}}}]))' "$WORK/req8.json"
OUT="$(CONSULT_CLAUDE_BIN="$MOCK8" run_client "$WS8" "$WORK/req8.json")"
R11=$(printf '%s' "$OUT" | node -e 'const r=JSON.parse(require("fs").readFileSync(0));const x=r["11"].result;console.log(x.isError?"ERR":"OK")')
[ "$R11" = "OK" ] && ok "malicious question accepted as data (ran)" || bad "malicious question path broke: $R11"
if grep -q -- 'dangerously-skip-permissions' "$ARGV8"; then bad "INJECTION: question reached argv as a flag"; else ok "question never appears in argv (fed on stdin)"; fi
grep -qx 'Read,Grep,Glob,LS' "$ARGV8" && ok "fence intact under injection attempt (allowlist unchanged)" || bad "fence altered under injection"

echo ""
echo "gptbridge-codex: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
