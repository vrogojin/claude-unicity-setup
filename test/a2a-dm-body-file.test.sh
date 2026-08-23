#!/bin/bash
# Focused, hermetic test for `a2a dm --body-file` (regression: flag text was sent as the
# literal message body because a2a_dm had no --body-file parsing). No relay/network is
# touched — TEAM_SPHERE_HELPER points at a FAKE node stub that captures the piped stdin body,
# and a raw npub1… peer resolves locally (rc_resolve_target passes npub through). No crypto /
# node_modules needed, so this suite never SKIPs.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
A2A="$REPO/claude_conf/hooks/a2a.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT
mkdir -p "$SBX/proj/.claude/agent" "$SBX/coord"

# Fake sphere-helper: for `send-dm`, dump the piped stdin body to $CAPTURE_FILE and succeed.
cat > "$SBX/fake-helper.mjs" <<'EOF'
import { readFileSync, writeFileSync } from 'node:fs';
const argv = process.argv.slice(2);
if (argv[0] === 'send-dm') {
  const body = readFileSync(0, 'utf-8');
  writeFileSync(process.env.CAPTURE_FILE, body);
  console.log(JSON.stringify({ ok: true }));
  process.exit(0);
}
process.exit(0);
EOF

export CLAUDE_PROJECT_DIR="$SBX/proj" COORD_ROOT="$SBX/coord" \
  TEAM_SPHERE_HELPER="$SBX/fake-helper.mjs" \
  TEAM_IDENTITY_FILE="$SBX/proj/.claude/agent/identity.json" \
  AGENT_REGISTRY_FILE="$SBX/registry.json" TEAM_SELF_NAME="test-self"

PEER="npub1faketestpeer00000000000000000000000000000000000000000000000"

echo "== a2a dm --body-file =="

# 1. --body-file sends the FILE CONTENTS (not the flag string). The body deliberately
#    contains flag-looking text that the OLD parser would have swallowed as argv and sent
#    literally. Trailing newline is trimmed by the usual $(cat) idiom (same as the positional
#    and stdin forms), so we compare against that trimmed content, not the raw file.
printf 'line one\nline two with --flag looking text\n' > "$SBX/msg.txt"
EXPECT1="$(cat "$SBX/msg.txt")"
CAPTURE_FILE="$SBX/cap1" bash "$A2A" dm "$PEER" --body-file "$SBX/msg.txt" --no-intro >/dev/null 2>&1 || true
if [ -f "$SBX/cap1" ] && [ "$(cat "$SBX/cap1")" = "$EXPECT1" ] && grep -q -- '--flag looking text' "$SBX/cap1"; then
  ok "--body-file sends file contents (incl. flag-looking text), not the flag string"
else
  bad "--body-file did not send file contents (got: $(cat "$SBX/cap1" 2>/dev/null))"
fi

# 2. Positional form is unchanged: `a2a dm <peer> "message text"`.
CAPTURE_FILE="$SBX/cap2" bash "$A2A" dm "$PEER" "hello world" --no-intro >/dev/null 2>&1 || true
if [ -f "$SBX/cap2" ] && [ "$(cat "$SBX/cap2")" = "hello world" ]; then
  ok "positional message still works unchanged"
else
  bad "positional message broke (got: $(cat "$SBX/cap2" 2>/dev/null))"
fi

# 3. --body-file - reads stdin.
printf 'from stdin body' | CAPTURE_FILE="$SBX/cap3" bash "$A2A" dm "$PEER" --body-file - --no-intro >/dev/null 2>&1 || true
if [ -f "$SBX/cap3" ] && [ "$(cat "$SBX/cap3")" = "from stdin body" ]; then
  ok "--body-file - reads stdin"
else
  bad "--body-file - did not read stdin (got: $(cat "$SBX/cap3" 2>/dev/null))"
fi

# 4. Giving BOTH positional words AND --body-file is an error (nothing sent).
OUT="$(CAPTURE_FILE="$SBX/cap4" bash "$A2A" dm "$PEER" "words" --body-file "$SBX/msg.txt" --no-intro 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -f "$SBX/cap4" ] && printf '%s' "$OUT" | grep -qi 'not both'; then
  ok "positional + --body-file rejected (fail-closed, nothing sent)"
else
  bad "both-forms guard failed (rc=$rc)"
fi

# 5. A missing --body-file path is an error (nothing sent).
OUT="$(bash "$A2A" dm "$PEER" --body-file "$SBX/nope.txt" --no-intro 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'not found'; then
  ok "missing --body-file path rejected"
else
  bad "missing-file guard failed (rc=$rc)"
fi

# 6. Neither positional words nor --body-file → the original usage error is preserved.
OUT="$(bash "$A2A" dm "$PEER" --no-intro 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'usage: a2a dm'; then
  ok "empty message preserves usage error"
else
  bad "usage-error path changed (rc=$rc)"
fi

echo ""
echo "a2a-dm-body-file: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
