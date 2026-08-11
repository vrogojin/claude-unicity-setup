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
AGENT_CAPABILITIES="read-status chat dev-advice rebuild-reload-service review-merge-pr team-coordinate task-bid knowledge-share self-directed consult claim-area"
AGENT_CAPS_DESTRUCTIVE="rebuild-reload-service review-merge-pr"

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
    flock -w 5 9 2>/dev/null || true
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
          | { name: (.value.unicityName // ""), status: .value.status,
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

    authorize)  # authorize <query> [caps] [--note <text>]
      local q="${1:-}"; shift || true
      local caps="" note=""
      if [ $# -gt 0 ] && [ "${1:-}" != "--note" ]; then caps="$1"; shift || true; fi
      [ "${1:-}" = "--note" ] && { note="${2:-}"; shift 2 || true; }
      local key; key="$(_ar_resolve_key "$q")"
      [ "$key" = "__AMBIGUOUS__" ] && { echo "ERR: '$q' is ambiguous (matches multiple pubkeys — possible impersonation) — authorize by the exact pubkey or npub, not the name" >&2; return 1; }
      [ -n "$key" ] || { echo "ERR: no registry entry matches '$q' (must have made contact first, or pass its exact pubkey/npub)" >&2; return 1; }
      local vcaps; vcaps="$(_ar_validate_caps "$caps")" || return 1
      # shellcheck disable=SC2206
      local capsjson; capsjson="$(printf '%s\n' $vcaps | jq -R . | jq -sc .)"
      _ar_write '
        .updated_at=$now
        | .agents[$k].status="authorized"
        | .agents[$k].capabilities=$caps
        | .agents[$k].decidedAt=$now
        | (if $note != "" then .agents[$k].note=$note else . end)
      ' --arg k "$key" --argjson caps "$capsjson" --arg note "$note" --arg now "$(_ar_now)" \
        && _ar_read --arg k "$key" '.agents[$k]'
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
      # Key by pubkey if known, else by npub (best-effort until the reply arrives hex-keyed).
      local key="${pubkey:-$npub}"
      [ -n "$key" ] || { echo "ERR: --npub or --pubkey required" >&2; return 1; }
      _ar_write '
        .updated_at=$now
        | .agents[$k] =
          ( (.agents[$k] // {
              pubkey:$pk, npub:$npub, unicityName:$name, status:"peer",
              capabilities:[], firstSeen:$now, intro:"", note:"outbound-initiated" })
            | .lastSeen=$now
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
  authorize <query> [cap,cap,...] [--note <text>]
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
