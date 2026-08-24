#!/bin/bash
# Hermetic test for serena-reaper.sh — the SessionStart orphan-reaper for Serena
# MCP containers. Uses a FAKE `docker` (DOCKER_BIN) and a live-projects override
# file (SERENA_REAPER_LIVE_PROJECTS_FILE) so NO real Docker or processes are
# touched. Proves the safety invariant: a container is reaped ONLY when it is both
# older than the grace window AND has no live Serena client for its project.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
REAPER="$REPO/claude_conf/hooks/serena-reaper.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT
FIX="$SBX/fix"; mkdir -p "$FIX"

# --- Fake docker: answers ps / inspect / rm from fixture files under $FIX --------
FAKE="$SBX/docker"
cat > "$FAKE" <<'FAKEDOCKER'
#!/bin/bash
FIX="$FAKE_DOCKER_FIXTURES"
case "${1:-}" in
  ps)      cat "$FIX/ps.txt" 2>/dev/null || true ;;
  inspect)
    fmt="${3:-}"; cid="${4:-}"
    if [[ "$fmt" == *StartedAt* ]]; then cat "$FIX/$cid.started" 2>/dev/null || true
    else cat "$FIX/$cid.args" 2>/dev/null || true; fi ;;
  rm)      cid="${!#}"; echo "$cid" >> "$FIX/removed.txt" ;;
  *)       : ;;
esac
exit 0
FAKEDOCKER
chmod +x "$FAKE"

export FAKE_DOCKER_FIXTURES="$FIX"
export DOCKER_BIN="$FAKE"
export SERENA_ORPHAN_MAX_AGE_HOURS=48

# Helper: register a fake container (id, started-ISO, project)
mk_container() {
  local id="$1" started="$2" proj="$3"
  echo "$id" >> "$FIX/ps.txt"
  echo "$started" > "$FIX/$id.started"
  printf 'start-mcp-server\n--context\nagent\n--project\n%s\n' "$proj" > "$FIX/$id.args"
}
iso_hours_ago() { date -u -d "@$(( $(date +%s) - $1*3600 ))" +"%Y-%m-%dT%H:%M:%S.000000000Z"; }
reset_fix() { rm -f "$FIX"/*.txt "$FIX"/*.started "$FIX"/*.args 2>/dev/null || true; }
was_removed() { grep -qxF "$1" "$FIX/removed.txt" 2>/dev/null; }

echo "== serena-reaper: orphan detection & liveness safety =="

# ---- Case 1: old orphan, NO live client → REAPED --------------------------------
reset_fix
mk_container "cidOLDORPHAN" "$(iso_hours_ago 120)" "/home/u/repoA"   # 5 days old
: > "$SBX/live.empty"; export SERENA_REAPER_LIVE_PROJECTS_FILE="$SBX/live.empty"
bash "$REAPER" start </dev/null >/dev/null 2>&1
was_removed "cidOLDORPHAN" && ok "old orphan with no live client is reaped" || bad "old orphan NOT reaped"

# ---- Case 2: old but a LIVE client owns its project → KEPT -----------------------
reset_fix
mk_container "cidOLDLIVE" "$(iso_hours_ago 120)" "/home/u/repoLive"
printf '%s\n' "/home/u/repoLive" > "$SBX/live.one"
export SERENA_REAPER_LIVE_PROJECTS_FILE="$SBX/live.one"
bash "$REAPER" start </dev/null >/dev/null 2>&1
was_removed "cidOLDLIVE" && bad "old container with a LIVE client was WRONGLY reaped" \
  || ok "old container with a live client is KEPT (never kill a live session)"

# ---- Case 3: young orphan (age < grace) → KEPT (age guard) -----------------------
reset_fix
mk_container "cidYOUNG" "$(iso_hours_ago 2)" "/home/u/repoYoung"     # 2 hours old
: > "$SBX/live.empty2"; export SERENA_REAPER_LIVE_PROJECTS_FILE="$SBX/live.empty2"
bash "$REAPER" start </dev/null >/dev/null 2>&1
was_removed "cidYOUNG" && bad "young container was WRONGLY reaped (age guard failed)" \
  || ok "young container is KEPT (below grace window)"

# ---- Case 4: `list` mode reports the orphan but does NOT remove ------------------
reset_fix
mk_container "cidLISTME" "$(iso_hours_ago 120)" "/home/u/repoList"
: > "$SBX/live.empty3"; export SERENA_REAPER_LIVE_PROJECTS_FILE="$SBX/live.empty3"
OUT="$(bash "$REAPER" list </dev/null 2>/dev/null)"
echo "$OUT" | grep -q "cidLISTME" && echo "$OUT" | grep -q "ORPHAN" \
  && ! was_removed "cidLISTME" \
  && ok "list mode reports orphan without removing it" || bad "list mode behaved wrong"

# ---- Case 5: mixed batch — only the true orphan among several is reaped ----------
reset_fix
mk_container "cidMixOrphan" "$(iso_hours_ago 100)" "/home/u/dead"
mk_container "cidMixLive"   "$(iso_hours_ago 100)" "/home/u/alive"
mk_container "cidMixYoung"  "$(iso_hours_ago 1)"   "/home/u/dead"    # young, same dead proj
printf '%s\n' "/home/u/alive" > "$SBX/live.mix"
export SERENA_REAPER_LIVE_PROJECTS_FILE="$SBX/live.mix"
bash "$REAPER" start </dev/null >/dev/null 2>&1
if was_removed "cidMixOrphan" && ! was_removed "cidMixLive" && ! was_removed "cidMixYoung"; then
  ok "mixed batch: only the old, client-less container is reaped"
else
  bad "mixed batch reaped the wrong set (orphan=$(was_removed cidMixOrphan && echo y||echo n) live=$(was_removed cidMixLive && echo y||echo n) young=$(was_removed cidMixYoung && echo y||echo n))"
fi

# ---- Case 6: SERENA_REAPER_DISABLE=1 → no-op ------------------------------------
reset_fix
mk_container "cidDISABLED" "$(iso_hours_ago 120)" "/home/u/x"
: > "$SBX/live.empty4"; export SERENA_REAPER_LIVE_PROJECTS_FILE="$SBX/live.empty4"
SERENA_REAPER_DISABLE=1 bash "$REAPER" start </dev/null >/dev/null 2>&1
was_removed "cidDISABLED" && bad "disabled reaper still reaped" \
  || ok "SERENA_REAPER_DISABLE=1 is a full no-op"

echo
echo "serena-reaper: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
