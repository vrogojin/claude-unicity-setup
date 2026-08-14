#!/usr/bin/env bash
# onboard-teammate.sh — one-shot teammate onboarding for A2A coordination.
#
# ADMIN SIDE (run by the coordinator/localhost session). Pre-authorizes a
# teammate's Nostr identity in our default-deny registry — thanks to
# pre-authorize-by-npub (issue #14) this works even BEFORE they have ever
# messaged us — then prints a ready-to-send invitation with everything the
# teammate runs on their machine to join.
#
# Usage:
#   onboard-teammate.sh <npub> --name <name> [--caps <csv>] [--note <text>]
#   onboard-teammate.sh --name <name>                 # no npub yet → print setup steps only
#
# Default caps grant the full autonomous-remote-agent surface (all non-locking):
#   team-coordinate,task-bid,knowledge-share,self-directed,consult,claim-area
#
# Env: CLAUDE_PROJECT_DIR (defaults to the project this hook tree lives under).
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${CLAUDE_PROJECT_DIR:=$(cd "$HOOK_DIR/../.." && pwd)}"
REGISTRY="$HOOK_DIR/agent-registry.sh"
RC="$HOOK_DIR/remote-coord.sh"
AGENT_DIR="$CLAUDE_PROJECT_DIR/.claude/agent"

DEFAULT_CAPS="team-coordinate,task-bid,knowledge-share,self-directed,consult,claim-area"

npub=""; nametag=""; name=""; caps="$DEFAULT_CAPS"; note=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name="${2:-}"; shift 2;;
    --caps) caps="${2:-}"; shift 2;;
    --note) note="${2:-}"; shift 2;;
    npub1*) npub="$1"; shift;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    # A bare Unicity nametag (lowercase alnum / - / _) is accepted and resolved to an npub
    # via the Sphere SDK, so you can authorize a teammate by the NAME they gave you.
    [a-z0-9]*) nametag="$1"; shift;;
    *) echo "onboard-teammate: unknown arg '$1'" >&2; exit 2;;
  esac
done
[ -n "$name" ] || name="$nametag"
[ -n "$name" ] || { echo "ERR: --name <name> required (or pass a nametag)" >&2; exit 2; }

# If given a nametag instead of an npub, resolve it -> npub via the Sphere SDK.
if [ -z "$npub" ] && [ -n "$nametag" ]; then
  HELPER="$(command -v sphere-helper.mjs 2>/dev/null || true)"
  [ -n "$HELPER" ] || for p in /home/vrogojin/claude_unicity_setup/lib/sphere-helper.mjs "$HOME"/claude*unicity*setup/lib/sphere-helper.mjs; do
    [ -f "$p" ] && { HELPER="$p"; break; }; done
  [ -n "$HELPER" ] || { echo "ERR: sphere-helper.mjs not found to resolve nametag '$nametag'" >&2; exit 1; }
  echo "== Resolving nametag '$nametag' -> npub via the Sphere SDK ..."
  npub="$(node "$HELPER" resolve-nametag "$nametag" 2>/dev/null | jq -r '.npub // empty' 2>/dev/null)"
  [ -n "$npub" ] || { echo "ERR: nametag '$nametag' did not resolve (registered? sphere-helper working?)" >&2; exit 1; }
  echo "   -> $npub"
fi
[ -n "$npub" ] || { echo "ERR: pass the teammate's npub OR their Unicity nametag" >&2; exit 2; }

# Our coordinator identity + relay, to embed in the invite.
OUR_NPUB="$(CLAUDE_PROJECT_DIR="$CLAUDE_PROJECT_DIR" bash "$RC" self 2>/dev/null | sed -n 's/.*npub=\([^ ]*\).*/\1/p')"
OUR_NAME="$(CLAUDE_PROJECT_DIR="$CLAUDE_PROJECT_DIR" bash "$RC" self 2>/dev/null | sed -n 's/.*name=\([^ ]*\).*/\1/p')"
RELAY="$(jq -r '(.relays // .group.relays // ["wss://nostr-relay.testnet.unicity.network"])[0]' "$AGENT_DIR/daemon.json" 2>/dev/null || echo 'wss://nostr-relay.testnet.unicity.network')"

if [ -n "$npub" ]; then
  echo "== Pre-authorizing $name ($npub) with caps: $caps =="
  OUT="$(bash "$REGISTRY" authorize "$npub" "$caps" --note "teammate: $name${note:+ — $note}" 2>&1)" || {
    echo "$OUT" >&2; echo "ERR: authorize failed" >&2; exit 1; }
  echo "$OUT" | jq -c '{name:.unicityName, status, caps:.capabilities, hex:.pubkey}' 2>/dev/null || echo "$OUT"
  echo
fi

cat <<INVITE
────────────────────────────────────────────────────────────────────────
  INVITATION — send this to $name
────────────────────────────────────────────────────────────────────────
You're being added as an autonomous peer on the Concierge coordination team.
Coordinator: ${OUR_NAME:-concierge-coordinator}
Coordinator npub: ${OUR_NPUB:-<coordinator-npub>}
Relay: $RELAY

On your machine (one time):
  1. git clone git@github.com:vrogojin/claude-unicity-setup.git && cd claude-unicity-setup
  2. ./setup.sh <path-to-your-concierge-checkout>
       # installs sphere-sdk, MINTS your Nostr identity, writes .claude/agent + hooks + skills,
       # records the transport helper path, and runs a PREFLIGHT (identity + transport).
       # It must end with "Setup Complete" — if the preflight FAILS, stop and fix it; a broken
       # transport makes your outbound coordination messages silently vanish.
  3. SEND YOUR npub BACK to the coordinator (the "npub" setup.sh printed) so it can authorize
       you, if you have not already. Nothing routes until your npub is authorized.
  4. nohup node lib/sphere-daemon.mjs start --project <path-to-your-concierge-checkout> --live >/tmp/sphere-daemon.log 2>&1 &
       # --live = sub-second push transport; polls every 5s as fallback (default). Runs from
       # the CLONE dir so the transport helper + node_modules resolve. The daemon is
       # foreground — a bare '… &' dies with your shell, so use nohup (above) or a systemd
       # --user unit for durability.

Then, in your Claude Code session on that project:
  /consult-coordinator ${OUR_NAME:-concierge-coord} "what I intend to work on"
     # research-before-claim → who's-on-this broadcast → advisory claim →
     # consult the coordinator for any matching changes on the concierge side.
  # VERIFY the send worked: you should see "sent → …", NOT "DRY-RUN send" or "ERROR(...)".
  #   DRY-RUN  → you set TEAM_DRY_RUN=1 (unset it to really send).
  #   ERROR    → transport/identity unresolved: re-run setup.sh (its preflight pinpoints it).

You're already authorized (${caps}); your first message will route straight
through — no waiting. Work freely, even in parallel on shared files; the
protocol handles awareness, split negotiation, and conflict reconciliation.
────────────────────────────────────────────────────────────────────────
INVITE

if [ -z "$npub" ]; then
  echo
  echo "NOTE: no npub supplied — teammate has not been authorized yet."
  echo "Once they send their npub, run:"
  echo "  onboard-teammate.sh <their-npub> --name \"$name\""
fi
