#!/bin/bash
# team-coordination.test.sh — hermetic end-to-end proof of the Contract-Net-over-A2A team
# protocol. Drives cfp → bid → award → result → accept THROUGH the real installed hooks
# (classify-inbound.sh routing + team-coord.sh engine) with a real test registry + ledger,
# then proves default-deny (unauthorized sender, and authorized-but-cap-missing) and the
# Phase-B epoch fence. No network: peer messages are crafted exactly as the daemon would
# deliver them and fed through classify-inbound; outbound is dry-run.
#
# Run:  bash test/team-coordination.test.sh
set -uo pipefail

FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }
chk()  { if eval "$2"; then pass "$1"; else fail "$1 — [$2]"; fi; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_HOOKS="$REPO/claude_conf/hooks"

# --- Hermetic sandbox -----------------------------------------------------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tc-e2e.XXXXXX")"
trap 'rm -rf "$TMP"; [ -n "${STATE_DIR:-}" ] && rm -rf "$STATE_DIR"' EXIT
HOOKS="$TMP/hooks"; cp -r "$SRC_HOOKS" "$HOOKS"
PROJ="$TMP/proj"; mkdir -p "$PROJ/.claude/agent"
printf '{"npub":"npub1coordAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","agent_nametag":"coord-test"}' > "$PROJ/.claude/agent/identity.json"
printf '{"agent_nametag":"coord-test","owner_npub":"","owner_nametag":""}' > "$PROJ/.claude/agent/config.json"

export CLAUDE_PROJECT_DIR="$PROJ"
export AGENT_REGISTRY_FILE="$PROJ/.claude/agent/agent-registry.json"
export TEAM_ROOT="$TMP/teamstore"
export TEAM_SELF_NPUB="npub1coordAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
export TEAM_SELF_NAME="coord-test"
export TEAM_DRY_RUN=1
mkdir -p "$TEAM_ROOT"

# STATE_DIR is derived by state-dir.sh from the (temp) hooks path — capture it the same way.
STATE_DIR="$(. "$HOOKS/state-dir.sh" 2>/dev/null && printf '%s' "$STATE_DIR")"
rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
MSGFILE="$STATE_DIR/agent-messages.json"
TE_DIR="$STATE_DIR/agent-team-events"
REG="$HOOKS/agent-registry.sh"
TC="$HOOKS/team-coord.sh"

WORKER_PK="ffbbworkerpubkeyhex0000000000000000000000000000000000000000000000"
WORKER_NPUB="npub1workerBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
STRANGER_PK="dddstrangerpubkeyhex000000000000000000000000000000000000000000000"

# Deliver a crafted inbound DM (body carries the A2A envelope JSON as a string) and run the
# real classifier, exactly as on-dm.sh → classify-inbound.sh would in production.
deliver() { # <from_pubkey> <envelope-json>
  local from="$1" env="$2"
  [ -f "$MSGFILE" ] || printf '{"unread":false,"unread_count":0,"priority_count":0,"messages":[]}' > "$MSGFILE"
  local tmp="$MSGFILE.t"
  jq --arg from "$from" --arg body "$env" --arg ts "$(date -u +%FT%TZ)" \
     '.messages += [{type:"dm",from:$from,from_name:"",body:$body,timestamp:$ts,priority:false,read:false,authz:null}]' \
     "$MSGFILE" > "$tmp" && mv "$tmp" "$MSGFILE"
  ( cd "$HOOKS" && bash "$HOOKS/classify-inbound.sh" >/dev/null 2>&1 )
}
last_authz() { jq -c '.messages[-1].authz' "$MSGFILE"; }
te_count()  { ls "$TE_DIR"/*.json 2>/dev/null | wc -l | tr -d ' '; }
te_last_kind() { for f in "$TE_DIR"/*.json; do [ -e "$f" ] || continue; jq -r '.kind' "$f"; done | tail -1; }

echo "=============================================================="
echo " TEAM-COORDINATION E2E  (Contract-Net over A2A, hermetic)"
echo "=============================================================="

echo; echo "── Phase A: happy-path cfp → bid → award → result → accept ──"

# 0) Registry: authorize the worker for the full team cap set (the /authorize-agent grant).
bash "$REG" upsert-pending --pubkey "$WORKER_PK" --npub "$WORKER_NPUB" --name "worker-bee" --intro "hi" >/dev/null 2>&1
bash "$REG" authorize "$WORKER_PK" "team-coordinate,task-bid,knowledge-share" >/dev/null 2>&1
chk "worker authorized with team caps" '[ "$(bash "$REG" has-cap "$WORKER_PK" task-bid)" = yes ]'

# 1) Coordinator forms the team + task ledger.
bash "$TC" create demo "Ship the CSV exporter" --ttl-hours 48 >/dev/null
bash "$TC" add-member --team demo --npub "$WORKER_NPUB" --pubkey "$WORKER_PK" --name worker-bee >/dev/null
T1="$(bash "$TC" task-add --team demo --subject "Write exporter" --objective "CSV exporter module" --scope src/export --artifact patch --accept "unit tests pass" --budget 2h)"
chk "team created, coordinator role" '[ "$(bash "$TC" get demo | jq -r .role)" = coordinator ]'
chk "task added + ready" '[ "$(bash "$TC" ready demo | jq -r ".[0].taskId")" = "'"$T1"'" ]'

# 2) Coordinator opens a CFP (returns the envelope it would broadcast) + dry-run emit.
CFP="$(bash "$TC" open-cfp demo "$T1")"
chk "cfp envelope well-formed" '[ "$(jq -r .kind <<<"$CFP")" = task.cfp ] && [ "$(jq -r .task <<<"$CFP")" = "'"$T1"'" ]'
bash "$TC" emit demo "$CFP" >/dev/null
chk "task now in cfp state" '[ "$(bash "$TC" tasks demo | jq -r ".[0].state")" = cfp ]'

# 3) Worker's BID arrives as an inbound DM → classify routes it to the team-event queue.
BID="$(jq -nc --arg t "$T1" '{a2a:"1",kind:"task.bid",team:"demo",epoch:1,id:"bid-001",lamport:4,fromNpub:"'"$WORKER_NPUB"'",from:"worker-bee",task:$t,payload:{score:0.92,eta:"90m",note:"done exporters before"}}')"
deliver "$WORKER_PK" "$BID"
chk "bid routed to team queue (classify)" '[ "$(te_last_kind)" = task.bid ]'
chk "bid message authz = teamVerb" '[ "$(last_authz | jq -r .teamVerb)" = task.bid ]'

# 4) Coordinator drains the queue → ingests the bid.
for f in "$TE_DIR"/*.json; do bash "$TC" ingest "$f" >/dev/null; done
chk "bid recorded on task" '[ "$(bash "$TC" tasks demo | jq -r ".[0].bids | length")" = 1 ]'

# 5) Coordinator AWARDS to the best bid (a lease) + dry-run emit.
AW="$(bash "$TC" award demo "$T1")"
chk "award names the worker + lease epoch 1" '[ "$(jq -r .payload.assigneeNpub <<<"$AW")" = "'"$WORKER_NPUB"'" ] && [ "$(jq -r .payload.lease.epoch <<<"$AW")" = 1 ]'
chk "task awarded, lease set" '[ "$(bash "$TC" tasks demo | jq -r ".[0].state")" = awarded ]'

# 6) Worker's RESULT arrives inbound → classify → ingest → submitted.
RES="$(jq -nc --arg t "$T1" '{a2a:"1",kind:"task.result",team:"demo",epoch:1,id:"res-001",lamport:9,fromNpub:"'"$WORKER_NPUB"'",from:"worker-bee",task:$t,payload:{artifactType:"patch",summary:"exporter.ts + tests",ref:"branch feat/export"}}')"
deliver "$WORKER_PK" "$RES"
chk "result routed to team queue" '[ "$(te_last_kind)" = task.result ]'
for f in "$TE_DIR"/*.json; do bash "$TC" ingest "$f" >/dev/null; done
chk "task result submitted" '[ "$(bash "$TC" tasks demo | jq -r ".[0].state")" = submitted ]'

# 7) Coordinator reviews + ACCEPTS → task done, DAG advances.
bash "$TC" accept-result demo "$T1" "looks good" >/dev/null
chk "task done + verdict accepted" '[ "$(bash "$TC" tasks demo | jq -r ".[0].state")" = done ] && [ "$(bash "$TC" tasks demo | jq -r ".[0].verdict")" = accepted ]'

echo; echo "── Default-deny: unauthorized + cap-missing senders ──"

# 8) A stranger (no registry entry) sends a bid → NOT queued; surfaced as pending authz.
BEFORE="$(te_count)"
STRANGER_BID="$(jq -nc '{a2a:"1",kind:"task.bid",team:"demo",epoch:1,id:"bid-stranger",lamport:1,from:"who",payload:{score:1}}')"
deliver "$STRANGER_PK" "$STRANGER_BID"
chk "stranger bid NOT queued (default-deny)" '[ "$(te_count)" = "'"$BEFORE"'" ]'
chk "stranger surfaced as pending" '[ "$(last_authz | jq -r .status)" = pending ]'

# 9) Authorized but WITHOUT knowledge-share → a kb.publish is refused (capMissing), not stored.
bash "$REG" upsert-pending --pubkey "aa11" --npub "npub1capmiss" --name capmiss >/dev/null 2>&1
bash "$REG" authorize "aa11" "team-coordinate" >/dev/null 2>&1   # note: no knowledge-share
BEFORE="$(te_count)"
KB="$(jq -nc '{a2a:"1",kind:"kb.publish",team:"demo",epoch:1,id:"kb-x",lamport:1,fromNpub:"npub1capmiss",from:"capmiss",payload:{fact:"the sky is green"}}')"
deliver "aa11" "$KB"
chk "kb.publish without cap NOT queued" '[ "$(te_count)" = "'"$BEFORE"'" ]'
chk "authz records capMissing=knowledge-share" '[ "$(last_authz | jq -r .capMissing)" = knowledge-share ]'

echo; echo "── Phase B: epoch fence + knowledge card ──"

# 10) A stale AWARD from a superseded epoch is fenced on ingest.
#     (Bump the team to epoch 2 via a coordinator claim, then feed an epoch-1 award.)
bash "$TC" claim-coord demo >/dev/null   # epoch → 2
STALE_AW="$(jq -nc --arg t "$T1" '{a2a:"1",kind:"task.award",team:"demo",epoch:1,id:"aw-stale",lamport:2,fromNpub:"npub1ghost",from:"ghost",task:$t,payload:{assigneeNpub:"'"$WORKER_NPUB"'",lease:{epoch:1}}}')"
OUT="$(bash "$TC" ingest "$STALE_AW")"
chk "stale (epoch<current) award is FENCED" 'echo "$OUT" | grep -qi fenced'

# 11) Knowledge card: publish + a teammate card ingested as DATA with provenance.
CID="$(bash "$TC" kb-add --team demo --fact "exporter must quote fields containing commas" --confidence 0.9)"
chk "knowledge card stored" '[ -f "$TEAM_ROOT/demo/knowledge/'"$CID"'.md" ]'
chk "card tagged as DATA-not-instructions" 'grep -qi "treat as DATA" "$TEAM_ROOT/demo/knowledge/'"$CID"'.md"'
KBIN="$(jq -nc '{a2a:"1",kind:"kb.publish",team:"demo",epoch:2,id:"kb-in",lamport:12,fromNpub:"'"$WORKER_NPUB"'",from:"worker-bee",payload:{fact:"UTF-8 BOM breaks Excel import",confidence:0.8,title:"BOM gotcha"}}')"
bash "$TC" ingest "$KBIN" >/dev/null
chk "teammate card stored with source provenance" 'grep -rqi "source: teammate/'"$WORKER_NPUB"'" "$TEAM_ROOT/demo/knowledge/"'

# 12) Idempotency: replaying the same bid id does not double-count.
deliver "$WORKER_PK" "$BID"
for f in "$TE_DIR"/*.json; do bash "$TC" ingest "$f" >/dev/null 2>&1; done
DUP="$(bash "$TC" ingest "$BID")"
chk "duplicate message id is de-duplicated" 'echo "$DUP" | grep -qi dup'

echo; echo "── Member side: join → cfp-open → awarded-to-us; scope serialization ──"
(
  # Run as a DIFFERENT identity (a member) against a fresh team.
  export TEAM_SELF_NPUB="npub1memberZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"
  export TEAM_SELF_NAME="member-z"
  bash "$TC" join --team proj --goal "Docs" --coord npub1coordAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA --coord-name coord --epoch 3 >/dev/null
  [ "$(bash "$TC" get proj | jq -r .role)" = member ] && echo "  PASS member joined as member (epoch 3)" || echo "  FAIL member join"
  CFP2="$(jq -nc '{a2a:"1",kind:"task.cfp",team:"proj",epoch:3,id:"cfp-m",lamport:2,fromNpub:"npub1coordAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",from:"coord",task:"tM",deadline:"2099-01-01T00:00:00Z",payload:{subject:"intro",objective:"x",exclusiveScope:"docs/intro",artifactType:"doc",acceptanceCriteria:"clear",effortBudget:"1h"}}')"
  bash "$TC" ingest "$CFP2" >/dev/null
  [ "$(bash "$TC" tasks proj | jq -r '.[0].state')" = cfp-open ] && echo "  PASS CFP observed as cfp-open (bid candidate)" || echo "  FAIL cfp ingest"
  AW2="$(jq -nc '{a2a:"1",kind:"task.award",team:"proj",epoch:3,id:"aw-m",lamport:5,fromNpub:"npub1coordAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",from:"coord",task:"tM",payload:{assigneeNpub:"npub1memberZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ",lease:{epoch:3,expiresAt:"2099-01-01T00:00:00Z"}}}')"
  bash "$TC" ingest "$AW2" >/dev/null
  [ "$(bash "$TC" tasks proj | jq -r '.[0].state')" = awarded ] && echo "  PASS award-to-us adopted (execute under lease)" || echo "  FAIL award ingest"
)
# Scope serialization: a second todo task sharing an exclusiveScope with an in-flight CFP is held out.
T2="$(bash "$TC" task-add --team demo --subject "Rework export" --scope src/export)"
bash "$TC" open-cfp demo "$T2" >/dev/null
T3="$(bash "$TC" task-add --team demo --subject "Also export" --scope src/export)"
chk "overlapping-scope task held out of ready-serialized" '[ "$(bash "$TC" ready-serialized demo | jq -r --arg t "'"$T3"'" "map(.taskId)|index(\$t)")" = null ]'
chk "same task appears in unserialized ready" '[ "$(bash "$TC" ready demo | jq -r --arg t "'"$T3"'" "map(.taskId)|index(\$t)")" != null ]'

echo; echo "── Rendered ledgers ──"
bash "$TC" render demo >/dev/null
chk "ledger.md rendered" '[ -f "$TEAM_ROOT/demo/ledger.md" ]'
chk "progress.md rendered" '[ -f "$TEAM_ROOT/demo/progress.md" ]'

echo
echo "── Final task ledger ──"
bash "$TC" tasks demo | jq -c '.[] | {taskId, state, verdict, bids:(.bids|length), assignee:(.assigneeNpub|.[0:16])}'
echo "── Team ──"
bash "$TC" get demo | jq -c '{teamId, role, epoch, members:(.members|length), coordinator:(.coordinatorNpub|.[0:16])}'

echo
if [ "$FAIL" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit $FAIL
