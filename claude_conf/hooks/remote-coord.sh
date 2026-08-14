#!/bin/bash
# remote-coord.sh — the REMOTE-AGENT coordination engine: peer-scoped consults,
# holistic advisories, and work-area claims/leases between AUTONOMOUS agents and a
# coordinator, layered on the same default-deny A2A substrate as team-coord.sh.
#
# WHY A SEPARATE MODULE (not more team-coord.sh verbs): team verbs are TEAM-scoped —
# a coordinator assigns CNP tasks to subordinate members inside a shared teamId. A
# REMOTE AGENT is an autonomous peer: it arrives with its OWN tasks and initiatives,
# needs no team membership, and talks to our coordinator only to (a) avoid conflicts
# on shared projects/features/files and (b) ask the coordinator — who holds the
# holistic full-stack view (all repos, deployments, secrets, service wiring) — to
# apply MATCHING changes on our side (e.g. a remote CRM change that needs the
# concierge-backend updated to match). Peer verbs therefore skip team_exists gating
# but keep every other guard: capability-gated per sender in OUR registry, signed
# transport, SIF on both directions, opt-in draining by a skill. team-coord.sh is
# untouched; classify-inbound.sh sources BOTH engines and routes by verb.
#
# DESIGN (see docs/team-coordination-remote-agents.md):
#   • Durable store <MEM_DIR>/coord/ (sibling of team/): consult threads, the
#     work-area claim registry, work-intent broadcasts, split negotiations, open
#     conflicts, the prior-work edge graph, announced peer initiatives, OUR
#     change-commitment ledger — JSON as truth, markdown re-rendered per mutation.
#   • Verbs: peer.announce · consult.request/advise/ack/commit_done ·
#     work.intent/status · area.claim/ack/heartbeat/release · split.propose/agree ·
#     conflict.open/resolve — mapped onto three NEW non-destructive caps
#     (self-directed / consult / claim-area) in the registry enum.
#   • PARALLEL-FRIENDLY BY DESIGN: claims are SOFT/ADVISORY — parallel work on the
#     same files is allowed; an overlapping claim never blocks, it surfaces an
#     overlap notice + the peers to coordinate with. The protocol ladder is
#     (1) avoidance via awareness (work.intent "who's-on-this?" broadcast + the
#     research-before-claim gate), (2) negotiation (split.propose partitions, or an
#     acknowledged parallelVersions run), (3) reconciliation (conflict.open with the
#     Overstory/Refinery escalation ladder clean → auto-merge → ai-resolve →
#     re-plan, routed through the coordinator as INTEGRATOR, never gatekeeper).
#   • Claim leases have heartbeats + stale-claim reaping (madebyaris TTL pattern);
#     an un-heartbeated claim quietly expires — it was advisory anyway.
#   • NOTHING auto-decides: ingest only records. Advisories, overlap acks, and
#     change-commitments are produced by /coordinator-advise with the admin in the
#     loop; applying a committed matching change still runs the normal local
#     workflow (branch, tests, PR, owner confirmation).
#   • Scope note: same-machine mailbox/claiming is covered by native Claude Code
#     Agent Teams — this engine's value is the FEDERATION layer (cross-machine/
#     cross-owner identity + capability grants + durable state). Outward schema
#     should ride the A2A v1.0 façade (see a2a-standard-facade memory) with these
#     kinds as an extension, not a parallel dialect.
#
# Dual-use, same as team-coord.sh / agent-registry.sh:
#   • SOURCED by classify-inbound.sh for the verb→capability map + event enqueue.
#   • Run as a CLI by /consult-coordinator (remote side) + /coordinator-advise (ours).
#
# INERT / OPT-IN: with no consults and no claims the module does nothing. Every
# mutation is driven by a skill the localhost session runs.
set -uo pipefail

RC_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"

# --- Runtime state dir (per-repo), shared with the rest of the A2A pipeline -----------
. "$RC_HOOK_DIR/state-dir.sh" 2>/dev/null || STATE_DIR="/tmp/claude"
CONSULT_EVENTS_DIR="$STATE_DIR/agent-consult-events"

# --- Registry + team engine helpers (identity, SIF, transport discovery) ---------------
# Guarded CLIs: sourcing only defines functions. team-coord.sh gives us the identity
# helpers (team_self_npub/team_self_name/team_identity_path) and _tc_sphere_helper so
# both engines resolve self + transport identically.
. "$RC_HOOK_DIR/agent-registry.sh" 2>/dev/null || true
. "$RC_HOOK_DIR/team-coord.sh" 2>/dev/null || true
RC_REGISTRY="$RC_HOOK_DIR/agent-registry.sh"
RC_SIF="$RC_HOOK_DIR/sif-guard.sh"

rc_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
_rc_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'; return; fi
  printf '%s-%s-%s' "$(date -u +%s)" "$$" "$(head -c8 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || echo rnd)"
}

# Self identity — reuse team-coord.sh helpers when present, else re-derive.
rc_self_npub() {
  if type team_self_npub >/dev/null 2>&1; then team_self_npub; return; fi
  [ -n "${TEAM_SELF_NPUB:-}" ] && { printf '%s' "$TEAM_SELF_NPUB"; return; }
  local id="$RC_HOOK_DIR/../agent/identity.json"
  [ -f "$id" ] && jq -r '.npub // ""' "$id" 2>/dev/null || true
}
rc_self_name() {
  if type team_self_name >/dev/null 2>&1; then team_self_name; return; fi
  [ -n "${TEAM_SELF_NAME:-}" ] && { printf '%s' "$TEAM_SELF_NAME"; return; }
  local c="$RC_HOOK_DIR/../agent/config.json"
  [ -f "$c" ] && jq -r '.agent_nametag // ""' "$c" 2>/dev/null || true
}

# ============================================================================
# Durable store: <MEM_DIR>/coord/ — sibling of team-coord.sh's team/ store
# ============================================================================
coord_root() {
  if [ -n "${COORD_ROOT:-}" ]; then printf '%s' "$COORD_ROOT"; return; fi
  if type team_root >/dev/null 2>&1; then
    printf '%s' "$(dirname "$(team_root)")/coord"; return
  fi
  local proj="${CLAUDE_PROJECT_DIR:-}"
  [ -n "$proj" ] || proj="$(cd "$RC_HOOK_DIR/../.." 2>/dev/null && pwd || true)"
  if [ -n "$proj" ]; then
    local slug; slug="$(printf '%s' "$proj" | sed 's#/#-#g')"
    printf '%s/.claude/projects/%s/memory/coord' "${HOME:-/tmp}" "$slug"
  else
    printf '%s' "$RC_HOOK_DIR/../agent/coord"
  fi
}
_rc_ensure_dir() { mkdir -p "$1" 2>/dev/null || true; }

# Atomic locked read-modify-write of a JSON file (same pattern as _tc_write).
_rc_write() {
  local f="$1"; shift
  local filter="$1"; shift
  local dir; dir="$(dirname "$f")"; _rc_ensure_dir "$dir"
  [ -f "$f" ] || printf '{}' > "$f"
  local lock="$f.lock" tmp="$f.tmp.$$"
  (
    flock -w 5 9 2>/dev/null || true
    if jq "$@" "$filter" "$f" > "$tmp" 2>/dev/null; then mv "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
  ) 9>"$lock"
}

_rc_areas_file()       { printf '%s/areas.json'       "$(coord_root)"; }
_rc_peers_file()       { printf '%s/peers.json'       "$(coord_root)"; }
_rc_commitments_file() { printf '%s/commitments.json' "$(coord_root)"; }
_rc_intents_file()     { printf '%s/intents.json'     "$(coord_root)"; }
_rc_splits_file()      { printf '%s/splits.json'      "$(coord_root)"; }
_rc_conflicts_file()   { printf '%s/conflicts.json'   "$(coord_root)"; }
_rc_edges_file()       { printf '%s/edges.jsonl'      "$(coord_root)"; }
_rc_consults_dir()     { printf '%s/consults'         "$(coord_root)"; }
_rc_seen_file()        { printf '%s/seen.json'        "$(coord_root)"; }

_rc_areas()       { local f; f="$(_rc_areas_file)";       [ -f "$f" ] && jq -c '.areas // []' "$f" || echo '[]'; }
_rc_commitments() { local f; f="$(_rc_commitments_file)"; [ -f "$f" ] && jq -c '.commitments // []' "$f" || echo '[]'; }
_rc_intents()     { local f; f="$(_rc_intents_file)";     [ -f "$f" ] && jq -c '.intents // []' "$f" || echo '[]'; }
_rc_splits()      { local f; f="$(_rc_splits_file)";      [ -f "$f" ] && jq -c '.splits // []' "$f" || echo '[]'; }
_rc_conflicts()   { local f; f="$(_rc_conflicts_file)";   [ -f "$f" ] && jq -c '.conflicts // []' "$f" || echo '[]'; }

# Lamport clock for peer-scope envelopes (coordination is single-authority — our
# coordinator — so no epoch fencing; the clock just orders consult threads).
rc_lamport_next() {
  local d; d="$(coord_root)"; _rc_ensure_dir "$d"
  local f="$d/lamport" cur next
  (
    flock -w 5 9 2>/dev/null || true
    cur="$( [ -f "$f" ] && cat "$f" 2>/dev/null || echo 0 )"; [ -n "$cur" ] || cur=0
    next=$((cur+1)); printf '%s' "$next" > "$f"; printf '%s' "$next"
  ) 9>"$f.lock"
}
rc_seen_check() {
  local f; f="$(_rc_seen_file)"; [ -f "$f" ] || return 1
  jq -e --arg id "$1" '(.ids // []) | index($id)' "$f" >/dev/null 2>&1
}
rc_seen_mark() {
  local f; f="$(_rc_seen_file)"; _rc_ensure_dir "$(dirname "$f")"
  [ -f "$f" ] || printf '{"ids":[]}' > "$f"
  _rc_write "$f" '.ids = ((.ids // []) + [$id] | (if (length>5000) then .[-5000:] else . end))' --arg id "$1"
}

# ============================================================================
# Verb ⇄ capability map (the authorization join point)
# ============================================================================
# Each peer verb requires the SENDER to hold a specific capability in OUR registry.
# Standing autonomy announcements → self-directed; consult fabric + conflict
# reconciliation (integrator judgment) → consult; the awareness/claim/negotiate
# fabric (who's-on-this broadcasts, advisory claims, split partitions) → claim-area.
# All three are NON-destructive: they let an authorized peer ASK/INFORM. Applying a
# matching change on our side still runs the normal local workflow with admin
# confirmation, and no claim verb can forbid anyone's parallel work.
rc_verb_cap() {
  case "$1" in
    peer.announce) echo "self-directed";;
    consult.request|consult.advise|consult.ack|consult.commit_done) echo "consult";;
    conflict.open|conflict.resolve) echo "consult";;
    work.intent|work.status|area.claim|area.ack|area.heartbeat|area.release|split.propose|split.agree) echo "claim-area";;
    *) echo "";;
  esac
}
rc_is_verb() { [ -n "$(rc_verb_cap "$1")" ]; }

# ============================================================================
# Inbound event queue (written by classify-inbound.sh, drained by /coordinator-advise
# on the coordinator side and /consult-coordinator on the remote side)
# ============================================================================
# rc_enqueue_event <from_pubkey> <ts> <envelope-json> <npub> <name>
# Idempotent by the envelope's own id (falls back to a content hash).
rc_enqueue_event() {
  local from="$1" ts="$2" env="$3" npub="${4:-}" name="${5:-}"
  _rc_ensure_dir "$CONSULT_EVENTS_DIR"
  local eid; eid="$(printf '%s' "$env" | jq -r '.id // ""' 2>/dev/null)"
  [ -n "$eid" ] && [ "$eid" != "null" ] || eid="$(printf '%s|%s' "$from" "$env" | sha1sum 2>/dev/null | cut -c1-16)"
  [ -n "$eid" ] || return 0
  local ef="$CONSULT_EVENTS_DIR/$eid.json"
  [ -f "$ef" ] && return 0
  local kind cid area
  kind="$(printf '%s' "$env" | jq -r '.kind // ""')"
  cid="$(printf '%s' "$env" | jq -r '.consult // ""')"
  area="$(printf '%s' "$env" | jq -r '.area // ""')"
  jq -nc --arg id "$eid" --arg from "$from" --arg npub "$npub" --arg name "$name" \
     --arg kind "$kind" --arg cid "$cid" --arg area "$area" \
     --argjson env "$env" --arg ts "$ts" --arg now "$(rc_now)" \
     '{id:$id, status:"queued", from_pubkey:$from, npub:$npub, unicityName:$name,
       kind:$kind, consult:$cid, area:$area, envelope:$env,
       receivedAt:$ts, enqueuedAt:$now}' > "$ef.tmp.$$" 2>/dev/null \
    && mv "$ef.tmp.$$" "$ef" 2>/dev/null || rm -f "$ef.tmp.$$" 2>/dev/null || true
  printf '%s' "$eid"
}

# ============================================================================
# Consult threads
# ============================================================================
# A consult thread is one remote↔coordinator conversation about intended or already-
# made work: "I intend to work on X — conflicts?" / "I changed CRM API Y — please
# apply the matching backend changes". side:remote = they opened it with us (we are
# the coordinator); side:local = we opened it with a remote coordinator.
rc_consult_open() {  # --to <npub|nametag> --intent I [--areas csv --repos csv --changes J --questions J --urgency u]
  local to="" intent="" areas="" repos="" changes='[]' questions='[]' urgency="normal"
  while [ $# -gt 0 ]; do case "$1" in
    --to) to="$2"; shift 2;; --intent) intent="$2"; shift 2;; --areas) areas="$2"; shift 2;;
    --repos) repos="$2"; shift 2;; --changes) changes="$2"; shift 2;;
    --questions) questions="$2"; shift 2;; --urgency) urgency="$2"; shift 2;; *) shift;; esac; done
  [ -n "$to" ] && [ -n "$intent" ] || { echo "ERR: --to <npub|nametag> and --intent required" >&2; return 1; }
  # Accept a nametag as the target: resolve (+cache) to an npub so the stored thread and
  # every later emit reference the canonical key. An npub/hex passes through unchanged.
  to="$(rc_resolve_target "${to#@}")" || { echo "ERR: could not resolve --to target" >&2; return 1; }
  echo "$changes"   | jq -e . >/dev/null 2>&1 || changes='[]'
  echo "$questions" | jq -e . >/dev/null 2>&1 || questions='[]'
  local cid; cid="c$(printf '%s%s%s' "$to" "$intent" "$(rc_now)" | sha1sum | cut -c1-10)"
  local d; d="$(_rc_consults_dir)"; _rc_ensure_dir "$d"
  local areasjson reposjson
  areasjson="$(printf '%s' "$areas" | tr ',' '\n' | sed '/^$/d' | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
  reposjson="$(printf '%s' "$repos" | tr ',' '\n' | sed '/^$/d' | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
  jq -nc --arg cid "$cid" --arg to "$to" --arg intent "$intent" --arg urgency "$urgency" \
     --argjson areas "$areasjson" --argjson repos "$reposjson" \
     --argjson changes "$changes" --argjson questions "$questions" --arg now "$(rc_now)" \
     '{cid:$cid, side:"local", peerNpub:$to, status:"sent", intent:$intent, urgency:$urgency,
       areas:$areas, repos:$repos, changes:$changes, questions:$questions,
       advisory:null, commitments:[], openedAt:$now}' > "$d/$cid.json.tmp.$$" \
    && mv "$d/$cid.json.tmp.$$" "$d/$cid.json"
  rc_render >/dev/null 2>&1 || true
  printf '%s\n' "$cid"
}
rc_consult_get()  { local f; f="$(_rc_consults_dir)/$1.json"; [ -f "$f" ] && cat "$f" || { echo '{}'; return 1; }; }
rc_consult_list() {  # [status-filter]
  local d; d="$(_rc_consults_dir)"; [ -d "$d" ] || { echo '[]'; return 0; }
  local out='[]' f
  for f in "$d"/*.json; do [ -e "$f" ] || continue
    out="$(jq -c --arg s "${1:-}" --slurpfile c "$f" \
      '. + [ $c[0] | select($s=="" or .status==$s) | {cid, side, status, peerNpub, intent, urgency, openedAt, receivedAt} ]' \
      <<<"$out" 2>/dev/null || echo "$out")"
  done
  printf '%s' "$out"
}
_rc_consult_patch() {  # <cid> <jq-expr> [jq-args...] — patch the thread object
  local cid="$1" expr="$2"; shift 2
  local f; f="$(_rc_consults_dir)/$cid.json"
  [ -f "$f" ] || { echo "ERR: no consult $cid" >&2; return 1; }
  _rc_write "$f" "$expr" "$@"
}

# Coordinator records its holistic advisory + change-commitments on a thread. Each
# commitment is work WE promise to do on OUR side (matching backend fix, config,
# redeploy) — it lands in the commitment ledger as pending, admin-confirmed later.
rc_advise() {  # <cid> --advisory TEXT [--conflicts JSON] [--commit "desc|scope" ...]
  local cid="$1"; shift
  local advisory="" conflicts='[]' commits=()
  while [ $# -gt 0 ]; do case "$1" in
    --advisory) advisory="$2"; shift 2;; --conflicts) conflicts="$2"; shift 2;;
    --commit) commits+=("$2"); shift 2;; *) shift;; esac; done
  [ -n "$advisory" ] || { echo "ERR: --advisory required" >&2; return 1; }
  echo "$conflicts" | jq -e . >/dev/null 2>&1 || conflicts='[]'
  local cjson='[]' c desc scope cmid
  for c in ${commits[@]+"${commits[@]}"}; do
    desc="${c%%|*}"; scope="${c#*|}"; [ "$scope" = "$c" ] && scope=""
    cmid="m$(printf '%s%s' "$cid" "$desc" | sha1sum | cut -c1-8)"
    cjson="$(jq -c --arg id "$cmid" --arg d "$desc" --arg s "$scope" '. + [{cmid:$id, description:$d, scope:$s}]' <<<"$cjson")"
    # Mirror into the local commitment ledger (the Stop gate surfaces pending ones).
    _rc_write "$(_rc_commitments_file)" '
      .commitments = ((.commitments // []) | map(select(.cmid != $id)))
      | .commitments += [{cmid:$id, consult:$cid, description:$d, scope:$s, status:"pending", createdAt:$now}]' \
      --arg id "$cmid" --arg cid "$cid" --arg d "$desc" --arg s "$scope" --arg now "$(rc_now)"
  done
  _rc_consult_patch "$cid" '.status="advised" | .advisory={text:$a, conflicts:$cf, at:$now} | .commitments=$cm' \
    --arg a "$advisory" --argjson cf "$conflicts" --argjson cm "$cjson" --arg now "$(rc_now)" || return 1
  rc_render >/dev/null 2>&1 || true
  local peer; peer="$(rc_consult_get "$cid" | jq -r '.peerNpub // ""')"
  rc_envelope consult.advise --consult "$cid" \
    --payload "$(jq -nc --arg a "$advisory" --argjson cf "$conflicts" --argjson cm "$cjson" \
      '{advisory:$a, conflicts:$cf, commitments:$cm}')"
}

rc_commit_done() {  # <cmid> [note] — mark a commitment applied; returns consult.commit_done envelope
  local cmid="$1" note="${2:-}"
  local cid; cid="$(_rc_commitments | jq -r --arg id "$cmid" '.[] | select(.cmid==$id) | .consult // ""')"
  [ -n "$cid" ] || { echo "ERR: no commitment $cmid" >&2; return 1; }
  _rc_write "$(_rc_commitments_file)" \
    '.commitments = ((.commitments // []) | map(if .cmid==$id then (.status="applied" | .appliedAt=$now | .note=$n) else . end))' \
    --arg id "$cmid" --arg now "$(rc_now)" --arg n "$note"
  rc_render >/dev/null 2>&1 || true
  rc_envelope consult.commit_done --consult "$cid" \
    --payload "$(jq -nc --arg id "$cmid" --arg n "$note" '{cmid:$id, status:"applied", note:$n}')"
}

# ============================================================================
# Work-area claims (SOFT/ADVISORY awareness map at feature/component/file granularity)
# ============================================================================
# An AREA is a named slice of shared surface: "crm-service", "concierge-backend:
# backend/src/tasks/**", "feature:persona-v2". The claim registry is the shared
# "who is working where" map — broader-lived than a single CNP task's exclusiveScope.
# UNLIKE a CNP award lease, a claim is NOT exclusive: parallel work on the same
# files is allowed. A claim is registered immediately (no grant needed to proceed);
# overlap surfaces a NOTICE naming the peers to coordinate with (→ split.propose or
# an acknowledged parallelVersions run), never a block. Leases exist only for
# liveness: claims are heartbeated and stale ones are reaped after the TTL
# (RC_AREA_TTL_HOURS, default 72; use minutes-scale TTLs for hot editing surfaces).
# Scope matching is advisory prefix/token overlap; humans/models judge semantics.
rc_area_upsert() {  # --area ID --scope csv --holder npub [--name N --side remote|local --status S --ttl-hours H --note T]
  local id="" scope="" holder="" name="" side="remote" status="requested" ttl="72" note=""
  while [ $# -gt 0 ]; do case "$1" in
    --area) id="$2"; shift 2;; --scope) scope="$2"; shift 2;; --holder) holder="$2"; shift 2;;
    --name) name="$2"; shift 2;; --side) side="$2"; shift 2;; --status) status="$2"; shift 2;;
    --ttl-hours) ttl="$2"; shift 2;; --note) note="$2"; shift 2;; *) shift;; esac; done
  [ -n "$id" ] && [ -n "$holder" ] || { echo "ERR: --area and --holder required" >&2; return 1; }
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=72
  local scopejson; scopejson="$(printf '%s' "$scope" | tr ',' '\n' | sed '/^$/d' | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
  local exp; exp="$(date -u -d "+${ttl} hours" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || rc_now)"
  _rc_write "$(_rc_areas_file)" '
    .areas = ((.areas // []) | map(select(.areaId != $id)))
    | .areas += [{areaId:$id, scope:$scope, holderNpub:$holder, holderName:$name, side:$side,
                  status:$status, lease:{expiresAt:$exp}, note:$note, updatedAt:$now}]' \
    --arg id "$id" --argjson scope "$scopejson" --arg holder "$holder" --arg name "$name" \
    --arg side "$side" --arg status "$status" --arg exp "$exp" --arg note "$note" --arg now "$(rc_now)" \
    && { rc_render >/dev/null 2>&1 || true; printf '%s\n' "$id"; }
}
_rc_area_patch() {  # <areaId> <jq-expr on the area object as .>
  _rc_write "$(_rc_areas_file)" '.areas = ((.areas // []) | map(if .areaId==$id then ('"$2"') else . end))' --arg id "$1"
}
rc_area_list() {  # [status-filter] — expired active leases are reported as expired
  jq -c --arg s "${1:-}" --arg now "$(rc_now)" '
    map(if (.status=="active" and (.lease.expiresAt // "") < $now and (.lease.expiresAt // "") != "")
        then (.status="expired") else . end)
    | map(select($s=="" or .status==$s))' <<<"$(_rc_areas)"
}
# rc_area_check <scope-csv> → active areas whose scope overlaps (prefix either way,
# case-insensitive). ADVISORY: catches "same repo/path/feature", not semantics.
rc_area_check() {
  local q; q="$(printf '%s' "${1:-}" | tr ',' '\n' | sed '/^$/d' | jq -R 'ascii_downcase' | jq -sc . 2>/dev/null || echo '[]')"
  rc_area_list active | jq -c --argjson q "$q" '
    map(select(
      ((.scope // []) | map(ascii_downcase)) as $held
      | any($q[]; . as $c | any($held[]; . as $h | (($h | startswith($c)) or ($c | startswith($h)))))
    ))'
}
rc_area_ack() {  # <areaId> [advice] — advisory response to a claim: computed overlaps
  # + coordination advice. NEVER a permission: the claimant already holds the (soft)
  # claim; this tells them who else is on the surface and how to coordinate.
  local id="$1" advice="${2:-}"
  local scope; scope="$(_rc_areas | jq -r --arg id "$id" '.[] | select(.areaId==$id) | (.scope // []) | join(",")')"
  local overlaps; overlaps="$(rc_area_check "$scope" | jq -c --arg id "$id" 'map(select(.areaId != $id) | {areaId, holderNpub, holderName, scope})')"
  _rc_area_patch "$id" ".ackAt=\"$(rc_now)\"" >/dev/null 2>&1
  rc_render >/dev/null 2>&1 || true
  rc_envelope area.ack --area "$id" \
    --payload "$(jq -nc --argjson o "${overlaps:-[]}" --arg a "$advice" '{overlaps:$o, advice:$a}')"
}
rc_area_heartbeat() {  # <areaId> [--ttl-hours H] — renew our claim's lease; returns envelope
  local id="$1"; shift
  local ttl="${RC_AREA_TTL_HOURS:-72}"
  while [ $# -gt 0 ]; do case "$1" in --ttl-hours) ttl="$2"; shift 2;; *) shift;; esac; done
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=72
  local exp; exp="$(date -u -d "+${ttl} hours" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || rc_now)"
  _rc_area_patch "$id" ".status=\"active\" | .lease={expiresAt:\"$exp\"} | .heartbeatAt=\"$(rc_now)\"" || return 1
  rc_render >/dev/null 2>&1 || true
  rc_envelope area.heartbeat --area "$id" --payload "$(jq -nc --arg e "$exp" '{lease:{expiresAt:$e}}')"
}
rc_area_release() {  # <areaId> — local-side release; returns area.release envelope
  _rc_area_patch "$1" ".status=\"released\" | .releasedAt=\"$(rc_now)\"" || return 1
  rc_render >/dev/null 2>&1 || true
  rc_envelope area.release --area "$1" --payload '{}'
}
rc_reap() {  # mark active claims past their lease as expired (stale-claim reaping).
  # Mechanical tier-0 pass (Overstory watchdog pattern) — safe because claims are
  # advisory: expiring one blocks nobody, it just stops asserting presence.
  _rc_write "$(_rc_areas_file)" '
    .areas = ((.areas // []) | map(
      if (.status=="active" and (.lease.expiresAt // "") != "" and (.lease.expiresAt // "") < $now)
      then (.status="expired" | .reapedAt=$now) else . end))' --arg now "$(rc_now)" \
    && { rc_render >/dev/null 2>&1 || true; rc_area_list expired | jq -r 'map(.areaId) | join(" ")'; }
}

# ============================================================================
# Work-intent broadcasts ("who's-on-this?") — awareness BEFORE claiming
# ============================================================================
# The research-before-claim gate's LIVE half: before starting a task/feature/bug an
# agent (a) queries the prior-work graph (/recall-prior-work) and (b) broadcasts
# work.intent to ALL peers, collecting work.status replies within a window. If a
# peer is already on it: negotiate a split (split.propose) or proceed as an
# acknowledged parallelVersions run. Silence past the window = no overlap, claim.
rc_intent_open() {  # --subject S --area csv [--approach A] [--deadline ISO | --window-mins M]
  # (--intent/--scope accepted as aliases.) --approach is a free tag for the
  # deliberate parallel-versions case ("trying approach X — others welcome on Y").
  # --deadline mirrors open-cfp's reply window; --window-mins is the convenience form.
  local subject="" scope="" approach="" deadline="" window="30"
  while [ $# -gt 0 ]; do case "$1" in
    --subject|--intent) subject="$2"; shift 2;; --area|--scope) scope="$2"; shift 2;;
    --approach) approach="$2"; shift 2;; --deadline) deadline="$2"; shift 2;;
    --window-mins) window="$2"; shift 2;; *) shift;; esac; done
  [ -n "$subject" ] || { echo "ERR: --subject required" >&2; return 1; }
  [[ "$window" =~ ^[0-9]+$ ]] || window=30
  [ -n "$deadline" ] || deadline="$(date -u -d "+${window} minutes" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || rc_now)"
  local iid; iid="i$(printf '%s%s' "$subject" "$(rc_now)" | sha1sum | cut -c1-8)"
  local scopejson; scopejson="$(printf '%s' "$scope" | tr ',' '\n' | sed '/^$/d' | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
  _rc_write "$(_rc_intents_file)" '
    .intents = ((.intents // []) + [{iid:$iid, side:"local", subject:$i, approach:$a,
      scope:$s, windowUntil:$u, responses:[], status:"open", openedAt:$now}])' \
    --arg iid "$iid" --arg i "$subject" --arg a "$approach" --argjson s "$scopejson" \
    --arg u "$deadline" --arg now "$(rc_now)" \
    && { rc_render >/dev/null 2>&1 || true; printf '%s\n' "$iid"; }
}
# rc_intent_check <scope-csv> → our LIVE local intents whose scope overlaps (same
# prefix/token match as rc_area_check) — so an inbound work.intent is checked against
# both what we CLAIM and what we have ANNOUNCED we are about to do.
rc_intent_check() {
  local q; q="$(printf '%s' "${1:-}" | tr ',' '\n' | sed '/^$/d' | jq -R 'ascii_downcase' | jq -sc . 2>/dev/null || echo '[]')"
  _rc_intents | jq -c --argjson q "$q" '
    map(select(.side=="local" and .status=="open"
      and (((.scope // []) | map(ascii_downcase)) as $held
           | any($q[]; . as $c | any($held[]; . as $h | (($h | startswith($c)) or ($c | startswith($h))))))))
    | map({iid, subject, approach, scope})'
}
_rc_intent_patch() {  # <iid> <jq-expr> [jq-args...]
  local iid="$1" expr="$2"; shift 2
  _rc_write "$(_rc_intents_file)" '.intents = ((.intents // []) | map(if .iid==$iid then ('"$expr"') else . end))' --arg iid "$iid" "$@"
}
# rc_intent_result <iid> → summarize replies once the window passed:
#   none → clear-to-claim; overlap replies → the peers to negotiate with.
rc_intent_result() {
  _rc_intents | jq -c --arg iid "$1" --arg now "$(rc_now)" '
    (.[] | select(.iid==$iid)) as $i
    | {iid:$iid, windowClosed: (($i.windowUntil // "") < $now),
       overlapping: [ ($i.responses // [])[] | select(.onIt == true) ],
       verdict: (if ([ ($i.responses // [])[] | select(.onIt == true) ] | length) == 0
                 then "clear-to-claim" else "coordinate-or-split" end)}'
}

# ============================================================================
# Split negotiation — partition overlapping work, or acknowledge parallel versions
# ============================================================================
# When work.intent (or a claim overlap notice) finds peers on the same surface, the
# peers negotiate autonomously: either a PARTITION (each party owns a disjoint
# slice) or a deliberate PARALLEL-VERSIONS run (both proceed knowingly — allowed,
# e.g. to try competing approaches). Escalation to human admins is an optional
# branch when the split or the winning approach needs a judgment call.
rc_split_propose() {  # --subject S --parts 'npub=slice-desc|scope' [--parts ...]
  #                     [--about <iid-or-areaId>] [--parallel-versions] [--note T] [--emit]
  # Each --parts entry proposes one NON-overlapping slice: its owner npub, a short
  # slice description, and (after "|") the scope it covers. --parallel-versions means
  # "we intend different approaches — skip the split, both proceed knowingly" (the
  # decision is recorded, no partition needed). --emit sends the envelope to every
  # non-self part owner directly (otherwise the envelope is printed for the caller
  # to emit). Recipients accept via split.agree OR consult.ack{sid}, or counter with
  # another split.propose.
  local subject="" about="" pv="false" note="" do_emit=0 parts=()
  while [ $# -gt 0 ]; do case "$1" in
    --subject) subject="$2"; shift 2;; --about) about="$2"; shift 2;;
    --parts) parts+=("$2"); shift 2;; --parallel-versions) pv="true"; shift;;
    --note) note="$2"; shift 2;; --emit) do_emit=1; shift;; *) shift;; esac; done
  [ -n "$subject" ] || { echo "ERR: --subject required" >&2; return 1; }
  { [ "$pv" = "true" ] || [ "${#parts[@]}" -gt 0 ]; } || { echo "ERR: --parts required (or --parallel-versions)" >&2; return 1; }
  # Parse 'npub=slice-desc|scope' → {owner, slice, scope}
  local partition='[]' p owner rest slice pscope
  for p in ${parts[@]+"${parts[@]}"}; do
    owner="${p%%=*}"; rest="${p#*=}"
    slice="${rest%%|*}"; pscope="${rest#*|}"; [ "$pscope" = "$rest" ] && pscope=""
    [ -n "$owner" ] && [ "$owner" != "$p" ] || { echo "ERR: bad --parts '$p' (want npub=slice-desc|scope)" >&2; return 1; }
    partition="$(jq -c --arg o "$owner" --arg sl "$slice" --arg sc "$pscope" \
      '. + [{owner:$o, slice:$sl, scope:$sc}]' <<<"$partition")"
  done
  local sid; sid="s$(printf '%s%s' "$subject" "$(rc_now)" | sha1sum | cut -c1-8)"
  _rc_write "$(_rc_splits_file)" '
    .splits = ((.splits // []) + [{sid:$sid, side:"local", subject:$subject, about:$about,
      partition:$p, parallelVersions:($pv=="true"), note:$note, status:"proposed", proposedAt:$now}])' \
    --arg sid "$sid" --arg subject "$subject" --arg about "$about" --argjson p "$partition" \
    --arg pv "$pv" --arg note "$note" --arg now "$(rc_now)"
  rc_render >/dev/null 2>&1 || true
  local env; env="$(rc_envelope split.propose \
    --payload "$(jq -nc --arg sid "$sid" --arg subject "$subject" --arg about "$about" \
        --argjson p "$partition" --argjson pv "$pv" --arg note "$note" \
        '{sid:$sid, subject:$subject, about:$about, partition:$p, parallelVersions:$pv, note:$note}')")"
  if [ "$do_emit" = "1" ]; then
    local me; me="$(rc_self_npub)"
    local sent=() o
    while IFS= read -r o; do
      [ -n "$o" ] && [ "$o" != "$me" ] || continue
      case " ${sent[*]:-} " in *" $o "*) continue;; esac
      # Only count a recipient as sent when rc_emit actually succeeded — it now returns
      # non-zero on a missing transport / send failure (#20), so an unconditional sent+=()
      # would mislabel a dropped split.propose as delivered.
      if rc_emit "$env" --to "$o"; then sent+=("$o"); else echo "WARN(split.propose): emit FAILED → $o (not counted as sent)" >&2; fi
    done < <(jq -r '.[].owner' <<<"$partition")
    printf '%s\n' "$env"
  else
    printf '%s\n' "$env"
  fi
}
_rc_split_patch() {  # <sid> <jq-expr> [jq-args...]
  local sid="$1" expr="$2"; shift 2
  _rc_write "$(_rc_splits_file)" '.splits = ((.splits // []) | map(if .sid==$sid then ('"$expr"') else . end))' --arg sid "$sid" "$@"
}
# An AGREED partition becomes real awareness state: each part auto-creates that
# owner's advisory area claim (side local for us, remote for peers). Skipped for a
# parallelVersions agreement — nothing to partition, the decision itself is the record.
_rc_split_apply() {  # <sid>
  local sid="$1"
  local sp; sp="$(_rc_splits | jq -c --arg sid "$sid" '.[] | select(.sid==$sid)')"
  [ -n "$sp" ] || return 0
  [ "$(jq -r '.parallelVersions // false' <<<"$sp")" = "true" ] && return 0
  local me; me="$(rc_self_npub)"
  local i n; n="$(jq '(.partition // []) | length' <<<"$sp")"
  for ((i=0; i<n; i++)); do
    local owner slice pscope side
    owner="$(jq -r ".partition[$i].owner" <<<"$sp")"
    slice="$(jq -r ".partition[$i].slice" <<<"$sp")"
    pscope="$(jq -r ".partition[$i].scope // \"\"" <<<"$sp")"
    side="remote"; [ "$owner" = "$me" ] && side="local"
    rc_area_upsert --area "${sid}-p$((i+1))" --scope "$pscope" --holder "$owner" \
      --side "$side" --status active --note "per split $sid: $slice" >/dev/null
  done
}
rc_split_agree() {  # <sid> [note] — accept a proposed split; auto-creates the per-part
  # advisory claims; returns split.agree envelope
  local sid="$1" note="${2:-}"
  _rc_split_patch "$sid" '.status="agreed" | .agreedAt=$now | .agreeNote=$n' \
    --arg now "$(rc_now)" --arg n "$note" || return 1
  _rc_split_apply "$sid"
  rc_render >/dev/null 2>&1 || true
  rc_envelope split.agree --payload "$(jq -nc --arg sid "$sid" --arg n "$note" '{sid:$sid, note:$n}')"
}

# ============================================================================
# Conflict reconciliation (the "Refinery" role) — reconcile, don't prevent
# ============================================================================
# Parallel work means conflicts WILL happen; they get reconciled, not forbidden.
# A conflict record names the overlapping paths + parties and walks the Overstory
# escalation ladder: clean → auto-merge → ai-resolve → re-plan (re-implement against
# the new base). The coordinator acts as INTEGRATOR/tie-breaker (it holds the
# holistic view), never as a gatekeeper that serializes everyone.
rc_conflict_open() {  # --paths csv --parties csv [--about ref --note T] → records + envelope
  local paths="" parties="" about="" note=""
  while [ $# -gt 0 ]; do case "$1" in
    --paths) paths="$2"; shift 2;; --parties) parties="$2"; shift 2;;
    --about) about="$2"; shift 2;; --note) note="$2"; shift 2;; *) shift;; esac; done
  [ -n "$paths" ] || { echo "ERR: --paths required" >&2; return 1; }
  local kid; kid="k$(printf '%s%s' "$paths" "$(rc_now)" | sha1sum | cut -c1-8)"
  local pj tj
  pj="$(printf '%s' "$paths"   | tr ',' '\n' | sed '/^$/d' | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
  tj="$(printf '%s' "$parties" | tr ',' '\n' | sed '/^$/d' | jq -R . | jq -sc . 2>/dev/null || echo '[]')"
  _rc_write "$(_rc_conflicts_file)" '
    .conflicts = ((.conflicts // []) + [{kid:$kid, paths:$p, parties:$t, about:$about,
      note:$note, stage:"clean", status:"open", openedAt:$now}])' \
    --arg kid "$kid" --argjson p "$pj" --argjson t "$tj" --arg about "$about" \
    --arg note "$note" --arg now "$(rc_now)"
  rc_render >/dev/null 2>&1 || true
  rc_envelope conflict.open \
    --payload "$(jq -nc --arg kid "$kid" --argjson p "$pj" --argjson t "$tj" --arg n "$note" \
       '{kid:$kid, paths:$p, parties:$t, note:$n, ladder:["clean","auto-merge","ai-resolve","re-plan"]}')"
}
rc_conflict_resolve() {  # <kid> --stage clean|auto-merge|ai-resolve|re-plan [--resolution T] [--open]
  local kid="$1"; shift
  local stage="" resolution="" status="resolved"
  while [ $# -gt 0 ]; do case "$1" in
    --stage) stage="$2"; shift 2;; --resolution) resolution="$2"; shift 2;;
    --open) status="open"; shift;; *) shift;; esac; done
  case "$stage" in clean|auto-merge|ai-resolve|re-plan) ;; *) echo "ERR: --stage must be clean|auto-merge|ai-resolve|re-plan" >&2; return 1;; esac
  _rc_write "$(_rc_conflicts_file)" '
    .conflicts = ((.conflicts // []) | map(if .kid==$kid
      then (.stage=$s | .status=$st | .resolution=$r | .updatedAt=$now) else . end))' \
    --arg kid "$kid" --arg s "$stage" --arg st "$status" --arg r "$resolution" --arg now "$(rc_now)" || return 1
  rc_render >/dev/null 2>&1 || true
  rc_envelope conflict.resolve \
    --payload "$(jq -nc --arg kid "$kid" --arg s "$stage" --arg st "$status" --arg r "$resolution" \
       '{kid:$kid, stage:$s, status:$st, resolution:$r}')"
}
# Git-aware detection: paths BOTH branches touched since their merge-base — the
# mechanical "you two collided" probe behind conflict.open.
rc_conflict_scan() {  # <repo-dir> <branchA> <branchB> → common changed paths (one per line)
  local repo="$1" a="$2" b="$3"
  local base; base="$(git -C "$repo" merge-base "$a" "$b" 2>/dev/null)" || { echo "ERR: no merge-base $a..$b" >&2; return 1; }
  comm -12 \
    <(git -C "$repo" diff --name-only "$base" "$a" 2>/dev/null | sort -u) \
    <(git -C "$repo" diff --name-only "$base" "$b" 2>/dev/null | sort -u)
}

# ============================================================================
# Prior-work edge graph (Beads-style typed relations, for "did I do this before?")
# ============================================================================
# Grow-only JSONL of typed edges between work artifacts (task ids, area ids, memory
# card names, PR/issue refs, feature names): duplicates | supersedes | blocks |
# conflicts-with. Makes "have I built this?" a LOOKUP (rc edges <node>) instead of a
# grep, and — per the StateFuse critique — conflicts-with SURFACES contradictory
# knowledge instead of letting it silently coexist; a periodic consolidation pass
# (coordinator-run) merges duplicates and prunes stale nodes. `bd` (Beads) is a
# drop-in heavier alternative (git-synced, transactional) if this outgrows JSONL.
rc_edge_add() {  # <from> <rel> <to> [note]
  local from="$1" rel="$2" to="$3" note="${4:-}"
  case "$rel" in duplicates|supersedes|blocks|conflicts-with) ;; *) echo "ERR: rel must be duplicates|supersedes|blocks|conflicts-with" >&2; return 1;; esac
  local f; f="$(_rc_edges_file)"; _rc_ensure_dir "$(dirname "$f")"
  jq -nc --arg from "$from" --arg rel "$rel" --arg to "$to" --arg note "$note" --arg now "$(rc_now)" \
     '{from:$from, rel:$rel, to:$to, note:$note, at:$now}' >> "$f"
}
rc_edges() {  # [node-or-rel-filter] → matching edges (all if no filter)
  local f q="${1:-}"; f="$(_rc_edges_file)"
  [ -f "$f" ] || { echo '[]'; return 0; }
  jq -sc --arg q "$q" '[ .[] | select($q=="" or .from==$q or .to==$q or .rel==$q) ]' "$f" 2>/dev/null || echo '[]'
}

# ============================================================================
# Peer initiative announcements (a standing "I am autonomously working on…" surface)
# ============================================================================
rc_peer_note() {  # <npub> <name> <initiatives-json-array>
  local npub="$1" name="$2" inits="$3"
  echo "$inits" | jq -e . >/dev/null 2>&1 || inits='[]'
  _rc_write "$(_rc_peers_file)" '.peers[$np] = {name:$n, initiatives:$i, lastAnnounce:$now}' \
    --arg np "$npub" --arg n "$name" --argjson i "$inits" --arg now "$(rc_now)"
  rc_render >/dev/null 2>&1 || true
}
rc_peers() { local f; f="$(_rc_peers_file)"; [ -f "$f" ] && jq -c '.peers // {}' "$f" || echo '{}'; }

# ============================================================================
# Envelope build + emit (same wire shape as team-coord.sh, peer-scoped fields)
# ============================================================================
# rc_envelope <kind> [--consult C --area A --payload JSON]
rc_envelope() {
  local kind="$1"; shift
  local cid="" area="" payload="{}"
  while [ $# -gt 0 ]; do case "$1" in
    --consult) cid="$2"; shift 2;; --area) area="$2"; shift 2;; --payload) payload="$2"; shift 2;; *) shift;; esac; done
  local me name lam mid
  me="$(rc_self_npub)"; name="$(rc_self_name)"; lam="$(rc_lamport_next)"; mid="$(_rc_uuid)"
  echo "$payload" | jq -e . >/dev/null 2>&1 || payload='{}'
  jq -nc --arg a2a "1" --arg kind "$kind" --arg id "$mid" --argjson lamport "${lam:-1}" \
     --arg cid "$cid" --arg area "$area" --arg from "$name" --arg fromNpub "$me" \
     --argjson payload "$payload" --arg now "$(rc_now)" \
     '{a2a:$a2a, kind:$kind, id:$id, lamport:$lamport, from:$from, fromNpub:$fromNpub, sentAt:$now}
      + (if $cid!="" then {consult:$cid} else {} end)
      + (if $area!="" then {area:$area} else {} end)
      + {payload:$payload}'
}

# rc_emit <envelope-json> --to <npub> | --to-all-peers
# SIF egress-guard + send. Most peer verbs are 1:1; work.intent ("who's-on-this?")
# fans out to every AUTHORIZED registry peer via --to-all-peers. Honors TEAM_DRY_RUN=1.
# rc_resolve_target <target> → an npub for a --to value.
# An npub (npub1…) or a raw 64-hex pubkey passes through UNCHANGED (send-dm handles both).
# Anything else is treated as a Unicity NAMETAG: resolve it to an npub, checking the
# local agent-registry CACHE first (a prior nametag→npub is stored as a peer, resolvable
# by unicityName) and only hitting the network via `sphere-helper resolve-nametag` on a
# miss — then caching the nametag↔npub in the registry so later lookups stay local.
# Prints the npub on stdout; empty + non-zero exit when a nametag does not resolve.
rc_resolve_target() {
  local target="${1:-}"
  [ -n "$target" ] || { echo "ERR: empty target" >&2; return 1; }
  # Already an npub or a 32-byte hex pubkey → nothing to resolve.
  case "$target" in
    npub1*) printf '%s' "$target"; return 0;;
  esac
  if printf '%s' "$target" | grep -Eiq '^[0-9a-f]{64}$'; then printf '%s' "$target"; return 0; fi

  # Nametag path. Cache hit? (registry resolves a peer by its unicityName.)
  local cached
  cached="$(bash "$RC_REGISTRY" get "$target" 2>/dev/null | jq -r '.npub // ""' 2>/dev/null || echo "")"
  case "$cached" in
    npub1*) printf '%s' "$cached"; return 0;;
  esac

  # Miss → resolve on the network via the sphere-helper.
  local helper=""; type _tc_sphere_helper >/dev/null 2>&1 && helper="$(_tc_sphere_helper)"
  [ -n "$helper" ] || { echo "ERR: sphere-helper not found — cannot resolve nametag '$target'" >&2; return 1; }
  local out npub hex
  out="$(node "$helper" resolve-nametag "$target" 2>/dev/null || true)"
  npub="$(printf '%s' "$out" | jq -r '.npub // ""' 2>/dev/null || echo "")"
  hex="$(printf '%s' "$out" | jq -r '.hex // ""' 2>/dev/null || echo "")"
  case "$npub" in
    npub1*) ;;
    *) echo "ERR: nametag '$target' did not resolve to an npub" >&2; return 1;;
  esac
  # Cache nametag↔npub for future local lookups (best-effort; never blocks the send).
  if printf '%s' "$hex" | grep -Eiq '^[0-9a-f]{64}$'; then
    bash "$RC_REGISTRY" upsert-peer --npub "$npub" --pubkey "$hex" --name "$target" >/dev/null 2>&1 || true
  else
    bash "$RC_REGISTRY" upsert-peer --npub "$npub" --name "$target" >/dev/null 2>&1 || true
  fi
  printf '%s' "$npub"
}

rc_emit() {
  local env="$1"; shift
  local to="" all=0
  while [ $# -gt 0 ]; do case "$1" in
    --to) to="$2"; shift 2;; --to-all-peers) all=1; shift;; *) shift;; esac; done
  local recips=()
  if [ "$all" = "1" ]; then
    while IFS= read -r n; do [ -n "$n" ] && recips+=("$n"); done \
      < <(bash "$RC_REGISTRY" list authorized 2>/dev/null | jq -r '.[].npub // empty' 2>/dev/null)
    [ "${#recips[@]}" -gt 0 ] || { echo "WARN: no authorized peers to broadcast to" >&2; return 0; }
  else
    [ -n "$to" ] || { echo "ERR: --to <npub|nametag> (or --to-all-peers) required" >&2; return 1; }
    # Accept a nametag (or @nametag) as well as an npub/hex: resolve+cache → npub.
    local resolved; resolved="$(rc_resolve_target "${to#@}")" \
      || { echo "ERR: could not resolve recipient '$to' (not an npub/hex, and nametag resolution failed)" >&2; return 1; }
    recips=("$resolved")
  fi
  local kind; kind="$(jq -r '.kind' <<<"$env")"
  local helper=""; type _tc_sphere_helper >/dev/null 2>&1 && helper="$(_tc_sphere_helper)"
  local ident=""; type team_identity_path >/dev/null 2>&1 && ident="$(team_identity_path)"
  # Point NODE_PATH at the framework clone's node_modules (helper dir → ../node_modules) so
  # the transport helper loads @unicitylabs/sphere-sdk even when invoked from outside the
  # clone (mirrors sphere-daemon.mjs).
  local nodepath=""; [ -n "$helper" ] && nodepath="$(cd "$(dirname "$helper")/.." 2>/dev/null && pwd)/node_modules:${NODE_PATH:-}"
  # Transport preflight: a MISSING helper or identity must FAIL LOUD — never masquerade as a
  # successful DRY-RUN. Folding "no transport" into the DRY-RUN branch made a fresh peer's
  # every consult/claim/intent silently vanish while reporting success (#20). Only an explicit
  # TEAM_DRY_RUN=1 suppresses real sending.
  if [ "${TEAM_DRY_RUN:-0}" != "1" ]; then
    if [ -z "$helper" ]; then
      echo "ERROR(rc_emit): sphere-helper.mjs not found — '$kind' NOT sent to any recipient. Set \$TEAM_SPHERE_HELPER or record transport.helper_path in the agent config (re-run setup.sh)." >&2
      return 3
    fi
    if [ ! -f "$ident" ]; then
      echo "ERROR(rc_emit): identity file '${ident:-unset}' missing — '$kind' NOT sent. Re-run setup.sh to mint the agent identity." >&2
      return 3
    fi
  fi
  local n rc=0
  for n in "${recips[@]}"; do
    if [ -f "$RC_SIF" ]; then
      local dec; dec="$(printf '%s' "$env" | bash "$RC_SIF" check --direction outbound --principal "$n" --source agent-comms 2>/dev/null | jq -r '.decision // "pass"' 2>/dev/null || echo pass)"
      [ "$dec" = "quarantine" ] && { echo "BLOCKED(sif) → $n : $kind" >&2; rc=1; continue; }
    fi
    if [ "${TEAM_DRY_RUN:-0}" = "1" ]; then
      printf 'DRY-RUN send → %s : %s\n' "$n" "$kind"
    elif NODE_PATH="$nodepath" node "$helper" send-dm "$n" "$env" --identity "$ident" >/dev/null 2>&1; then
      printf 'sent → %s : %s\n' "$n" "$kind"
    else
      printf 'FAILED send → %s : %s\n' "$n" "$kind" >&2; rc=1
    fi
  done
  return $rc
}

# ============================================================================
# INGEST — record an inbound peer event to durable state (dedup, record-only).
# NOTHING here decides or executes: grants, advisories, and commitment work are
# produced only by the skills, with the admin in the loop.
# ============================================================================
rc_ingest() {  # <event-json-or-file-or-->  (event = the queued wrapper OR a raw envelope)
  local raw="$1" ev
  if [ "$raw" = "-" ]; then ev="$(cat)"; elif [ -f "$raw" ]; then ev="$(cat "$raw")"; else ev="$raw"; fi
  local env; env="$(jq -c 'if has("envelope") then .envelope else . end' <<<"$ev" 2>/dev/null)"
  [ -n "$env" ] || { echo "ERR: bad event json" >&2; return 1; }
  local kind cid area mid from_npub from_name payload
  kind="$(jq -r '.kind // ""' <<<"$env")"
  cid="$(jq -r '.consult // ""' <<<"$env")"
  area="$(jq -r '.area // ""' <<<"$env")"
  mid="$(jq -r '.id // ""' <<<"$env")"
  from_npub="$(jq -r '.fromNpub // ""' <<<"$env")"
  from_name="$(jq -r '.from // ""' <<<"$env")"
  if [ -z "$from_npub" ] || [ "$from_npub" = "null" ]; then
    local fp; fp="$(jq -r '.from_pubkey // ""' <<<"$ev")"
    [ -n "$fp" ] && from_npub="$(bash "$RC_REGISTRY" get "$fp" 2>/dev/null | jq -r '.npub // ""' 2>/dev/null || echo "")"
  fi
  payload="$(jq -c '.payload // {}' <<<"$env")"
  [ -n "$kind" ] || { echo "ERR: no kind" >&2; return 1; }
  if [ -n "$mid" ] && rc_seen_check "$mid"; then echo "DUP: $mid ($kind) ignored"; return 0; fi

  case "$kind" in
    peer.announce)
      rc_peer_note "$from_npub" "$from_name" "$(jq -c '.initiatives // []' <<<"$payload")"
      echo "ANNOUNCE: $from_npub initiatives updated";;
    consult.request)
      # They opened a consult with us — record the thread (side:remote), status open.
      [ -n "$cid" ] || cid="c$(printf '%s%s' "$from_npub" "$mid" | sha1sum | cut -c1-10)"
      local d; d="$(_rc_consults_dir)"; _rc_ensure_dir "$d"
      jq -nc --arg cid "$cid" --arg from "$from_npub" --arg name "$from_name" \
         --argjson p "$payload" --arg now "$(rc_now)" \
         '{cid:$cid, side:"remote", peerNpub:$from, peerName:$name, status:"open",
           intent:($p.intent // ""), urgency:($p.urgency // "normal"),
           areas:($p.areas // []), repos:($p.repos // []),
           changes:($p.changes // []), questions:($p.questions // []),
           advisory:null, commitments:[], receivedAt:$now}' > "$d/$cid.json.tmp.$$" \
        && mv "$d/$cid.json.tmp.$$" "$d/$cid.json"
      rc_render >/dev/null 2>&1 || true
      echo "CONSULT opened: $cid from $from_npub — advise via /coordinator-advise";;
    consult.advise)
      # A coordinator answered a consult WE opened. The wire payload carries the
      # advisory text under key `advisory`; store it ALSO under `.advisory.text` so
      # readers match the coordinator-side shape (rc_advise writes `.advisory.text`).
      # Keeps `.advisory.advisory` too for back-compat. See consult.advise field-name fix.
      _rc_consult_patch "$cid" '.status="advised" | .advisory=($p + {text:($p.text // $p.advisory // ""), at:$now})' \
        --argjson p "$payload" --arg now "$(rc_now)" >/dev/null 2>&1 \
        && echo "ADVISORY received on $cid" || echo "ADVISORY for unknown consult $cid — noted"
      rc_render >/dev/null 2>&1 || true;;
    consult.ack)
      # Dual duty: closes a consult thread (by .consult/cid) AND — when the payload
      # carries a sid — accepts a split we proposed (the lead protocol: recipients
      # reply to split.propose via consult.ack). Acceptance applies the partition.
      local acksid; acksid="$(jq -r '.sid // ""' <<<"$payload")"
      if [ -n "$acksid" ]; then
        _rc_split_patch "$acksid" '.status="agreed" | .agreedAt=$now | .agreeNote=($p.note // "")' \
          --arg now "$(rc_now)" --argjson p "$payload" >/dev/null 2>&1
        _rc_split_apply "$acksid"
        rc_render >/dev/null 2>&1 || true
        echo "SPLIT accepted via consult.ack: $acksid — per-part advisory claims recorded"
      fi
      if [ -n "$cid" ]; then
        _rc_consult_patch "$cid" '.status="closed" | .ack=($p + {at:$now})' \
          --argjson p "$payload" --arg now "$(rc_now)" >/dev/null 2>&1
        rc_render >/dev/null 2>&1 || true
        echo "ACK on $cid"
      fi;;
    consult.commit_done)
      _rc_consult_patch "$cid" '.commitments = ((.commitments // []) | map(if .cmid==($p.cmid // "") then (.status="applied") else . end))' \
        --argjson p "$payload" >/dev/null 2>&1
      rc_render >/dev/null 2>&1 || true
      echo "COMMITMENT applied on $cid: $(jq -r '.cmid // "?"' <<<"$payload")";;
    work.intent)
      # A peer broadcasts "is anyone already working on X?" — record it and surface
      # what WE hold on that scope (active claims AND our own live intents) so the
      # skill can compose an honest work.status. Record-only: nothing auto-decides.
      local iid; iid="$(jq -r '.iid // ""' <<<"$payload")"; [ -n "$iid" ] || iid="i-$mid"
      _rc_write "$(_rc_intents_file)" '
        .intents = ((.intents // []) | map(select(.iid != $iid)))
        | .intents += [{iid:$iid, side:"remote", peerNpub:$from, peerName:$name,
            subject:($p.subject // $p.intent // ""), approach:($p.approach // ""),
            scope:($p.scope // []), windowUntil:($p.windowUntil // $p.deadline // ""),
            status:"awaiting-reply", receivedAt:$now}]' \
        --arg iid "$iid" --arg from "$from_npub" --arg name "$from_name" \
        --argjson p "$payload" --arg now "$(rc_now)"
      rc_render >/dev/null 2>&1 || true
      local qscope; qscope="$(jq -r '(.scope // []) | join(",")' <<<"$payload")"
      local mine; mine="$(rc_area_check "$qscope")"
      local myint; myint="$(rc_intent_check "$qscope")"
      echo "WORK-INTENT from $from_npub: $(jq -r '.subject // .intent // "?"' <<<"$payload") — reply via /coordinator-advise (or /consult-coordinator)"
      [ "$(jq 'length' <<<"$mine" 2>/dev/null || echo 0)" -gt 0 ] \
        && echo "  ⚠ we hold overlapping active area(s): $(jq -r 'map(.areaId) | join(", ")' <<<"$mine")"
      [ "$(jq 'length' <<<"$myint" 2>/dev/null || echo 0)" -gt 0 ] \
        && echo "  ⚠ we have live intent(s) on that scope: $(jq -r 'map(.iid + " (" + .subject + ")") | join(", ")' <<<"$myint")";;
    work.status)
      # A reply to OUR broadcast: onIt=true/false (+ optional parallelVersions offer).
      local iid; iid="$(jq -r '.iid // ""' <<<"$payload")"
      _rc_intent_patch "$iid" '.responses = ((.responses // []) + [($p + {fromNpub:$from, fromName:$name, at:$now})])' \
        --argjson p "$payload" --arg from "$from_npub" --arg name "$from_name" --arg now "$(rc_now)" >/dev/null 2>&1
      rc_render >/dev/null 2>&1 || true
      echo "WORK-STATUS on $iid from $from_npub: onIt=$(jq -r '.onIt // false' <<<"$payload")";;
    area.claim)
      # A peer registers an ADVISORY claim — recorded as active immediately (soft
      # claim; nothing to grant). Overlap with our areas is surfaced as a notice so
      # /coordinator-advise can send an area.ack naming the peers to coordinate with.
      [ -n "$area" ] || area="a$(printf '%s%s' "$from_npub" "$mid" | sha1sum | cut -c1-8)"
      rc_area_upsert --area "$area" \
        --scope "$(jq -r '(.scope // []) | join(",")' <<<"$payload")" \
        --holder "$from_npub" --name "$from_name" --side remote --status active \
        --note "$(jq -r '.note // ""' <<<"$payload")" >/dev/null
      local clash; clash="$(rc_area_check "$(jq -r '(.scope // []) | join(",")' <<<"$payload")" | jq -c --arg id "$area" 'map(select(.areaId != $id))')"
      echo "AREA claimed (advisory): $area by $from_npub"
      [ "$(jq 'length' <<<"$clash" 2>/dev/null || echo 0)" -gt 0 ] \
        && echo "  ⚠ OVERLAP notice — coordinate with holders of: $(jq -r 'map(.areaId + " (" + ((.holderName // .holderNpub[0:12])) + ")") | join(", ")' <<<"$clash") — ack via /coordinator-advise";;
    area.ack)
      # Advisory response to OUR claim: overlaps + advice (informational, not permission).
      _rc_area_patch "$area" ".ack=$(jq -c '.' <<<"$payload") | .ackAt=\"$(rc_now)\"" >/dev/null 2>&1
      rc_render >/dev/null 2>&1 || true
      local ovl; ovl="$(jq -r '(.overlaps // []) | length' <<<"$payload")"
      echo "AREA ack on $area: ${ovl} overlap(s)$( [ "$ovl" != "0" ] && printf ' — coordinate: %s' "$(jq -r '(.overlaps // []) | map(.areaId) | join(", ")' <<<"$payload")" )";;
    area.heartbeat)
      _rc_area_patch "$area" ".status=\"active\" | .lease=$(jq -c '.lease // {}' <<<"$payload") | .heartbeatAt=\"$(rc_now)\"" >/dev/null 2>&1
      rc_render >/dev/null 2>&1 || true
      echo "AREA heartbeat: $area";;
    area.release)
      _rc_area_patch "$area" ".status=\"released\" | .releasedAt=\"$(rc_now)\"" >/dev/null 2>&1
      rc_render >/dev/null 2>&1 || true
      echo "AREA released: $area";;
    split.propose)
      local sid; sid="$(jq -r '.sid // ""' <<<"$payload")"; [ -n "$sid" ] || sid="s-$mid"
      _rc_write "$(_rc_splits_file)" '
        .splits = ((.splits // []) | map(select(.sid != $sid)))
        | .splits += [{sid:$sid, side:"remote", peerNpub:$from, peerName:$name,
            subject:($p.subject // ""), about:($p.about // ""), partition:($p.partition // []),
            parallelVersions:($p.parallelVersions // false), note:($p.note // ""),
            status:"proposed", receivedAt:$now}]' \
        --arg sid "$sid" --arg from "$from_npub" --arg name "$from_name" \
        --argjson p "$payload" --arg now "$(rc_now)"
      rc_render >/dev/null 2>&1 || true
      if [ "$(jq -r '.parallelVersions // false' <<<"$payload")" = "true" ]; then
        echo "SPLIT proposal $sid from $from_npub: acknowledged PARALLEL-VERSIONS run on '$(jq -r '.subject // .about // "?"' <<<"$payload")' — agree via 'split-agree $sid' if intended"
      else
        echo "SPLIT proposal $sid from $from_npub: partition of '$(jq -r '.subject // .about // "?"' <<<"$payload")' — review + 'split-agree $sid' (accept, records per-part claims) or counter with another split-propose; escalate to admins only if a judgment call is needed"
      fi;;
    split.agree)
      # Peer accepted OUR proposal → the agreed partition becomes real awareness
      # state: each part auto-creates that owner's advisory area claim.
      local sid; sid="$(jq -r '.sid // ""' <<<"$payload")"
      _rc_split_patch "$sid" '.status="agreed" | .agreedAt=$now | .agreeNote=($p.note // "")' \
        --arg now "$(rc_now)" --argjson p "$payload" >/dev/null 2>&1
      _rc_split_apply "$sid"
      rc_render >/dev/null 2>&1 || true
      echo "SPLIT agreed: $sid — per-part advisory claims recorded; proceed on your slice";;
    conflict.open)
      local kid; kid="$(jq -r '.kid // ""' <<<"$payload")"; [ -n "$kid" ] || kid="k-$mid"
      _rc_write "$(_rc_conflicts_file)" '
        .conflicts = ((.conflicts // []) | map(select(.kid != $kid)))
        | .conflicts += [{kid:$kid, side:"remote", peerNpub:$from, paths:($p.paths // []),
            parties:($p.parties // []), note:($p.note // ""), stage:"clean",
            status:"open", receivedAt:$now}]' \
        --arg kid "$kid" --arg from "$from_npub" --argjson p "$payload" --arg now "$(rc_now)"
      rc_render >/dev/null 2>&1 || true
      echo "CONFLICT opened: $kid on $(jq -r '(.paths // []) | join(", ")' <<<"$payload") — reconcile via /coordinator-advise (ladder: clean → auto-merge → ai-resolve → re-plan)";;
    conflict.resolve)
      local kid; kid="$(jq -r '.kid // ""' <<<"$payload")"
      _rc_write "$(_rc_conflicts_file)" '
        .conflicts = ((.conflicts // []) | map(if .kid==($p.kid // "") then
          (.stage=($p.stage // .stage) | .status=($p.status // "resolved")
           | .resolution=($p.resolution // "") | .updatedAt=$now) else . end))' \
        --argjson p "$payload" --arg now "$(rc_now)" >/dev/null 2>&1
      rc_render >/dev/null 2>&1 || true
      echo "CONFLICT $kid → $(jq -r '.status // "resolved"' <<<"$payload") at stage $(jq -r '.stage // "?"' <<<"$payload")";;
    *) echo "IGNORED: unknown kind $kind";;
  esac
  [ -n "$mid" ] && rc_seen_mark "$mid" >/dev/null 2>&1
  return 0
}

# ============================================================================
# Render the human-facing coordination ledger
# ============================================================================
rc_render() {
  local d; d="$(coord_root)"; _rc_ensure_dir "$d"
  {
    printf '# Remote-agent coordination ledger\n\nUpdated %s\n\n' "$(rc_now)"
    printf '## Work-area claims\n\n'
    printf '| area | status | holder | side | scope | lease expires |\n|---|---|---|---|---|---|\n'
    rc_area_list | jq -r '.[] | "| \(.areaId) | \(.status) | \(.holderName // (.holderNpub|.[0:12])) | \(.side) | \((.scope // [])|join(", ")) | \(.lease.expiresAt // "-") |"' 2>/dev/null
    printf '\n## Consult threads\n\n'
    local f
    for f in "$(_rc_consults_dir)"/*.json; do [ -e "$f" ] || continue
      jq -r '"### \(.cid) — \(.side) · **\(.status)**\n- peer: \(.peerName // "") \(.peerNpub|.[0:20])…\n- intent: \(.intent)\n- areas: \((.areas // [])|join(", "))\n- changes: \((.changes // [])|length) · questions: \((.questions // [])|length)\n- advisory: \(if .advisory then (.advisory.text // .advisory.advisory // "recorded") else "—" end)\n- commitments: \((.commitments // []) | map("\(.cmid) \(.status // "pending")") | join(", "))\n"' "$f" 2>/dev/null
    done
    printf '\n## Work-intent broadcasts (who'"'"'s-on-this?)\n\n'
    _rc_intents | jq -r '.[] | "- \(.iid) [\(.side)] **\(.status)** — \(.subject // .intent // "")\(if (.approach // "") != "" then " · approach: " + .approach else "" end) · scope: \((.scope // [])|join(", ")) · replies: \((.responses // [])|length) (\((.responses // []) | map(select(.onIt==true)) | length) on it)"' 2>/dev/null
    printf '\n## Split negotiations\n\n'
    _rc_splits | jq -r '.[] | "- \(.sid) [\(.side)] **\(.status)** — \(.subject // .about // "")\(if .parallelVersions then " · PARALLEL-VERSIONS" else "" end) · slices: \((.partition // []) | map((.owner|.[0:12]) + "→" + .slice) | join(", "))"' 2>/dev/null
    printf '\n## Open conflicts (reconciliation ladder: clean → auto-merge → ai-resolve → re-plan)\n\n'
    _rc_conflicts | jq -r '.[] | "- \(.kid) **\(.status)** @ \(.stage) — \((.paths // [])|join(", ")) · parties: \((.parties // [])|join(", "))"' 2>/dev/null
    printf '\n## Our pending change-commitments\n\n'
    _rc_commitments | jq -r '.[] | select(.status=="pending") | "- [ ] \(.cmid) (consult \(.consult)): \(.description) [\(.scope)]"' 2>/dev/null
    printf '\n## Announced peer initiatives\n\n'
    rc_peers | jq -r 'to_entries[] | "- \(.value.name // (.key|.[0:12])): \((.value.initiatives // []) | join("; ")) (\(.value.lastAnnounce))"' 2>/dev/null
  } > "$d/coord.md.tmp.$$" && mv "$d/coord.md.tmp.$$" "$d/coord.md"
  return 0
}

# ============================================================================
# Deferred-envelope replay (peer authorization chicken-and-egg — issue #14)
# ============================================================================
# classify-inbound.sh stashes a peer's FIRST coordination envelope (arriving before the
# sender is authorized) under <STATE_DIR>/agent-deferred/<hex>/<eventid>.json. When the
# owner later authorizes that hex, agent-registry.sh calls us here to REPLAY the stash:
# re-enqueue each envelope by kind onto the right queue (peer verb → consult queue via
# rc_enqueue_event, team verb → team queue via team_enqueue_event — both sourced by this
# module), then delete the stash so nothing double-dispatches. Prints the replay count.
# Idempotent: the enqueue functions dedup by envelope id, and files are removed after.
rc_replay_deferred() {  # <hex>
  local hex="$1"
  [ -n "$hex" ] || { echo "ERR: hex required" >&2; return 1; }
  local d="$STATE_DIR/agent-deferred/$hex"
  [ -d "$d" ] || { printf '0\n'; return 0; }
  local n=0 f env kind ts npub name
  for f in "$d"/*.json; do
    [ -e "$f" ] || continue
    env="$(jq -r '.body // ""' "$f" 2>/dev/null)"
    ts="$(jq -r '.receivedAt // ""' "$f" 2>/dev/null)"
    npub="$(jq -r '.npub // ""' "$f" 2>/dev/null)"
    name="$(jq -r '.unicityName // ""' "$f" 2>/dev/null)"
    kind="$(printf '%s' "$env" | jq -r '.kind // ""' 2>/dev/null)"
    [ -n "$kind" ] && [ "$kind" != "null" ] || kind="$(jq -r '.kind // ""' "$f" 2>/dev/null)"
    if rc_is_verb "$kind"; then
      rc_enqueue_event "$hex" "$ts" "$env" "$npub" "$name" >/dev/null 2>&1 && n=$((n+1))
    elif type team_is_verb >/dev/null 2>&1 && team_is_verb "$kind"; then
      team_enqueue_event "$hex" "$ts" "$env" "$npub" "$name" >/dev/null 2>&1 && n=$((n+1))
    fi
    rm -f "$f" 2>/dev/null || true
  done
  rmdir "$d" 2>/dev/null || true
  printf '%s\n' "$n"
}

# ============================================================================
# CLI dispatch (only when executed directly, not sourced)
# ============================================================================
_rc_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    root) coord_root; echo;;
    self) printf 'npub=%s name=%s\n' "$(rc_self_npub)" "$(rc_self_name)";;
    verb-cap) rc_verb_cap "${1:-}";;
    is-verb) rc_is_verb "${1:-}" && echo yes || { echo no; return 1; };;
    consult-open) rc_consult_open "$@";;
    consult-list) rc_consult_list "${1:-}"; echo;;
    consult-get) rc_consult_get "${1:-}";;
    advise) rc_advise "$@";;
    commit-done) rc_commit_done "$@";;
    commitments) _rc_commitments; echo;;
    area-upsert) rc_area_upsert "$@";;
    areas) rc_area_list "${1:-}"; echo;;
    area-check) rc_area_check "${1:-}"; echo;;
    area-ack) rc_area_ack "$@";;
    area-heartbeat) rc_area_heartbeat "$@";;
    area-release) rc_area_release "${1:-}";;
    reap) rc_reap;;
    intent-open) rc_intent_open "$@";;
    intents) _rc_intents; echo;;
    intent-result) rc_intent_result "${1:-}"; echo;;
    intent-check) rc_intent_check "${1:-}"; echo;;
    split-propose) rc_split_propose "$@";;
    split-agree) rc_split_agree "$@";;
    splits) _rc_splits; echo;;
    conflict-open) rc_conflict_open "$@";;
    conflict-resolve) rc_conflict_resolve "$@";;
    conflicts) _rc_conflicts; echo;;
    conflict-scan) rc_conflict_scan "$@";;
    edge-add) rc_edge_add "$@";;
    edges) rc_edges "${1:-}"; echo;;
    peers) rc_peers; echo;;
    envelope) rc_envelope "$@";;
    emit) rc_emit "$@";;
    ingest) rc_ingest "${1:--}";;
    replay-deferred) rc_replay_deferred "${1:-}";;
    events)  # list queued consult events
      _rc_ensure_dir "$CONSULT_EVENTS_DIR"
      local out='[]' f
      for f in "$CONSULT_EVENTS_DIR"/*.json; do [ -e "$f" ] || continue
        [ "$(jq -r '.status // "queued"' "$f")" = "queued" ] && out="$(jq -c --slurpfile e "$f" '. + [$e[0] | {id,kind,consult,area,from_pubkey,npub,unicityName}]' <<<"$out")"; done
      printf '%s\n' "$out";;
    event-done) local f="$CONSULT_EVENTS_DIR/${1:-}.json"; [ -f "$f" ] && { jq '.status="done"|.processedAt=(now|todate)' "$f" > "$f.t" && mv "$f.t" "$f"; echo done; };;
    enqueue-event) rc_enqueue_event "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}"; echo;;
    render) rc_render; echo "rendered $(coord_root)/coord.md";;
    *)
      cat >&2 <<EOF
remote-coord.sh — remote-agent coordination engine (consults + advisory work-area
claims + who's-on-this broadcasts + split negotiation + conflict reconciliation, over A2A).
Commands:
  root | self | verb-cap <kind> | is-verb <kind>
  consult-open --to <npub|nametag> --intent I [--areas csv --repos csv --changes J --questions J --urgency u]
  consult-list [status] | consult-get <cid>
  advise <cid> --advisory TEXT [--conflicts JSON] [--commit "desc|scope"]...
  commit-done <cmid> [note] | commitments
  intent-open --subject S --area csv [--approach A] [--deadline ISO | --window-mins M]
  intents | intent-result <iid> | intent-check <scope-csv>
  area-upsert --area ID --scope csv --holder npub [--name --side --status --ttl-hours --note]
  areas [status] | area-check <scope-csv> | area-ack <areaId> [advice]
  area-heartbeat <areaId> [--ttl-hours H] | area-release <areaId> | reap
  split-propose --subject S --parts 'npub=slice-desc|scope' [--parts ...] \
                [--about <iid|areaId>] [--parallel-versions] [--note T] [--emit]
  split-agree <sid> [note] | splits     (accept also arrives as consult.ack{sid})
  conflict-open --paths csv --parties csv [--about --note] | conflicts
  conflict-resolve <kid> --stage clean|auto-merge|ai-resolve|re-plan [--resolution T] [--open]
  conflict-scan <repo-dir> <branchA> <branchB>
  edge-add <from> duplicates|supersedes|blocks|conflicts-with <to> [note] | edges [filter]
  peers | envelope <kind> [--consult C --area A --payload JSON]
  emit <env-json> --to <npub|nametag> | --to-all-peers   (nametag → npub via sphere-helper, cached in registry)
  ingest <event-json|file|-> | events | event-done <id>
  enqueue-event <from_pubkey> <ts> <envelope-json> [npub] [name]
  render
Env: COORD_ROOT, RC_AREA_TTL_HOURS, TEAM_SELF_NPUB, TEAM_SELF_NAME, TEAM_IDENTITY_FILE, TEAM_DRY_RUN=1
EOF
      return 1;;
  esac
}

if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then _rc_cli "$@"; fi
