#!/bin/bash
# agent-registry.sh — authorized-agents registry: single source of truth for
# WHO a remote Claude agent is (cryptographic pubkey) and WHAT it may ask us to do
# (explicit capability grants). DEFAULT-DENY throughout.
#
# Dual-use:
#   • Sourced by hooks (classify-inbound.sh, check-diagnostics.sh) for lookups.
#   • Run as a CLI by the owner-facing skills (/authorize-agent, /deny-agent,
#     /list-agents, /dm-agent) to mutate the registry.
#
# IDENTITY MODEL — the registry is keyed by the sender's **pubkey** (the hex string
# the daemon writes as `.from` on each message), because the pubkey is the only
# thing a remote cannot spoof. `unicityName` is a *claimed* label (from the intro
# text, or owner-assigned) and is NEVER the security boundary. A lookup query may be
# a pubkey hex, an npub, a unicityName, or a short hex prefix — but authorization is
# always recorded against the pubkey key.
#
# SECURITY POSTURE: absent key ⇒ unknown ⇒ pending ⇒ NEVER acted upon. Only an entry
# with status=="authorized" AND the specific capability in `capabilities` clears the
# gate — and destructive/outward capabilities still honor normal owner-confirmation.
#
# The registry file is runtime state, kept OUT of git (lives under the gitignored
# .claude/ tree, override with AGENT_REGISTRY_FILE). It self-initializes empty
# (default-deny) on first access, so the whole system is INERT-safe: an empty
# registry queues everything for owner authorization and does nothing else.
set -uo pipefail

# --- Portable advisory file lock (bug: macOS/BSD ships no flock(1)) ---------------
# Prefer the real flock(1) when present → byte-identical behavior on Linux. When it
# is absent (notably macOS), fall back to an atomic mkdir spinlock: mkdir is atomic
# on every POSIX filesystem and needs no external binary. The mkdir lock auto-releases
# when the calling (sub)shell exits, mirroring flock's fd-close semantics — so callers
# keep the existing `( _pflock "$lock" [timeout]; … ) 9>"$lock"` subshell form
# unchanged. `PFLOCK_FORCE_MKDIR=1` forces the fallback path (used by tests on Linux).
if ! declare -f _pflock >/dev/null 2>&1; then
_pflock() {  # _pflock <lockfile> [timeout_s]  — call inside a `( … ) 9>"$lockfile"` subshell
  local lf="${1:-}" to="${2:-5}"
  if [ -z "${PFLOCK_FORCE_MKDIR:-}" ] && command -v flock >/dev/null 2>&1; then
    flock -w "$to" 9            # real flock on the inherited fd 9
    return
  fi
  local d="${lf}.d" hp deadline nap=0.05
  # Use a sub-second nap where the platform's sleep supports it (BSD/GNU do — and the
  # mkdir path only runs where flock is absent, i.e. macOS/BSD); fall back to 1s on a
  # strict POSIX sleep. Coarse 1s naps would throttle throughput to ~1 acquire/sec and
  # make contended waiters spuriously time out.
  sleep 0.05 2>/dev/null || nap=1
  deadline=$(( $(date +%s) + to ))
  while ! mkdir "$d" 2>/dev/null; do
    # Steal a stale lock whose recorded holder PID is gone (crash-safe).
    if [ -f "$d/pid" ]; then
      hp="$(cat "$d/pid" 2>/dev/null || true)"
      if [ -n "$hp" ] && ! kill -0 "$hp" 2>/dev/null; then rm -rf "$d" 2>/dev/null || true; continue; fi
    fi
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep "$nap"
  done
  echo "$$" > "$d/pid" 2>/dev/null || true
  trap 'rm -rf "'"$d"'" 2>/dev/null || true' EXIT   # auto-release on subshell exit
  return 0
}
fi

# --- Canonical capability enum ---------------------------------------------------
# Extend here (and in docs/agent-coordination.md). Each capability is a single
# lowercase token. Destructive/outward capabilities are additionally listed in
# AGENT_CAPS_DESTRUCTIVE so enforcement layers can require owner-confirmation.
#
# team-coordinate / task-bid / knowledge-share power the self-organizing team protocol
# (Contract-Net over A2A — see docs/team-coordination.md). They are NON-destructive: they
# let an authorized peer PARTICIPATE (invite/cfp/award/progress/snapshot/lease → coordinate;
# bid/result → task-bid; kb.publish → knowledge-share). The actual work a team task drives
# still passes through the normal capability-scoped processor + owner-confirmation, so a
# team award can never itself trigger a rebuild/merge unattended.
#
# self-directed / consult / claim-area power the REMOTE-AGENT coordination protocol
# (autonomous peers coordinating with our coordinator — see
# docs/team-coordination-remote-agents.md). Also NON-destructive: announce initiatives →
# self-directed; consult threads + conflict reconciliation (request/advise/ack/
# commit_done, conflict.open/resolve) → consult; the awareness/claim/negotiate fabric
# (work.intent/status who's-on-this broadcasts, ADVISORY area claims/acks/heartbeats,
# split.propose/agree partitions) → claim-area. Claims are soft — they never forbid
# parallel work — and a consult can ASK us to apply matching changes on our side, but
# applying them still runs the normal local workflow with admin confirmation.
#
# provision-ingress powers the pluggable DNS/ingress provider (see
# provision-ingress.README.md). An authorized peer (e.g. Mission Control / AMC) may REQUEST
# a public hostname for a service it spawned; THIS instance does the Cloudflare provisioning
# under ITS OWN credential + owner consent, and the credential NEVER leaves this side. It is
# DESTRUCTIVE/outward (owner-granted AND owner-confirmed PER provision, rebuild-reload class):
# /process-agent-requests only PLANS it (read-only) and STOPS; the owner disposes. The one
# capability gates both the provision and deprovision operations (op named in the request).
AGENT_CAPABILITIES="read-status chat dev-advice rebuild-reload-service review-merge-pr team-coordinate task-bid knowledge-share self-directed consult claim-area deck provision-ingress"
AGENT_CAPS_DESTRUCTIVE="rebuild-reload-service review-merge-pr provision-ingress"

# --- Registry path resolution ----------------------------------------------------
# Precedence: explicit override → CLAUDE_PROJECT_DIR → derive from this script's dir.
# Daemon-invoked hooks lack CLAUDE_PROJECT_DIR, so fall back to <hooks>/../agent/.
_ar_registry_path() {
  if [ -n "${AGENT_REGISTRY_FILE:-}" ]; then
    printf '%s' "$AGENT_REGISTRY_FILE"; return 0
  fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s' "$CLAUDE_PROJECT_DIR/.claude/agent/agent-registry.json"; return 0
  fi
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  if [ -n "$self_dir" ]; then
    printf '%s' "$self_dir/../agent/agent-registry.json"; return 0
  fi
  printf '%s' "./.claude/agent/agent-registry.json"
}

AGENT_REGISTRY_FILE="$(_ar_registry_path)"

# --- Atomic, locked read-modify-write --------------------------------------------
_ar_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

_ar_ensure() {
  local f="$AGENT_REGISTRY_FILE" dir
  dir="$(dirname "$f")"
  mkdir -p "$dir" 2>/dev/null || true
  if [ ! -f "$f" ]; then
    printf '%s\n' "{\"version\":1,\"updated_at\":\"$(_ar_now)\",\"agents\":{}}" > "$f" 2>/dev/null || true
    chmod 600 "$f" 2>/dev/null || true
  fi
}

# _ar_write <jq-filter> [jq-args...] : apply filter to the registry atomically.
_ar_write() {
  _ar_ensure
  local f="$AGENT_REGISTRY_FILE" filter="$1"; shift
  local lock="$f.lock" tmp="$f.tmp.$$"
  (
    _pflock "$lock" 5 2>/dev/null || true
    if jq "$@" "$filter" "$f" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$f"
    else
      rm -f "$tmp" 2>/dev/null || true
      return 1
    fi
  ) 9>"$lock"
}

_ar_read() {  # _ar_read [jq-opts...] <jq-filter>  — filter is the LAST argument
  _ar_ensure
  local args=( "$@" ) n
  n=${#args[@]}
  [ "$n" -ge 1 ] || return 1
  local filter="${args[$((n-1))]}"
  unset 'args[$((n-1))]'
  jq "${args[@]}" "$filter" "$AGENT_REGISTRY_FILE" 2>/dev/null
}

# --- Lookup: resolve a free-form query → the pubkey KEY of the matching entry ----
# Matches (in order): exact key, exact npub, exact unicityName (case-insensitive),
# unique short hex-prefix. Prints the key on stdout, or nothing (exit 1) if no/ambiguous.
# Prints the resolved pubkey key, or the sentinel "__AMBIGUOUS__" when a NAME (or hex
# prefix) matches more than one distinct pubkey — so name-based authorize/deny refuses
# rather than acting on the wrong (possibly impersonating) key. Exact key/npub always win
# and are unique.
_ar_resolve_key() {
  local q="$1"
  [ -n "$q" ] || return 1
  _ar_ensure
  jq -r --arg q "$q" '
    .agents as $a
    | ($q | ascii_downcase) as $ql
    | ( [ $a | keys[] | select(. == $q) ]
        + [ $a | to_entries[] | select(.value.npub == $q) | .key ]
      ) as $idmatch
    | if ($idmatch | length) > 0 then ($idmatch | first)
      else
        ( [ $a | to_entries[]
            | select((.value.unicityName // "" | ascii_downcase) == $ql and $ql != "") | .key ]
          | unique ) as $named
        | if   ($named | length) == 1 then $named[0]
          elif ($named | length) >  1 then "__AMBIGUOUS__"
          else
            ( [ $a | keys[] | select(startswith($q)) ] | unique ) as $pre
            | if   ($pre | length) == 1 then $pre[0]
              elif ($pre | length) >  1 then "__AMBIGUOUS__"
              else empty end
          end
      end
  ' "$AGENT_REGISTRY_FILE" 2>/dev/null | head -1
}

# --- Public helpers (for sourcing hooks) -----------------------------------------
# registry_status <query> : echoes authorized|pending|denied|unknown
registry_status() {
  local key; key="$(_ar_resolve_key "$1")"
  if [ -z "$key" ] || [ "$key" = "__AMBIGUOUS__" ]; then echo "unknown"; return 0; fi
  _ar_read -r --arg k "$key" '.agents[$k].status // "unknown"'
}

# registry_has_cap <query> <capability> : exit 0 iff authorized AND cap granted
registry_has_cap() {
  local key; key="$(_ar_resolve_key "$1")"
  [ -n "$key" ] && [ "$key" != "__AMBIGUOUS__" ] || return 1
  local ok
  ok="$(_ar_read -r --arg k "$key" --arg c "$2" \
    '(.agents[$k] | select(.status=="authorized") | .capabilities // [] | index($c)) // empty')"
  [ -n "$ok" ]
}

_ar_is_destructive_cap() {
  case " $AGENT_CAPS_DESTRUCTIVE " in *" $1 "*) return 0;; *) return 1;; esac
}

_ar_validate_caps() {  # prints validated space-joined caps; errors on unknown
  local raw="$1" out=() c
  raw="${raw//,/ }"
  for c in $raw; do
    case " $AGENT_CAPABILITIES " in
      *" $c "*) out+=("$c");;
      *) echo "ERR:unknown-capability:$c" >&2; return 1;;
    esac
  done
  printf '%s' "${out[*]:-}"
}

# --- npub → hex, self-contained (for pre-authorize-by-npub) ----------------------
# Decode a bech32 npub → 32-byte x-only pubkey hex WITHOUT the Nostr SDK (ESM import
# of the SDK only resolves when sphere-helper.mjs sits inside the setup repo, which is
# not the case in the concierge session). A pure decoder here means `authorize <npub>`
# works everywhere. Prints lowercase hex on success; empty + non-zero on anything that
# is not a structurally valid npub.
_ar_npub_to_hex() {
  local npub="$1" hex=""
  case "$npub" in npub1*) ;; *) return 1;; esac
  command -v node >/dev/null 2>&1 || return 1
  hex="$(printf '%s' "$npub" | node -e '
    const CH="qpzry9x8gf2tvdw0s3jn54khce6mua7l";
    // Full bech32 verification — the checksum MUST validate (polymod===1 over the
    // hrp-expansion + data), and the 5→8-bit regroup MUST leave no non-zero padding.
    // Without this a valid-HRP but corrupted npub decoded to a plausible-looking (but
    // wrong) 32-byte key, silently authorizing the WRONG identity.
    const polymod=(vals)=>{const G=[0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3];
      let chk=1;for(const v of vals){const b=chk>>>25;chk=((chk&0x1ffffff)<<5)^v;
        for(let i=0;i<5;i++)if((b>>i)&1)chk^=G[i];}return chk>>>0;};
    const hrpExpand=(hrp)=>{const r=[];for(let i=0;i<hrp.length;i++)r.push(hrp.charCodeAt(i)>>5);
      r.push(0);for(let i=0;i<hrp.length;i++)r.push(hrp.charCodeAt(i)&31);return r;};
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      s=s.trim().toLowerCase();
      const pos=s.lastIndexOf("1");
      if(pos<1){process.exit(1);}
      const hrp=s.slice(0,pos), data=s.slice(pos+1);
      if(hrp!=="npub"){process.exit(1);}
      const vals=[];for(const c of data){const i=CH.indexOf(c);if(i<0)process.exit(1);vals.push(i);}
      if(vals.length<7)process.exit(1);                      // 6 checksum + >=1 data
      if(polymod(hrpExpand(hrp).concat(vals))!==1)process.exit(1);   // checksum MUST verify
      const d5=vals.slice(0,-6);              // drop the 6-char bech32 checksum
      let acc=0,bits=0;const out=[];
      for(const v of d5){acc=(acc<<5)|v;bits+=5;while(bits>=8){bits-=8;out.push((acc>>bits)&0xff);}}
      if(bits>=5||((acc<<(8-bits))&0xff)!==0)process.exit(1);        // no non-zero padding
      if(out.length!==32)process.exit(1);
      process.stdout.write(Buffer.from(out).toString("hex"));
    });
  ' 2>/dev/null || true)"
  printf '%s' "$hex" | grep -qiE '^[0-9a-f]{64}$' || return 1
  printf '%s' "$hex" | tr 'A-F' 'a-f'
}

# --- Deferred-envelope replay (peer authorization chicken-and-egg) ----------------
# A peer's FIRST coordination envelope arrives before it is authorized, so classify-
# inbound.sh stashes it under <STATE_DIR>/agent-deferred/<hex>/. On a successful grant
# we hand the hex to remote-coord.sh, which re-enqueues each stashed envelope by kind
# (peer verb → consult queue, team verb → team queue) and clears the stash. remote-
# coord.sh sources both engines, so it owns the replay; we only trigger it. Best-effort
# and silent on absence — never breaks an authorize.
_ar_replay_deferred_for() {  # <hex>
  local hex="$1"
  [ -n "$hex" ] || return 0
  local self_dir rc
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  rc="$self_dir/remote-coord.sh"
  [ -f "$rc" ] || return 0
  local n; n="$(bash "$rc" replay-deferred "$hex" 2>/dev/null || echo 0)"
  [ "${n:-0}" != "0" ] && echo "replayed ${n} deferred envelope(s) for ${hex}" >&2 || true
}

# --- Deny-stickiness surface (owner-in-the-loop) ----------------------------------
# When an AUTOMATIC / ticket-driven authorize is REFUSED because the peer is currently
# `denied`, record the blocked attempt so the Stop gate (check-diagnostics.sh) prompts the
# owner. A denied agent can NEVER un-deny itself; only an explicit owner authorize does.
_ar_resolve_state_dir() {  # (re)derive the per-repo STATE_DIR the SAME way every other hook does
  # DERIVE via state-dir.sh (from the hooks path), never trust an inherited env value —
  # check-diagnostics.sh and classify-inbound.sh both source it unconditionally, so the
  # surface MUST land exactly where the Stop gate reads it. (An inherited STATE_DIR can be a
  # STALE value: ticket.sh sources remote-coord → state-dir, mutating the exported var before
  # it spawns `authorize`.) Always mkdir so a first write never fails on a missing dir.
  local sd; sd="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)/state-dir.sh"
  if [ -f "$sd" ]; then . "$sd" 2>/dev/null || true; fi
  [ -n "${STATE_DIR:-}" ] || STATE_DIR="/tmp/claude"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
}

_ar_surface_denied_reauth() {  # <hex> [context-note]
  local hex="$1" ctx="${2:-}"
  [ -n "$hex" ] || return 0
  _ar_resolve_state_dir
  # NB: declare $sf on its own line — a single `local a=$X b=$a` expands $a from the OUTER
  # scope (unset here) BEFORE the assignment, tripping `set -u`.
  local sf="$STATE_DIR/agent-denied-reauth.json"
  local lock="$sf.lock" tmp="$sf.tmp.$$" now name
  now="$(_ar_now)"
  name="$(_ar_read -r --arg k "$hex" '.agents[$k].unicityName // ""' 2>/dev/null || echo "")"
  (
    _pflock "$lock" 5 2>/dev/null || true
    [ -f "$sf" ] || printf '%s\n' '{"count":0,"items":[],"updated_at":""}' > "$sf" 2>/dev/null || true
    if jq --arg k "$hex" --arg name "$name" --arg ctx "$ctx" --arg now "$now" '
        ( (.items // [] | map(select(.pubkey == $k)) | first)
          // {pubkey:$k, attempts:0, firstAt:$now} ) as $prev
        | .items = ((.items // []) | map(select(.pubkey != $k)))
            + [ $prev | .pubkey=$k | .unicityName=$name | .lastContext=$ctx | .lastAt=$now
                      | .attempts=((.attempts // 0)+1) ]
        | .count = (.items | length) | .updated_at = $now
      ' "$sf" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$sf" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    else rm -f "$tmp" 2>/dev/null || true; fi
  ) 9>"$lock"
  # Best-effort desktop / push notification (never fatal).
  local nf; nf="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)/notify.sh"
  if [ -f "$nf" ]; then
    ( . "$nf" 2>/dev/null && notify "Denied agent re-auth blocked" \
        "Denied ${hex:0:12}… attempted re-authorization via an automatic path. Explicitly re-authorize to allow." \
        "critical" ) 2>/dev/null || true
  fi
}

_ar_clear_denied_reauth() {  # <hex> — drop a resolved deny-reauth surface entry
  local hex="$1"; [ -n "$hex" ] || return 0
  _ar_resolve_state_dir
  local sf="$STATE_DIR/agent-denied-reauth.json"
  local lock="$sf.lock" tmp="$sf.tmp.$$"
  [ -f "$sf" ] || return 0
  (
    _pflock "$lock" 5 2>/dev/null || true
    if jq --arg k "$hex" '
        .items = ((.items // []) | map(select(.pubkey != $k))) | .count = (.items | length)
      ' "$sf" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$sf" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    else rm -f "$tmp" 2>/dev/null || true; fi
  ) 9>"$lock"
}

# ================================================================================
# CLI dispatch (only when executed directly, not when sourced)
# ================================================================================
_ar_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    path) printf '%s\n' "$AGENT_REGISTRY_FILE" ;;
    ensure) _ar_ensure; printf '%s\n' "$AGENT_REGISTRY_FILE" ;;
    caps) printf '%s\n' "$AGENT_CAPABILITIES" ;;
    caps-destructive) printf '%s\n' "$AGENT_CAPS_DESTRUCTIVE" ;;

    get)
      local key; key="$(_ar_resolve_key "${1:-}")"
      [ "$key" = "__AMBIGUOUS__" ] && { echo "ERR: '${1:-}' is ambiguous (matches multiple pubkeys) — pass the exact pubkey or npub" >&2; echo '{}'; return 1; }
      [ -n "$key" ] || { echo '{}'; return 1; }
      _ar_read --arg k "$key" '.agents[$k]'
      ;;

    status) registry_status "${1:-}" ;;

    has-cap)  # has-cap <query> <cap> → prints yes|no, exit reflects result
      if registry_has_cap "${1:-}" "${2:-}"; then echo yes; else echo no; return 1; fi
      ;;

    is-destructive-cap)
      if _ar_is_destructive_cap "${1:-}"; then echo yes; else echo no; return 1; fi
      ;;

    list)  # list [status] → compact JSON array
      _ar_read --arg s "${1:-}" '
        [ .agents | to_entries[]
          | select($s == "" or .value.status == $s)
          | { name: (if (.value.unicityName // "") != "" then .value.unicityName
                     else ((.value.note // "") | if startswith("teammate: ") then (ltrimstr("teammate: ") | split(" — ")[0]) else "" end) end),
              status: .value.status,
              capabilities: (.value.capabilities // []),
              npub: (.value.npub // ""), pubkey: .key,
              did: ("did:nostr:" + .key),
              intro: (.value.intro // ""), firstContact: (.value.firstContact // ""),
              requestedSkill: (.value.requestedSkill // ""),
              impersonationSuspect: (.value.impersonationSuspect // false),
              impersonationOf: (.value.impersonationOf // ""),
              firstSeen: .value.firstSeen, lastSeen: (.value.lastSeen // ""),
              note: (.value.note // "") } ]'
      ;;

    # find-name <name> → JSON array of {pubkey,status,npub} whose claimed name matches
    # (case-insensitive). Used to detect a name claimed by a DIFFERENT pubkey.
    find-name)
      _ar_read --arg n "${1:-}" '
        ($n | ascii_downcase) as $nl
        | [ .agents | to_entries[]
            | select((.value.unicityName // "" | ascii_downcase) == $nl and $nl != "")
            | { pubkey: .key, status: .value.status, npub: (.value.npub // "") } ]'
      ;;

    upsert-pending)
      # Create a pending entry for an unknown sender, or refresh lastSeen on an
      # existing one. NEVER changes an authorized/denied status (idempotent, safe
      # to call on every inbound message).
      local pubkey="" npub="" name="" intro="" mtype="" group="" suspect="" skill=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --pubkey)     pubkey="${2:-}"; shift 2;;
          --npub)       npub="${2:-}"; shift 2;;
          --name)       name="${2:-}"; shift 2;;
          --intro)      intro="${2:-}"; shift 2;;
          --type)       mtype="${2:-}"; shift 2;;
          --group)      group="${2:-}"; shift 2;;
          --suspect-of) suspect="${2:-}"; shift 2;;   # pubkey this sender may be impersonating
          --skill)      skill="${2:-}"; shift 2;;      # A2A skill/capability the sender asked for
          *) shift;;
        esac
      done
      [ -n "$pubkey" ] || { echo "ERR: --pubkey required" >&2; return 1; }
      _ar_write '
        .updated_at=$now
        | .agents[$k] =
          ( (.agents[$k] // {
              pubkey:$k, npub:$npub, unicityName:$name, status:"pending",
              capabilities:[], firstSeen:$now, intro:$intro,
              firstContact:$mtype, note:"" })
            | .pubkey = $k
            | .lastSeen = $now
            | (if (.npub // "")   == "" then .npub = $npub else . end)
            | (if (.unicityName // "") == "" then .unicityName = $name else . end)
            | (if (.intro // "")  == "" then .intro = $intro else . end)
            | (if (.status // "pending") == "pending" then .status = "pending" else . end)
            | (if $skill   != "" then .requestedSkill = $skill else . end)
            | (if $suspect != "" then (.impersonationSuspect = true | .impersonationOf = $suspect) else . end)
          )
      ' --arg k "$pubkey" --arg npub "$npub" --arg name "$name" \
        --arg intro "$intro" --arg mtype "$mtype" --arg suspect "$suspect" --arg skill "$skill" \
        --arg now "$(_ar_now)" \
        && registry_status "$pubkey"
      ;;

    authorize)  # authorize <query> [caps] [--note <text>] [--owner]
      # --owner marks an OWNER-EXPLICIT authorization — the ONLY thing that may un-deny a
      # denied peer. Without it (every AUTOMATIC / ticket-driven caller) a currently-denied
      # peer is REFUSED, so a denied agent can never re-authorize itself (e.g. by re-redeeming
      # an already-used invite ticket). This default-safe posture means new auto paths inherit
      # the block for free; only the owner skills pass --owner.
      local q="${1:-}"; shift || true
      local caps="" note="" owner=0
      # First non-flag token after the query is the (optional) positional caps list.
      if [ $# -gt 0 ] && [ "${1#--}" = "${1:-}" ]; then caps="${1:-}"; shift || true; fi
      while [ $# -gt 0 ]; do
        case "${1:-}" in
          --note)  note="${2:-}"; shift 2 || true;;
          --owner) owner=1; shift || true;;
          *) shift || true;;
        esac
      done
      local key; key="$(_ar_resolve_key "$q")"
      [ "$key" = "__AMBIGUOUS__" ] && { echo "ERR: '$q' is ambiguous (matches multiple pubkeys — possible impersonation) — authorize by the exact pubkey or npub, not the name" >&2; return 1; }
      # PRE-AUTHORIZE-BY-NPUB: no existing entry, but the query is an npub → decode it to
      # the pubkey hex and authorize that key directly (seeding a fresh entry). Lets the
      # owner grant a peer BEFORE its first message ever arrives. Invalid npub → hard error,
      # never a bogus write. A non-npub with no match keeps the original must-make-contact error.
      local preauth_npub=""
      if [ -z "$key" ]; then
        case "$q" in
          npub1*)
            key="$(_ar_npub_to_hex "$q")" \
              || { echo "ERR: '$q' is not a decodable npub — pass a valid npub or the exact pubkey hex" >&2; return 1; }
            preauth_npub="$q"
            ;;
          *)
            echo "ERR: no registry entry matches '$q' (must have made contact first, or pass its exact pubkey/npub)" >&2; return 1
            ;;
        esac
      fi
      # DENY IS STICKY. If this key is currently `denied`, only an OWNER-EXPLICIT authorize
      # (--owner) may un-deny it. Every automatic path (ticket redeem / finalize-grant /
      # re-redeem, and any future non-owner auto-auth) omits --owner, so it is REFUSED here
      # and the attempt is surfaced to the owner. This is the un-bypassable chokepoint: the
      # check is the DEFAULT for `authorize`, so no auto caller can route around it.
      local curstatus; curstatus="$(_ar_read -r --arg k "$key" '.agents[$k].status // "unknown"')"
      if [ "$curstatus" = "denied" ] && [ "$owner" != "1" ]; then
        _ar_surface_denied_reauth "$key" "$note"
        echo "REFUSED: ${key:0:12}… is DENIED — automatic re-authorization blocked; the owner must explicitly re-authorize (denied agent attempted re-authorization, e.g. via ticket re-redeem)." >&2
        return 3
      fi
      local vcaps; vcaps="$(_ar_validate_caps "$caps")" || return 1
      # shellcheck disable=SC2206
      local capsjson; capsjson="$(printf '%s\n' $vcaps | jq -R . | jq -sc .)"
      _ar_write '
        .updated_at=$now
        | .agents[$k].status="authorized"
        | .agents[$k].capabilities=$caps
        | .agents[$k].pubkey=$k
        | (if $pnpub != "" and ((.agents[$k].npub // "") == "") then .agents[$k].npub=$pnpub else . end)
        | (if (.agents[$k].firstSeen // "") == "" then .agents[$k].firstSeen=$now else . end)
        | .agents[$k].decidedAt=$now
        | (if $note != "" then .agents[$k].note=$note else . end)
      ' --arg k "$key" --argjson caps "$capsjson" --arg note "$note" --arg pnpub "$preauth_npub" --arg now "$(_ar_now)" \
        && { _ar_clear_denied_reauth "$key"; _ar_read --arg k "$key" '.agents[$k]'; _ar_replay_deferred_for "$key"; }
      ;;

    deny)  # deny <query> [--note <text>]
      local q="${1:-}"; shift || true
      local note=""
      [ "${1:-}" = "--note" ] && { note="${2:-}"; shift 2 || true; }
      local key; key="$(_ar_resolve_key "$q")"
      [ "$key" = "__AMBIGUOUS__" ] && { echo "ERR: '$q' is ambiguous (matches multiple pubkeys) — deny by the exact pubkey or npub" >&2; return 1; }
      [ -n "$key" ] || { echo "ERR: no registry entry matches '$q'" >&2; return 1; }
      _ar_write '
        .updated_at=$now
        | .agents[$k].status="denied"
        | .agents[$k].capabilities=[]
        | .agents[$k].decidedAt=$now
        | (if $note != "" then .agents[$k].note=$note else . end)
      ' --arg k "$key" --arg note "$note" --arg now "$(_ar_now)" \
        && _ar_read --arg k "$key" '.agents[$k]'
      ;;

    set-name)  # set-name <query> <name>  (label a peer, e.g. before outbound first-contact)
      local key; key="$(_ar_resolve_key "${1:-}")"
      [ "$key" = "__AMBIGUOUS__" ] && { echo "ERR: '${1:-}' is ambiguous — pass the exact pubkey or npub" >&2; return 1; }
      [ -n "$key" ] || { echo "ERR: no match for '${1:-}'" >&2; return 1; }
      _ar_write '.updated_at=$now | .agents[$k].unicityName=$name' \
        --arg k "$key" --arg name "${2:-}" --arg now "$(_ar_now)"
      ;;

    # Register (or refresh) a peer we are about to contact outbound. Keeps status
    # untouched if it already exists; seeds a "peer" record (NOT authorized) if new.
    upsert-peer)  # upsert-peer --npub <npub> [--name <name>] [--pubkey <hex>]
      local pubkey="" npub="" name=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --pubkey) pubkey="${2:-}"; shift 2;;
          --npub)   npub="${2:-}"; shift 2;;
          --name)   name="${2:-}"; shift 2;;
          *) shift;;
        esac
      done
      # Prefer the pubkey HEX as the registry key so this record MERGES onto any entry
      # `authorize` created (it keys by hex via _ar_npub_to_hex). Deriving the hex from a
      # bare --npub avoids a duplicate {pubkey:"",status:"peer"} record beside the real one.
      if [ -z "$pubkey" ] && [ -n "$npub" ]; then
        pubkey="$(_ar_npub_to_hex "$npub" 2>/dev/null || true)"
      fi
      # Key by pubkey hex when known (derived or given), else fall back to the npub string.
      local key="${pubkey:-$npub}"
      [ -n "$key" ] || { echo "ERR: --npub or --pubkey required" >&2; return 1; }
      _ar_write '
        .updated_at=$now
        | .agents[$k] =
          ( (.agents[$k] // {
              pubkey:$pk, npub:$npub, unicityName:$name, status:"peer",
              capabilities:[], firstSeen:$now, intro:"", note:"outbound-initiated" })
            | .lastSeen=$now
            | (if (.pubkey // "") == "" then .pubkey=$pk else . end)
            | (if (.npub // "") == "" then .npub=$npub else . end)
            | (if (.unicityName // "") == "" then .unicityName=$name else . end) )
      ' --arg k "$key" --arg pk "$pubkey" --arg npub "$npub" --arg name "$name" --arg now "$(_ar_now)" \
        && printf 'peer recorded: %s\n' "$key"
      ;;

    *)
      cat >&2 <<EOF
agent-registry.sh — authorized-agents registry (DEFAULT-DENY)
Usage: agent-registry.sh <command> [args]

  path                                   Print resolved registry file path
  ensure                                 Create empty default-deny registry if missing
  caps                                   List the capability enum
  caps-destructive                       List capabilities that still need owner-confirm
  get <query>                            Print the matching entry (pubkey|npub|name|hex-prefix)
  status <query>                         authorized|pending|denied|unknown
  has-cap <query> <cap>                  yes/no (+ exit code) — the enforcement gate
  is-destructive-cap <cap>               yes/no
  list [status]                          JSON array (optionally filtered by status)
  upsert-pending --pubkey <hex> [--npub --name --intro --type --group]
  upsert-peer  --npub <npub> [--name --pubkey]
  authorize <query> [cap,cap,...] [--note <text>] [--owner]
                                         --owner = owner-explicit (the ONLY thing that
                                         un-denies a denied peer; auto paths omit it)
  deny <query> [--note <text>]
  set-name <query> <name>

Capabilities: $AGENT_CAPABILITIES
EOF
      return 1
      ;;
  esac
}

# Only dispatch CLI when executed directly (not sourced).
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  _ar_cli "$@"
fi
