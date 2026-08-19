#!/bin/bash
# ============================================================================
#  setup.sh — deploy/upgrade the Unicity Claude Code agent framework
# ============================================================================
#
#  READ ME FIRST — especially if you are an AI coding agent deciding
#  "is it safe to run this here?"  Short answer: YES, if you run it
#  non-interactively (see MODES). It is idempotent and preserving by design.
#
#  WHAT THIS DOES
#    Deploys claude_conf/ into <target-project>/.claude/ (hooks, skills,
#    settings, CLAUDE.md), mints or KEEPS a Unicity agent identity
#    (secp256k1 keypair + nametag), and writes the agent's configuration
#    (owner, relay/group, notifications, dependency tracking). Also installs
#    the Serena MCP config (.mcp.json at the project root) and seeds
#    docs/ROADMAP.md + a per-project memory record.
#
#  CONTRACT — IDEMPOTENT, PRESERVE-BY-DEFAULT
#    Re-running setup.sh on an already-configured project is a SAFE NO-OP for
#    all agent state. Every existing value is the default and is KEPT unless
#    the operator explicitly provides a new one (an interactive entry, or a
#    SETUP_* env override). Precedence for every configurable value:
#        explicit SETUP_* env override  >  existing value  >  safe default
#    ("set but empty" env override clears a value; an UNSET var never does.)
#
#    PRESERVED (never silently overwritten):
#      .claude/agent/identity.json        keypair + mnemonic + nametag.
#                                         Regenerated ONLY via FORCE_NEW_IDENTITY=1
#                                         or an explicit interactive "yes".
#      .claude/agent/config.json          owner npub/nametag, network/relay,
#                                         group id, notification URL, dep
#                                         tracking — DEEP-MERGED, so unknown/
#                                         extra keys survive too.
#      .claude/agent/agent-registry.json  peer authorizations + recorded
#                                         coordinator. Touched only when a
#                                         coordinator is explicitly supplied.
#      .claude/agent/daemon.json          relays / group subscriptions /
#                                         dm contacts are UNIONED, never dropped.
#      .claude/settings.local.json        user-accumulated permission approvals
#                                         are UNION-merged back after the copy.
#      .claude/settings.json env keys     user-added env keys merged back
#                                         (template keys win on conflict).
#      docs/ROADMAP.md, memory record,    seeded only if absent.
#      .gitignore entries                 appended only if missing.
#
#    CREATED / REFRESHED on every run (framework-owned, safe to overwrite):
#      .claude/hooks/, .claude/skills/, .claude/settings.json (hooks etc.; user
#      env keys merged back after copy), .claude/CLAUDE.md, .claude/docker/,
#      project .mcp.json (Serena server merged in), config.json
#      transport.helper_path and daemon.json hook paths (re-pointed at this
#      clone).
#
#  MODES
#    Interactive (default when stdin IS a TTY): prompts for each value, with
#      the existing value as the default — pressing Enter keeps it.
#    Non-interactive (AUTO when stdin is NOT a TTY; or --yes /
#      --non-interactive / NONINTERACTIVE=1): prompts for NOTHING and is
#      NEVER destructive. Existing values are kept; only genuinely missing
#      values are filled with safe defaults; a fresh identity is minted ONLY
#      when none exists. This is the documented safe upgrade path:
#          git pull && ./setup.sh <target-project-dir> --yes
#      (--interactive forces prompts even without a TTY, reading stdin.)
#    --dry-run: prints what a real run WOULD do, faithfully — with an existing
#      identity/nametag/config it previews KEEPING them — and writes nothing.
#
#  EXPLICIT OVERRIDES (env vars; unset = keep existing, set = explicit new value)
#    SETUP_AGENT_NAMETAG    agent's own nametag
#    SETUP_OWNER_NAMETAG    owner's nametag        SETUP_OWNER_NPUB   owner's npub
#    SETUP_COORD_NAMETAG    coordinator to pre-record (registry upsert)
#    SETUP_COORD_NPUB       coordinator npub (else resolved on the network)
#    SETUP_NETWORK          testnet | mainnet | devnet
#    SETUP_RELAY_URL        explicit relay URL (beats the network→relay map)
#    SETUP_NOTIFY_URL       mobile notification URL (ntfy.sh/<topic>)
#    SETUP_DEPS             dependency tracking: all | none | name1,name2
#    FORCE_NEW_IDENTITY=1   DESTRUCTIVE: regenerate the identity (loses the
#                           keypair AND every peer authorization)
#    SETUP_SKIP_VERIFY=1    skip the live-relay round-trip self-test (CI/offline)
#
#  PHASES
#    1 file deploy → 2 identity → 3 owner → 3b coordinator (optional) →
#    4 network → 5 notifications → 6 dep tracking → 7 group join (skipped when
#    a real group id already exists) → 8 write config (deep-merge) →
#    9 roadmap/memory seeds → 9.5 transport preflight (fatal if broken) →
#    9.6 relay round-trip self-test (non-fatal; SETUP_SKIP_VERIFY=1 skips) →
#    9.7 ticket redeem (--ticket only) → summary.
#
#  USAGE
#    First install (human):    ./setup.sh /abs/path/to/project
#    Upgrade (agent/CI-safe):  ./setup.sh /abs/path/to/project --yes
#    Preview any run:          ./setup.sh /abs/path/to/project --dry-run
#    Serena config only:       ./setup.sh /abs/path/to/project --serena-only
#    One-command onboarding:   ./setup.sh /abs/path/to/project --ticket 'ut2_…'
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$SCRIPT_DIR/claude_conf"
DRY_RUN=false
SERENA_ONLY=false
# Capture a NONINTERACTIVE=1 env request before initializing the internal flag.
NONINTERACTIVE_REQ="${NONINTERACTIVE:-}"
NONINTERACTIVE=false
FORCE_INTERACTIVE=false
ASSUME_YES=false

# --- Helpers ---

info()  { printf '\033[1;34m[info]\033[0m  %s\n' "$1"; }
ok()    { printf '\033[1;32m[ok]\033[0m    %s\n' "$1"; }
warn()  { printf '\033[1;33m[warn]\033[0m  %s\n' "$1"; }
err()   { printf '\033[1;31m[error]\033[0m %s\n' "$1" >&2; }
die()   { err "$1"; exit 1; }

# In non-interactive mode both prompt helpers NEVER read stdin: prompt_yn
# silently returns its default, prompt_input silently returns its default.
# Callers arrange for "the default" to be the existing value, which is what
# makes a promptless run preserve-by-default (see header contract).
prompt_yn() {
  local msg="$1" default="${2:-y}"
  local yn
  if [ "$NONINTERACTIVE" = "true" ]; then
    case "$default" in [yY]*) return 0;; *) return 1;; esac
  fi
  if [ "$default" = "y" ]; then
    printf '%s [Y/n] ' "$msg"
  else
    printf '%s [y/N] ' "$msg"
  fi
  read -r yn
  yn="${yn:-$default}"
  case "$yn" in [yY]*) return 0;; *) return 1;; esac
}

prompt_input() {
  local msg="$1" default="${2:-}"
  local val
  if [ "$NONINTERACTIVE" = "true" ]; then
    echo "$default"
    return 0
  fi
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$msg" "$default" >&2
  else
    printf '%s: ' "$msg" >&2
  fi
  read -r val
  echo "${val:-$default}"
}

# resolve_value <SETUP_ENV_NAME> <existing-value> <fallback-default> <prompt-msg>
#   Implements the contract precedence for one value:
#     explicit SETUP_* env override (set-but-empty ⇒ clear)  >  existing value
#     >  fallback default; prompts only in interactive mode, with the
#     existing-or-fallback value as the default (Enter keeps it).
resolve_value() {
  local envn="$1" existing="$2" fallback="$3" msg="$4"
  if [ -n "${!envn+x}" ]; then
    printf '%s' "${!envn}"
    return 0
  fi
  local def="${existing:-$fallback}"
  if [ "$NONINTERACTIVE" = "true" ]; then
    printf '%s' "$def"
    return 0
  fi
  prompt_input "$msg" "$def"
}

run_or_dry() {
  if [ "$DRY_RUN" = "true" ]; then
    info "[dry-run] $*"
  else
    "$@"
  fi
}

# Ensure sphere-sdk is available for sphere-helper.mjs
ensure_sphere_sdk() {
  local helper="$SCRIPT_DIR/lib/sphere-helper.mjs"
  if [ ! -f "$helper" ]; then
    die "lib/sphere-helper.mjs not found in $SCRIPT_DIR"
  fi

  # Check if sphere-sdk is already available
  if NODE_PATH="$SCRIPT_DIR/node_modules:${NODE_PATH:-}" node -e "require.resolve('@unicitylabs/sphere-sdk')" 2>/dev/null; then
    return 0
  fi

  # Check if target project has it
  if [ -n "${TARGET_DIR:-}" ] && [ -f "$TARGET_DIR/node_modules/@unicitylabs/sphere-sdk/package.json" ]; then
    return 0
  fi

  # Try to install in script's own directory
  info "Installing @unicitylabs/sphere-sdk..."
  if [ "$DRY_RUN" = "true" ]; then
    info "[dry-run] npm install --no-save @unicitylabs/sphere-sdk (in $SCRIPT_DIR)"
  else
    if (cd "$SCRIPT_DIR" && npm install --no-save @unicitylabs/sphere-sdk 2>&1); then
      return 0
    fi
    echo ""
    warn "@unicitylabs/sphere-sdk is not available on npm yet."
    warn "Identity creation and messaging require sphere-sdk."
    echo ""
    if [ "$NONINTERACTIVE" = "true" ]; then
      # Never prompt for a source path in non-interactive mode; report and let
      # the caller take the sdk-unavailable branch (no identity is minted).
      warn "Non-interactive mode — not prompting for a sphere-sdk source."
      warn "Fix: (cd \"$SCRIPT_DIR\" && npm install) then re-run setup.sh"
      SPHERE_SDK_AVAILABLE=false
      return 1
    fi
    echo "  Options:"
    echo "    1) Provide a local path or git URL to sphere-sdk"
    echo "    2) Skip identity creation (import existing npub/nsec later)"
    echo ""
    SPHERE_SDK_PATH=$(prompt_input "sphere-sdk path or git URL (leave empty to skip)" "")
    if [ -n "$SPHERE_SDK_PATH" ]; then
      (cd "$SCRIPT_DIR" && npm install --no-save "$SPHERE_SDK_PATH" 2>&1) || \
        die "Could not install sphere-sdk from: $SPHERE_SDK_PATH"
    else
      SPHERE_SDK_AVAILABLE=false
      return 1
    fi
  fi
}

run_sphere_helper() {
  local helper="$SCRIPT_DIR/lib/sphere-helper.mjs"
  if [ "$DRY_RUN" = "true" ]; then
    # Notice to stderr so callers that capture this helper's stdout (Phase 2
    # create-identity, Phase 7 join-group) parse ONLY the JSON below, not the notice.
    info "[dry-run] node $helper $*" >&2
    echo '{"dry_run": true}'
    return 0
  fi
  NODE_PATH="$SCRIPT_DIR/node_modules:${NODE_PATH:-}" node "$helper" "$@"
}

# --- Serena MCP deployment (Dockerized semantic code search) ---
# Deploys/merges the project-root .mcp.json for Serena and relocates all of
# Serena's writable data OFF the read-only workspace mount. Used by both the
# normal setup flow and `--serena-only`. Relies on globals: TARGET_DIR,
# CLAUDE_DIR, GITIGNORE, DRY_RUN.
deploy_serena_mcp() {
  # Claude Code reads project-scoped MCP servers from <project-root>/.mcp.json,
  # NOT from inside .claude/. The template lives in claude_conf/.mcp.json and is
  # copied into .claude/ by the recursive copy in Phase 1 (or directly by
  # --serena-only); move/merge it to the project root where Claude Code actually
  # loads it, and substitute the paths + pinned image tag.
  local MCP_TEMPLATE="$CLAUDE_DIR/.mcp.json"
  local MCP_DEST="$TARGET_DIR/.mcp.json"
  # Bump SERENA_IMAGE_VERSION whenever Dockerfile.serena changes: every machine
  # then transparently rebuilds the image on its next setup run (the tag it looks
  # for no longer exists locally), while unchanged versions are reused as-is.
  local SERENA_IMAGE_VERSION="1.0.0"
  local SERENA_IMAGE="unicity/serena:${SERENA_IMAGE_VERSION}"
  local SERENA_DOCKERFILE="$CLAUDE_DIR/docker/Dockerfile.serena"

  # Workspace ROOT that Serena is allowed to see: a BROAD, READ-ONLY, identity
  # mount (host path == container path). Identity-mounting the root is what makes
  # git worktrees self-consistent inside the container — both a worktree's files
  # AND its gitdir under <repo>/.git/worktrees/<name> resolve at their true paths
  # — so Serena's activate_project can open ANY branch/worktree/repo/folder under
  # the root. Defaults to the target repo's parent dir; override with
  # SERENA_WORKSPACE_ROOT (e.g. a shared multi-repo parent).
  local WORKSPACE_ROOT="${SERENA_WORKSPACE_ROOT:-$(dirname "$TARGET_DIR")}"
  WORKSPACE_ROOT="$(cd "$WORKSPACE_ROOT" 2>/dev/null && pwd)" || WORKSPACE_ROOT="$(dirname "$TARGET_DIR")"

  if [ -f "$MCP_TEMPLATE" ] || [ "$DRY_RUN" = "true" ]; then
    if [ "$DRY_RUN" = "true" ]; then
      info "[dry-run] Deploy Serena MCP config -> $MCP_DEST (read-only mount $WORKSPACE_ROOT, project $TARGET_DIR)"
    elif [ -f "$MCP_DEST" ]; then
      # Merge the serena server into an existing project .mcp.json (idempotent).
      jq --slurpfile add "$MCP_TEMPLATE" \
        '.mcpServers = ((.mcpServers // {}) + $add[0].mcpServers)' \
        "$MCP_DEST" > "$MCP_DEST.tmp" && mv "$MCP_DEST.tmp" "$MCP_DEST"
      ok "Merged Serena MCP server into existing .mcp.json"
    else
      cp "$MCP_TEMPLATE" "$MCP_DEST"
      ok "Deployed Serena MCP config -> .mcp.json"
    fi
    # Fill in the read-only workspace-root mount, the real project path, and the
    # pinned image tag.
    if [ "$DRY_RUN" != "true" ]; then
      sed -i "s|__WORKSPACE_ROOT__|$WORKSPACE_ROOT|g; s|__PROJECT_DIR__|$TARGET_DIR|g; s|__SERENA_IMAGE__|$SERENA_IMAGE|g" "$MCP_DEST"
    fi
    # Remove the stray copy under .claude/ so there is a single source of truth
    # (the Dockerfile stays under .claude/docker/ for rebuilds).
    run_or_dry rm -f "$MCP_TEMPLATE"

    # Keep agent-local files out of the target repo's history: the .mcp.json
    # itself and Serena's per-project cache (.serena/, written by the container).
    local ignore
    for ignore in '.mcp.json' '.serena/'; do
      if [ -f "$GITIGNORE" ] && grep -qx "$ignore" "$GITIGNORE" 2>/dev/null; then
        ok "$ignore already in .gitignore"
      elif [ "$DRY_RUN" = "true" ]; then
        info "[dry-run] Append '$ignore' to $GITIGNORE"
      else
        echo "$ignore" >> "$GITIGNORE"
        ok "Added $ignore to .gitignore"
      fi
    done

    # Auto-build the pinned Serena image when this version isn't present yet, so
    # the only developer prerequisite is a working Docker install. Reused as-is on
    # later runs; re-triggered automatically when SERENA_IMAGE_VERSION bumps. The
    # image adds Go+gopls and clangd on top of the official image (which already
    # ships Node/TS and rust-analyzer).
    if ! command -v docker >/dev/null 2>&1; then
      warn "Serena runs via Docker, but 'docker' was not found on PATH."
      warn "Install Docker to enable semantic code search — the rest of setup continues."
    elif docker image inspect "$SERENA_IMAGE" >/dev/null 2>&1; then
      ok "Serena Docker image already built: $SERENA_IMAGE"
    elif [ "$DRY_RUN" = "true" ]; then
      info "[dry-run] docker build -t $SERENA_IMAGE -f $SERENA_DOCKERFILE $(dirname "$SERENA_DOCKERFILE")"
    else
      info "Building Serena Docker image $SERENA_IMAGE (one-time per version; first build may take a few minutes)..."
      if docker build -t "$SERENA_IMAGE" -f "$SERENA_DOCKERFILE" "$(dirname "$SERENA_DOCKERFILE")"; then
        ok "Built Serena Docker image: $SERENA_IMAGE"
      else
        warn "Serena image build failed — retry later with:"
        warn "  docker build -t $SERENA_IMAGE -f .claude/docker/Dockerfile.serena .claude/docker"
      fi
    fi

    # Relocate Serena's per-project data OFF the read-only workspace mount.
    # Serena writes each project's .serena/ (project.yml, symbol cache, memories)
    # INSIDE the project by default, which fails under the :ro bind mount. The
    # ONLY supported relocation is the global-config key
    # `project_serena_folder_location` (there is no CLI flag or env var override
    # for it), so we (a) pin SERENA_HOME onto the writable `serena-data` volume in
    # .mcp.json (-e SERENA_HOME=/serena-data) and (b) seed that volume's
    # serena_config.yml to mirror project data under
    # /serena-data/projects$projectDir/.serena — a full-path mirror, so it is
    # collision-free across repos/worktrees that share a basename. Idempotent and
    # host-global (the named volume is shared by every repo on this machine).
    # VERIFY: verifier should confirm end-to-end that activate_project +
    # find_symbol work over a worktree with the :ro mount + this seed (proven in
    # isolation via `serena project index`; confirm through the live MCP path).
    if command -v docker >/dev/null 2>&1 && docker image inspect "$SERENA_IMAGE" >/dev/null 2>&1; then
      if [ "$DRY_RUN" = "true" ]; then
        info "[dry-run] Seed serena-data volume: project_serena_folder_location -> /serena-data/projects\$projectDir/.serena"
      elif docker run --rm -i -e SERENA_HOME=/serena-data -v serena-data:/serena-data "$SERENA_IMAGE" python - <<'PYSEED' >/dev/null 2>&1
import os
from serena.config.serena_config import SerenaConfig
p = SerenaConfig._determine_config_file_path()
if not os.path.exists(p):
    SerenaConfig._generate_config_file(p)
s = open(p).read()
old = 'project_serena_folder_location: "$projectDir/.serena"'
new = 'project_serena_folder_location: "/serena-data/projects$projectDir/.serena"'
if old in s and new not in s:
    open(p, "w").write(s.replace(old, new))
PYSEED
      then
        ok "Relocated Serena project data off the read-only mount (serena-data volume)"
      else
        warn "Could not seed the serena-data volume; a read-only project may fail"
        warn "until project_serena_folder_location is set in /serena-data/serena_config.yml."
      fi
    fi
  fi
}

# --- Parse arguments ---

TARGET_DIR=""
TICKET_STR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --serena-only) SERENA_ONLY=true; shift ;;
    --yes|-y|--non-interactive) ASSUME_YES=true; shift ;;
    --interactive) FORCE_INTERACTIVE=true; shift ;;
    --ticket) TICKET_STR="${2:-}"; shift 2 ;;
    --ticket=*) TICKET_STR="${1#--ticket=}"; shift ;;
    --help|-h)
      echo "Usage: $0 <target-project-dir> [--dry-run] [--yes] [--interactive] [--serena-only] [--ticket '<t>']"
      echo ""
      echo "Deploys Unicity Claude Code configuration to a target project."
      echo "Idempotent: existing identity/nametag/config are PRESERVED unless a new"
      echo "value is explicitly supplied (interactive entry or SETUP_* env override)."
      echo "See the header of this script for the full contract + override list."
      echo ""
      echo "Options:"
      echo "  --dry-run      Print what a real run would do (faithfully — existing"
      echo "                 identity/config preview as KEPT) without executing"
      echo "  --yes          Non-interactive mode (also -y / --non-interactive /"
      echo "                 NONINTERACTIVE=1, and AUTO when stdin is not a TTY):"
      echo "                 no prompts, never destructive — the safe upgrade path"
      echo "  --interactive  Force prompts even when stdin is not a TTY"
      echo "  --ticket '<t>' Redeem a one-time invite ticket after install → single-command"
      echo "                 mutual onboarding (you and the issuer end up mutually authorized)."
      echo "  --serena-only  Re-apply ONLY the Serena MCP config (.mcp.json +"
      echo "                 substitution + gitignore + image/volume setup) and"
      echo "                 exit; skips identity/owner/network/notify/deps/config."
      echo "                 Idempotent; safe to re-run without clobbering an"
      echo "                 existing agent identity."
      echo "  --help         Show this help"
      exit 0
      ;;
    *) TARGET_DIR="$1"; shift ;;
  esac
done

if [ -z "$TARGET_DIR" ]; then
  die "Usage: $0 <target-project-dir> [--dry-run] [--yes] [--serena-only]"
fi

# Resolve to absolute path
TARGET_DIR="$(cd "$TARGET_DIR" 2>/dev/null && pwd)" || die "Target directory does not exist: $TARGET_DIR"
CLAUDE_DIR="$TARGET_DIR/.claude"
GITIGNORE="$TARGET_DIR/.gitignore"

# --- Interactivity resolution (see MODES in the header) ---
# Non-interactive when: explicitly requested (--yes/--non-interactive/
# NONINTERACTIVE=1), or stdin is not a TTY (an AI agent / CI shell) — unless
# --interactive forces prompts. In non-interactive mode nothing is asked and
# nothing existing is overwritten.
if [ "$FORCE_INTERACTIVE" = "true" ]; then
  NONINTERACTIVE=false
elif [ "$ASSUME_YES" = "true" ] || [ ! -t 0 ]; then
  NONINTERACTIVE=true
elif [ "$NONINTERACTIVE_REQ" = "1" ] || [ "$NONINTERACTIVE_REQ" = "true" ] || [ "$NONINTERACTIVE_REQ" = "yes" ]; then
  NONINTERACTIVE=true
else
  NONINTERACTIVE=false
fi

echo ""
echo "============================================"
echo "  Unicity Claude Code Setup"
echo "============================================"
echo ""
info "Target project: $TARGET_DIR"
[ "$DRY_RUN" = "true" ] && warn "DRY RUN mode — no changes will be made"
[ "$NONINTERACTIVE" = "true" ] && info "Non-interactive mode — no prompts; existing values are preserved"
echo ""

# ============================================================
# --serena-only: re-apply just the Serena MCP config, then exit.
# Self-contained — does not depend on any of the skipped phases.
# ============================================================
if [ "$SERENA_ONLY" = "true" ]; then
  info "Serena-only mode: deploying just the Serena MCP configuration..."
  if [ ! -d "$TARGET_DIR/.git" ]; then
    die "Target directory is not a git repository: $TARGET_DIR"
  fi
  # Bring just the .mcp.json template + the Serena Dockerfile into place, without
  # touching any existing agent identity/config already under .claude/.
  run_or_dry mkdir -p "$CLAUDE_DIR/docker"
  run_or_dry cp "$CONF_DIR/.mcp.json" "$CLAUDE_DIR/.mcp.json"
  if [ -f "$CONF_DIR/docker/Dockerfile.serena" ]; then
    run_or_dry cp "$CONF_DIR/docker/Dockerfile.serena" "$CLAUDE_DIR/docker/Dockerfile.serena"
  fi
  # Keep .claude out of the target repo's history (parity with the full flow).
  if [ -f "$GITIGNORE" ] && grep -qx '.claude' "$GITIGNORE" 2>/dev/null; then
    ok ".claude already in .gitignore"
  elif [ "$DRY_RUN" = "true" ]; then
    info "[dry-run] Append '.claude' to $GITIGNORE"
  else
    echo '.claude' >> "$GITIGNORE"
    ok "Added .claude to .gitignore"
  fi
  deploy_serena_mcp
  ok "Serena-only deployment complete."
  exit 0
fi

# ============================================================
# Phase 0: Load EXISTING configuration (the preserve-by-default source)
# ============================================================
# Everything read here becomes the default for the corresponding value below:
# in non-interactive mode it is used as-is; in interactive mode it is the
# prompt default (Enter keeps it). Only an explicit new input replaces it.
EX_AGENT_NAMETAG=""
EX_OWNER_NAMETAG=""
EX_OWNER_NPUB=""
EX_NETWORK=""
EX_RELAY=""
EX_RELAYS_JSON="[]"
EX_NOTIFY=""
EX_GROUP_ID=""
EX_GROUP_NAME=""
EX_HAS_DEP_CONFIG=false
EX_DEP_ENABLED=false
EX_DEPS_JSON="[]"

EXISTING_CONFIG_FILE="$CLAUDE_DIR/agent/config.json"
EXISTING_IDENTITY_FILE="$CLAUDE_DIR/agent/identity.json"

if [ -f "$EXISTING_CONFIG_FILE" ] && jq -e 'type == "object"' "$EXISTING_CONFIG_FILE" >/dev/null 2>&1; then
  EX_AGENT_NAMETAG=$(jq -r '.agent_nametag // ""' "$EXISTING_CONFIG_FILE")
  EX_OWNER_NAMETAG=$(jq -r '.owner_nametag // ""' "$EXISTING_CONFIG_FILE")
  EX_OWNER_NPUB=$(jq -r '.owner_npub // ""' "$EXISTING_CONFIG_FILE")
  EX_NETWORK=$(jq -r '.network // ""' "$EXISTING_CONFIG_FILE")
  # Full relay ARRAY (preserved verbatim when the relay is unchanged) + its
  # first entry (the prompt default / comparison value).
  EX_RELAYS_JSON=$(jq -c '.group.relays // [] | if type == "array" then . else [] end' "$EXISTING_CONFIG_FILE")
  EX_RELAY=$(jq -r '.group.relays // [] | if type == "array" then (.[0] // "") else "" end' "$EXISTING_CONFIG_FILE")
  EX_NOTIFY=$(jq -r '.notification_url // ""' "$EXISTING_CONFIG_FILE")
  EX_GROUP_ID=$(jq -r '.group.id // ""' "$EXISTING_CONFIG_FILE")
  EX_GROUP_NAME=$(jq -r '.group.name // ""' "$EXISTING_CONFIG_FILE")
  if jq -e '.dep_tracking' "$EXISTING_CONFIG_FILE" >/dev/null 2>&1; then
    EX_HAS_DEP_CONFIG=true
    EX_DEP_ENABLED=$(jq -r '.dep_tracking.enabled // false' "$EXISTING_CONFIG_FILE")
    # Normalize to a strict boolean (it is passed to jq --argjson later).
    [ "$EX_DEP_ENABLED" = "true" ] || EX_DEP_ENABLED=false
    EX_DEPS_JSON=$(jq -c '.dep_tracking.selected_deps // []' "$EXISTING_CONFIG_FILE")
  fi
  info "Existing agent config found — its values are the defaults (re-run preserves them)"
fi
# The nametag stored in identity.json wins over config.json (it is the one the
# transport actually announces).
if [ -f "$EXISTING_IDENTITY_FILE" ]; then
  _ex_id_tag=$(jq -r '.nametag // ""' "$EXISTING_IDENTITY_FILE" 2>/dev/null || echo "")
  [ -n "$_ex_id_tag" ] && EX_AGENT_NAMETAG="$_ex_id_tag"
fi

# ============================================================
# Phase 1: File deployment
# ============================================================
info "Phase 1: Deploying configuration files..."

# Validate target is a git repo
if [ ! -d "$TARGET_DIR/.git" ]; then
  die "Target directory is not a git repository: $TARGET_DIR"
fi

# Copy claude_conf/ → <target>/.claude/. This refreshes FRAMEWORK-OWNED files
# only (hooks, skills, settings.json, CLAUDE.md — see header): claude_conf/
# contains no identity.json/config.json/daemon.json/agent-registry.json, so
# agent state under .claude/agent/ is never touched by this copy.
if [ -d "$CLAUDE_DIR" ]; then
  if [ "$NONINTERACTIVE" = "true" ]; then
    info "Existing .claude/ found — refreshing framework files (agent identity/config preserved)"
  elif ! prompt_yn "  .claude/ already exists in target. Refresh framework files? (agent identity/config are preserved)"; then
    die "Aborted."
  fi
fi

# Two framework files accumulate LOCAL state at runtime that must survive the
# refresh copy: settings.local.json (Claude Code appends the user's permission
# approvals there) and settings.json (operators sometimes add env keys).
# Snapshot them before the copy; local state is merged back right after
# (template wins on conflicts; user-added entries are preserved).
OLD_SETTINGS_JSON=""
OLD_SETTINGS_LOCAL=""
if [ -f "$CLAUDE_DIR/settings.json" ] && jq -e 'type == "object"' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
  OLD_SETTINGS_JSON=$(cat "$CLAUDE_DIR/settings.json")
fi
if [ -f "$CLAUDE_DIR/settings.local.json" ] && jq -e 'type == "object"' "$CLAUDE_DIR/settings.local.json" >/dev/null 2>&1; then
  OLD_SETTINGS_LOCAL=$(cat "$CLAUDE_DIR/settings.local.json")
fi

run_or_dry cp -r "$CONF_DIR/." "$CLAUDE_DIR/"
ok "Copied claude_conf/ → .claude/"

if [ "$DRY_RUN" = "true" ]; then
  [ -n "$OLD_SETTINGS_JSON" ]  && info "[dry-run] Merge user env keys back into settings.json after copy"
  [ -n "$OLD_SETTINGS_LOCAL" ] && info "[dry-run] Merge existing settings.local.json (permission approvals) back after copy"
else
  # NOTE on failure handling: `jq ... > tmp && mv` would NOT abort under set -e
  # (the left side of && is errexit-exempt), silently leaving the template in
  # place — the user's settings clobbered with a green "preserved" message. So
  # both merges check jq's exit EXPLICITLY and, on failure, RESTORE the
  # pre-copy snapshot (losing at worst this run's template refresh of that one
  # file, never the user's data). Inputs are also type-coerced so a hand-edited
  # scalar (e.g. "deny": "Bash(rm:*)") cannot make the merge throw.
  if [ -n "$OLD_SETTINGS_JSON" ] && [ -f "$CLAUDE_DIR/settings.json" ]; then
    # Keep user-added env keys; the template's own env keys win on conflict.
    if jq --argjson old "$OLD_SETTINGS_JSON" '
         def obj(f): f | if type == "object" then . else {} end;
         .env = (obj($old.env) * obj(.env))
       ' "$CLAUDE_DIR/settings.json" > "$CLAUDE_DIR/settings.json.tmp" 2>/dev/null; then
      mv "$CLAUDE_DIR/settings.json.tmp" "$CLAUDE_DIR/settings.json"
      ok "Preserved user env keys in settings.json"
    else
      rm -f "$CLAUDE_DIR/settings.json.tmp"
      printf '%s\n' "$OLD_SETTINGS_JSON" > "$CLAUDE_DIR/settings.json"
      warn "settings.json env merge FAILED — restored your previous settings.json unchanged"
      warn "  (this run's template refresh was NOT applied to settings.json; inspect it and re-run)"
    fi
  fi
  if [ -n "$OLD_SETTINGS_LOCAL" ] && [ -f "$CLAUDE_DIR/settings.local.json" ]; then
    # Deep-merge (existing values win for scalars) + UNION the permission and
    # MCP-server arrays, so approvals the user accumulated are never lost.
    if jq --argjson old "$OLD_SETTINGS_LOCAL" '
         def arr(f): f | if type == "array" then . else [] end;
         def obj(f): f | if type == "object" then . else {} end;
         . as $tpl
         | ($tpl * $old)
         | .permissions = ((obj($tpl.permissions) * obj($old.permissions))
             | reduce ("allow", "deny", "ask") as $k (.;
                 if ((arr(obj($tpl.permissions)[$k]) + arr(obj($old.permissions)[$k])) | length) > 0
                 then .[$k] = ((arr(obj($tpl.permissions)[$k]) + arr(obj($old.permissions)[$k])) | unique)
                 else . end))
         | (if .permissions == {} then del(.permissions) else . end)
         | (if ((arr($tpl.enabledMcpjsonServers) + arr($old.enabledMcpjsonServers)) | length) > 0
            then .enabledMcpjsonServers = ((arr($tpl.enabledMcpjsonServers) + arr($old.enabledMcpjsonServers)) | unique)
            else . end)
       ' "$CLAUDE_DIR/settings.local.json" > "$CLAUDE_DIR/settings.local.json.tmp" 2>/dev/null; then
      mv "$CLAUDE_DIR/settings.local.json.tmp" "$CLAUDE_DIR/settings.local.json"
      ok "Merged settings.local.json (existing permission approvals preserved)"
    else
      rm -f "$CLAUDE_DIR/settings.local.json.tmp"
      printf '%s\n' "$OLD_SETTINGS_LOCAL" > "$CLAUDE_DIR/settings.local.json"
      warn "settings.local.json merge FAILED — restored your previous settings.local.json unchanged"
      warn "  (this run's template refresh was NOT applied to it; inspect the file and re-run)"
    fi
  fi
fi

# Ensure hook scripts are executable after deployment. cp -r preserves source
# modes, but make the +x bit explicit so the harness can always invoke them
# (and so a checkout that lost the bit doesn't silently break the hooks).
if [ -d "$CLAUDE_DIR/hooks" ]; then
  run_or_dry chmod +x "$CLAUDE_DIR/hooks"/*.sh
  ok "Made hook scripts executable"
fi

# Append .claude to .gitignore
if [ -f "$GITIGNORE" ] && grep -qx '.claude' "$GITIGNORE" 2>/dev/null; then
  ok ".claude already in .gitignore"
else
  if [ "$DRY_RUN" = "true" ]; then
    info "[dry-run] Append '.claude' to $GITIGNORE"
  else
    echo '.claude' >> "$GITIGNORE"
  fi
  ok "Added .claude to .gitignore"
fi

# --- MCP: Serena semantic code search (Dockerized) ---
# Broad, read-only, identity-mounted workspace root so Serena sees every
# branch/worktree/repo/folder under it; project data is relocated onto a
# writable volume (see deploy_serena_mcp).
deploy_serena_mcp

# Create agent directory
run_or_dry mkdir -p "$CLAUDE_DIR/agent"
ok "Created .claude/agent/"

# ============================================================
# Phase 2: Identity setup
# ============================================================
echo ""
info "Phase 2: Identity setup..."

IDENTITY_FILE="$CLAUDE_DIR/agent/identity.json"

# NOTE: this guard runs in --dry-run too, so a dry run previews the REAL
# behavior (an existing identity is KEPT, not replaced).
if [ -f "$IDENTITY_FILE" ]; then
  EXISTING_NPUB=$(jq -r '.npub // "unknown"' "$IDENTITY_FILE" 2>/dev/null)
  info "Existing identity found: $EXISTING_NPUB"
  # GUARD: this identity is the agent's keypair + EVERY peer authorization. Overwriting it
  # silently — a non-interactive shell taking a default, or a careless Enter on a [Y/n]
  # prompt — would DESTROY them. So: default to KEEP, refuse to overwrite in
  # non-interactive mode, and require an explicit affirmative (or FORCE_NEW_IDENTITY=1)
  # to regenerate.
  if [ "${FORCE_NEW_IDENTITY:-}" = "1" ]; then
    warn "FORCE_NEW_IDENTITY=1 — regenerating (existing identity + all peer authorizations will be DESTROYED)"
    IDENTITY_CREATED=true
  elif [ "$NONINTERACTIVE" = "true" ]; then
    ok "Keeping existing identity (non-interactive — refusing to overwrite; set FORCE_NEW_IDENTITY=1 to override)"
    IDENTITY_CREATED=false
  elif prompt_yn "  Overwrite it with a NEW identity? This DESTROYS the current keypair + all peer authorizations" "n"; then
    IDENTITY_CREATED=true
  else
    ok "Keeping existing identity"
    IDENTITY_CREATED=false
  fi
else
  IDENTITY_CREATED=true
fi

SPHERE_SDK_AVAILABLE=true

# Agent nametag — existing value (identity.json wins) is the default and is
# kept unless explicitly changed (prompt entry or SETUP_AGENT_NAMETAG).
AGENT_NAMETAG=$(resolve_value SETUP_AGENT_NAMETAG "$EX_AGENT_NAMETAG" \
  "claude-$(basename "$TARGET_DIR")" \
  "Agent nametag for this instance (e.g., claude-otc-bot, claude-sphere)")
AGENT_NAMETAG="${AGENT_NAMETAG#@}"  # strip leading @ if present
ok "Agent nametag: $AGENT_NAMETAG"

if [ "$IDENTITY_CREATED" = "true" ]; then
  if prompt_yn "Create a new Unicity ID for this Claude instance?"; then
    if ensure_sphere_sdk; then
      info "Generating identity (BIP-39 mnemonic + secp256k1 keypair)..."
      IDENTITY_JSON=$(run_sphere_helper create-identity)

      if [ "$DRY_RUN" != "true" ]; then
        echo "$IDENTITY_JSON" > "$IDENTITY_FILE"
        chmod 600 "$IDENTITY_FILE"
      fi

      AGENT_NPUB=$(echo "$IDENTITY_JSON" | jq -r '.npub // "unknown"')
      ok "Identity created: $AGENT_NPUB"

      # Show mnemonic once
      if [ "$DRY_RUN" != "true" ]; then
        echo ""
        warn "=== BACKUP YOUR MNEMONIC (shown once) ==="
        echo "$IDENTITY_JSON" | jq -r '.mnemonic'
        warn "==========================================="
        echo ""
      fi
    elif [ "$NONINTERACTIVE" = "true" ]; then
      # No sdk and no prompts allowed: do NOT write a placeholder identity.
      warn "sphere-sdk not available — cannot mint an identity non-interactively."
      warn "  Run: (cd \"$SCRIPT_DIR\" && npm install)  then re-run setup.sh"
      AGENT_NPUB="(none)"
    else
      warn "sphere-sdk not available — falling back to manual import."
      IMPORT_NPUB=$(prompt_input "Enter existing npub")
      IMPORT_NSEC=$(prompt_input "Enter existing nsec")
      AGENT_NPUB="$IMPORT_NPUB"

      if [ -z "$IMPORT_NPUB" ]; then
        warn "No npub provided — skipping identity import (no identity file written)."
        AGENT_NPUB="(none)"
      elif [ "$DRY_RUN" != "true" ]; then
        jq -n \
          --arg npub "$IMPORT_NPUB" \
          --arg nsec "$IMPORT_NSEC" \
          --arg created_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
          '{
            created_at: $created_at,
            mnemonic: "(imported)",
            public_key: "(derived from npub)",
            npub: $npub,
            nsec: $nsec,
            derivation_path: "m/44\u0027/0\u0027/0\u0027/0/0"
          }' > "$IDENTITY_FILE"
        chmod 600 "$IDENTITY_FILE"
      fi
      [ "$AGENT_NPUB" != "(none)" ] && ok "Imported identity: $AGENT_NPUB"
    fi
  else
    # Import existing identity (interactive only — non-interactive mode always
    # takes the create path above and only when NO identity exists).
    IMPORT_NPUB=$(prompt_input "Enter existing npub")
    IMPORT_NSEC=$(prompt_input "Enter existing nsec")
    AGENT_NPUB="$IMPORT_NPUB"

    if [ -z "$IMPORT_NPUB" ]; then
      warn "No npub provided — skipping identity import (no identity file written)."
      AGENT_NPUB="(none)"
    elif [ "$DRY_RUN" != "true" ]; then
      jq -n \
        --arg npub "$IMPORT_NPUB" \
        --arg nsec "$IMPORT_NSEC" \
        --arg created_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
          created_at: $created_at,
          mnemonic: "(imported)",
          public_key: "(derived from npub)",
          npub: $npub,
          nsec: $nsec,
          derivation_path: "m/44\u0027/0\u0027/0\u0027/0/0"
        }' > "$IDENTITY_FILE"
      chmod 600 "$IDENTITY_FILE"
    fi
    [ "$AGENT_NPUB" != "(none)" ] && ok "Imported identity: $AGENT_NPUB"
  fi
else
  AGENT_NPUB=$(jq -r '.npub // "unknown"' "$IDENTITY_FILE" 2>/dev/null)
fi

# Store nametag in identity file (after it's been created/imported above).
# Only rewritten when the value actually changed, so a preserving re-run
# leaves identity.json byte-for-byte untouched.
if [ -f "$IDENTITY_FILE" ]; then
  CUR_ID_NAMETAG=$(jq -r '.nametag // ""' "$IDENTITY_FILE" 2>/dev/null || echo "")
  if [ "$CUR_ID_NAMETAG" != "$AGENT_NAMETAG" ]; then
    if [ "$DRY_RUN" = "true" ]; then
      info "[dry-run] Stamp nametag '$AGENT_NAMETAG' into identity.json"
    else
      if jq --arg nametag "$AGENT_NAMETAG" '.nametag = $nametag' "$IDENTITY_FILE" > "$IDENTITY_FILE.tmp" 2>/dev/null; then
        mv "$IDENTITY_FILE.tmp" "$IDENTITY_FILE"
        chmod 600 "$IDENTITY_FILE"
      else
        rm -f "$IDENTITY_FILE.tmp"
        warn "Could not stamp nametag into identity.json — file left untouched"
      fi
    fi
  fi
fi

# ============================================================
# Phase 3: Owner configuration
# ============================================================
echo ""
info "Phase 3: Owner configuration..."

OWNER_NAMETAG=$(resolve_value SETUP_OWNER_NAMETAG "$EX_OWNER_NAMETAG" "" \
  "Enter the owner's nametag (e.g., babaika10)")
OWNER_NAMETAG="${OWNER_NAMETAG#@}"  # strip leading @ if present

OWNER_NPUB=$(resolve_value SETUP_OWNER_NPUB "$EX_OWNER_NPUB" "" \
  "Enter the owner's npub (leave empty if unknown)")

if [ -z "$OWNER_NPUB" ] && [ -n "$OWNER_NAMETAG" ]; then
  info "Owner npub not set — nametag '$OWNER_NAMETAG' will be resolved at runtime by the agent."
fi

ok "Owner: ${OWNER_NAMETAG:-(not set)}${OWNER_NPUB:+ ($OWNER_NPUB)}"

# ============================================================
# Phase 3b: Coordinator (optional) — pre-record its nametag → npub
# ============================================================
# If this instance is a TEAMMATE joining a coordination circle, pre-recording the
# coordinator's Unicity nametag lets you address it by name from the first boot
# (e.g. `/consult-coordinator concierge-coord …`), resolving to its npub locally via
# the agent-registry cache instead of a network lookup. Entirely optional and
# backward compatible: leave the nametag empty to skip. A previously-recorded
# coordinator lives in agent-registry.json and is PRESERVED whenever this step
# is skipped — the registry is only upserted when a nametag is explicitly given.
if [ -n "${SETUP_COORD_NAMETAG+x}" ]; then
  COORD_NAMETAG="$SETUP_COORD_NAMETAG"
elif [ "$NONINTERACTIVE" = "true" ]; then
  COORD_NAMETAG=""   # skip silently — existing registry records stay intact
else
  COORD_NAMETAG=$(prompt_input "Coordinator nametag to pre-record (empty to skip; existing records are kept)" "")
fi
COORD_NAMETAG="${COORD_NAMETAG#@}"  # strip leading @ if present
COORD_NPUB=""
if [ -n "$COORD_NAMETAG" ]; then
  if [ -n "${SETUP_COORD_NPUB+x}" ]; then
    COORD_NPUB="$SETUP_COORD_NPUB"
  elif [ "$NONINTERACTIVE" != "true" ]; then
    COORD_NPUB=$(prompt_input "Coordinator npub (leave empty to resolve '$COORD_NAMETAG' now)" "")
  fi
  REGISTRY_SH="$CLAUDE_DIR/hooks/agent-registry.sh"
  HELPER_MJS="$SCRIPT_DIR/lib/sphere-helper.mjs"
  if [ "$DRY_RUN" = "true" ]; then
    info "[dry-run] Pre-record coordinator '$COORD_NAMETAG'${COORD_NPUB:+ ($COORD_NPUB)} in agent registry"
  else
    # No npub given → resolve the nametag on the network (best-effort).
    if [ -z "$COORD_NPUB" ] && [ -f "$HELPER_MJS" ] && command -v node >/dev/null 2>&1; then
      COORD_NPUB=$(node "$HELPER_MJS" resolve-nametag "$COORD_NAMETAG" 2>/dev/null | jq -r '.npub // ""' 2>/dev/null || echo "")
    fi
    if [ -z "$COORD_NPUB" ]; then
      # Nametag given but no npub (none supplied and network-resolve came up empty). Say so
      # explicitly rather than calling upsert-peer with an empty --npub (which recorded nothing).
      warn "Coordinator '$COORD_NAMETAG' could not be resolved to an npub now (no npub given and network lookup failed)."
      warn "  The agent will resolve '$COORD_NAMETAG' at runtime, OR re-run and supply its npub to pre-record it."
    elif [ -f "$REGISTRY_SH" ]; then
      bash "$REGISTRY_SH" ensure >/dev/null 2>&1 || true
      bash "$REGISTRY_SH" upsert-peer --npub "$COORD_NPUB" --name "$COORD_NAMETAG" >/dev/null 2>&1 || true
      # VERIFY the record actually landed (the pre-record used to silently no-op) — query by
      # npub and confirm a non-empty pubkey came back before claiming success.
      COORD_REC="$(bash "$REGISTRY_SH" get "$COORD_NPUB" 2>/dev/null || echo '')"
      if [ -n "$COORD_REC" ] && [ -n "$(printf '%s' "$COORD_REC" | jq -r '.pubkey // ""' 2>/dev/null)" ]; then
        ok "Pre-recorded coordinator: $COORD_NAMETAG → $COORD_NPUB (registry entry verified)"
      else
        warn "Pre-record of coordinator '$COORD_NAMETAG' did NOT land in the registry — 'authorize/consult $COORD_NAMETAG' by name will fail until it does."
        warn "  Fix: bash '$REGISTRY_SH' upsert-peer --npub '$COORD_NPUB' --name '$COORD_NAMETAG'   (then re-run 'get $COORD_NPUB' to confirm)"
      fi
    else
      warn "Registry hook not found at '$REGISTRY_SH' — cannot pre-record coordinator '$COORD_NAMETAG'."
    fi
  fi
fi

# ============================================================
# Phase 4: Network environment
# ============================================================
echo ""
info "Phase 4: Network environment..."

if [ -n "${SETUP_NETWORK+x}" ]; then
  NETWORK="$SETUP_NETWORK"
  info "Network (from SETUP_NETWORK): $NETWORK"
elif [ "$NONINTERACTIVE" = "true" ]; then
  NETWORK="${EX_NETWORK:-testnet}"
else
  echo "  1) testnet (default)"
  echo "  2) mainnet"
  echo "  3) devnet (localhost)"
  NETWORK=$(prompt_input "Network environment" "${EX_NETWORK:-testnet}")
fi

# Canonicalize the network name and derive its DEFAULT relay. An unrecognized
# value that matches the EXISTING network is preserved verbatim (a hand-edited
# custom network must survive a re-run) instead of being reset to testnet.
case "$NETWORK" in
  1|testnet)
    NETWORK="testnet"
    MAPPED_RELAY="wss://nostr-relay.testnet.unicity.network"
    ;;
  2|mainnet)
    NETWORK="mainnet"
    MAPPED_RELAY="wss://relay.unicity.network"
    ;;
  3|devnet)
    NETWORK="devnet"
    MAPPED_RELAY="ws://localhost:7777"
    ;;
  *)
    if [ -n "$EX_NETWORK" ] && [ "$NETWORK" = "$EX_NETWORK" ]; then
      MAPPED_RELAY="${EX_RELAY:-wss://nostr-relay.testnet.unicity.network}"
    else
      warn "Unknown network '$NETWORK', defaulting to testnet"
      NETWORK="testnet"
      MAPPED_RELAY="wss://nostr-relay.testnet.unicity.network"
    fi
    ;;
esac

# Relay choice: explicit override > existing relay(s) preserved verbatim when
# the network is unchanged (also when the existing config has relays but no
# recorded network at all) > the network's default relay. RELAYS_PRESERVED
# carries the FULL existing relay array into config.json (never truncated).
RELAYS_PRESERVED=false
if [ -n "${SETUP_RELAY_URL+x}" ] && [ -n "$SETUP_RELAY_URL" ]; then
  RELAY_URL="$SETUP_RELAY_URL"
  info "Relay (from SETUP_RELAY_URL): $RELAY_URL"
elif [ -n "$EX_RELAY" ] && [ "$NETWORK" = "${EX_NETWORK:-$NETWORK}" ]; then
  RELAY_URL="$EX_RELAY"
  RELAYS_PRESERVED=true
else
  RELAY_URL="$MAPPED_RELAY"
fi

ok "Network: $NETWORK ($RELAY_URL)"

# ============================================================
# Phase 5: Notification URL
# ============================================================
echo ""
info "Phase 5: Notification configuration..."

NOTIFY_URL=$(resolve_value SETUP_NOTIFY_URL "$EX_NOTIFY" "" \
  "Mobile notification URL (ntfy.sh/<topic>, leave empty to skip)")

if [ -n "$NOTIFY_URL" ]; then
  # Normalize ntfy.sh shorthand
  if [[ "$NOTIFY_URL" == ntfy.sh/* ]]; then
    NOTIFY_URL="https://$NOTIFY_URL"
  fi
  ok "Notifications: $NOTIFY_URL"
else
  ok "Notifications: disabled (desktop only)"
fi

# ============================================================
# Phase 6: Dependency tracking
# ============================================================
echo ""
info "Phase 6: Dependency tracking..."

# Auto-detect repo from target basename
REPO_BASENAME=$(basename "$TARGET_DIR")
SELECTED_DEPS=()
DEPS_PRESERVED=false

# Read available deps from dep-map.json
DEP_MAP_FILE="$CONF_DIR/hooks/dep-map.json"
declare -a DEP_LIST=()
if [ -f "$DEP_MAP_FILE" ]; then
  REPO_DEPS=$(jq -r --arg repo "$REPO_BASENAME" '.repos[$repo].deps // [] | .[].name' "$DEP_MAP_FILE" 2>/dev/null)
  if [ -n "$REPO_DEPS" ]; then
    while IFS= read -r dep; do
      DEP_LIST+=("$dep")
    done <<< "$REPO_DEPS"
  fi
fi

if [ -n "${SETUP_DEPS+x}" ]; then
  # Explicit override: all | none | comma-separated dependency names.
  case "$SETUP_DEPS" in
    all)     SELECTED_DEPS=("${DEP_LIST[@]}") ;;
    none|"") SELECTED_DEPS=() ;;
    *)
      IFS=',' read -ra _dep_names <<< "$SETUP_DEPS"
      for _d in "${_dep_names[@]}"; do
        _d=$(echo "$_d" | tr -d ' ')
        [ -n "$_d" ] && SELECTED_DEPS+=("$_d")
      done
      ;;
  esac
  info "Dependency tracking (from SETUP_DEPS): ${SELECTED_DEPS[*]:-none}"
elif [ "$EX_HAS_DEP_CONFIG" = "true" ]; then
  # Preserve the existing dep-tracking config verbatim (enabled flag + list).
  DEPS_PRESERVED=true
  while IFS= read -r dep; do
    [ -n "$dep" ] && SELECTED_DEPS+=("$dep")
  done < <(jq -r '.[]?' <<< "$EX_DEPS_JSON")
  ok "Dependency tracking preserved: ${SELECTED_DEPS[*]:-none} (set SETUP_DEPS=all|none|a,b to change)"
elif [ "$NONINTERACTIVE" = "true" ]; then
  # Fresh install without prompts: track all detected upstream deps (same as
  # the interactive default).
  SELECTED_DEPS=("${DEP_LIST[@]}")
elif [ ${#DEP_LIST[@]} -gt 0 ]; then
  info "Detected repo: $REPO_BASENAME"
  info "Available upstream dependencies:"
  i=1
  for dep in "${DEP_LIST[@]}"; do
    CHECK_TYPE=$(jq -r --arg repo "$REPO_BASENAME" --arg dep "$dep" \
      '.repos[$repo].deps[] | select(.name == $dep) | .check' "$DEP_MAP_FILE" 2>/dev/null)
    printf '  [%d] %s (%s)\n' "$i" "$dep" "$CHECK_TYPE"
    i=$((i + 1))
  done

  DEP_SELECTION=$(prompt_input "Select deps to track (comma-separated numbers, 'all' for all, 'none' to skip)" "all")
  if [ "$DEP_SELECTION" = "all" ]; then
    SELECTED_DEPS=("${DEP_LIST[@]}")
  elif [ "$DEP_SELECTION" != "none" ]; then
    IFS=',' read -ra NUMS <<< "$DEP_SELECTION"
    for num in "${NUMS[@]}"; do
      num=$(echo "$num" | tr -d ' ')
      idx=$((num - 1))
      if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#DEP_LIST[@]}" ]; then
        SELECTED_DEPS+=("${DEP_LIST[$idx]}")
      fi
    done
  fi
else
  if [ ! -f "$DEP_MAP_FILE" ]; then
    warn "dep-map.json not found, skipping dependency configuration"
  else
    info "Repo '$REPO_BASENAME' not found in dep-map.json"
    if prompt_yn "  Add custom dependency tracking?" "n"; then
      CUSTOM_DEP=$(prompt_input "Dependency name (e.g., sphere-sdk)")
      if [ -n "$CUSTOM_DEP" ]; then
        SELECTED_DEPS+=("$CUSTOM_DEP")
      fi
    fi
  fi
fi

if [ "$DEPS_PRESERVED" = "true" ]; then
  DEP_TRACKING_ENABLED="$EX_DEP_ENABLED"
elif [ ${#SELECTED_DEPS[@]} -gt 0 ]; then
  ok "Tracking: ${SELECTED_DEPS[*]}"
  DEP_TRACKING_ENABLED=true
else
  ok "Dependency tracking: disabled"
  DEP_TRACKING_ENABLED=false
fi

# ============================================================
# Phase 7: Group setup
# ============================================================
echo ""
info "Phase 7: UNICITY_DEV_AGENTS group setup..."

GROUP_NAME="${EX_GROUP_NAME:-UNICITY_DEV_AGENTS}"
GROUP_ID=""

# A real (non-placeholder) group id from a previous run is preserved as-is —
# no network call. Placeholder ids (unicity-dev-agents-<network>) mean the
# original join never succeeded, so those are retried.
if [ -n "$EX_GROUP_ID" ] && [[ "$EX_GROUP_ID" != unicity-dev-agents-* ]]; then
  GROUP_ID="$EX_GROUP_ID"
  ok "Group preserved: $GROUP_NAME ($GROUP_ID)"
else
  if [ "$SPHERE_SDK_AVAILABLE" = "true" ]; then
    info "Joining $GROUP_NAME on $RELAY_URL..."

    GROUP_RESULT=$(run_sphere_helper join-group "$GROUP_NAME" \
      --identity "$IDENTITY_FILE" \
      --relay "$RELAY_URL" 2>/dev/null || echo '{"error": "join failed"}')

    GROUP_ID=$(echo "$GROUP_RESULT" | jq -r '.group_id // .id // ""' 2>/dev/null)
  fi

  if [ -z "$GROUP_ID" ] || [ "$GROUP_ID" = "null" ]; then
    warn "Could not join/create group (sphere-sdk required). Using placeholder."
    GROUP_ID="unicity-dev-agents-${NETWORK}"
  fi

  ok "Group: $GROUP_NAME ($GROUP_ID)"
fi

# ============================================================
# Phase 8: Write configuration files
# ============================================================
echo ""
info "Phase 8: Writing configuration files..."

# Build selected_deps JSON array
if [ "$DEPS_PRESERVED" = "true" ]; then
  DEPS_JSON="$EX_DEPS_JSON"
else
  DEPS_JSON="[]"
  if [ ${#SELECTED_DEPS[@]} -gt 0 ]; then
    DEPS_JSON=$(printf '%s\n' "${SELECTED_DEPS[@]}" | jq -R . | jq -s .)
  fi
fi

# --- agent/config.json ---
# DEEP-MERGED onto the existing file (never rebuilt from scratch), so any
# extra/unknown keys another tool added survive a re-run. All values below
# already follow the preserve-by-default resolution, so an untouched re-run
# writes back exactly what was there. transport.helper_path is framework-owned
# and deliberately re-pointed at this clone on every run.
CONFIG_FILE="$CLAUDE_DIR/agent/config.json"
# Relays written to config: the FULL existing array when preserved (a
# multi-relay config must never be truncated to one entry by a re-run),
# else the single resolved relay.
if [ "$RELAYS_PRESERVED" = "true" ] && [ "$EX_RELAYS_JSON" != "[]" ]; then
  CONFIG_RELAYS_JSON="$EX_RELAYS_JSON"
else
  CONFIG_RELAYS_JSON=$(jq -cn --arg r "$RELAY_URL" '[$r]')
fi
NEW_CONFIG=$(jq -n \
  --arg agent_nametag "$AGENT_NAMETAG" \
  --arg owner_npub "$OWNER_NPUB" \
  --arg owner_nametag "$OWNER_NAMETAG" \
  --arg notification_url "$NOTIFY_URL" \
  --arg group_name "$GROUP_NAME" \
  --arg group_id "$GROUP_ID" \
  --argjson relays "$CONFIG_RELAYS_JSON" \
  --arg network "$NETWORK" \
  --arg helper_path "$SCRIPT_DIR/lib/sphere-helper.mjs" \
  --argjson dep_enabled "$DEP_TRACKING_ENABLED" \
  --argjson selected_deps "$DEPS_JSON" \
  '{
    agent_nametag: $agent_nametag,
    owner_npub: $owner_npub,
    owner_nametag: $owner_nametag,
    notification_url: $notification_url,
    network: $network,
    group: {
      name: $group_name,
      id: $group_id,
      relays: $relays
    },
    transport: {
      helper_path: $helper_path
    },
    dep_tracking: {
      enabled: $dep_enabled,
      selected_deps: $selected_deps
    }
  }')
if [ "$DRY_RUN" = "true" ]; then
  if [ -f "$CONFIG_FILE" ]; then
    info "[dry-run] Deep-merge resolved values into existing $CONFIG_FILE (extra keys preserved)"
  else
    info "[dry-run] Write $CONFIG_FILE"
  fi
else
  if [ -f "$CONFIG_FILE" ] && jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null 2>&1; then
    # Explicit exit check: a failed merge must be LOUD, never a silent skip
    # that leaves the ok-line lying (jq on the left of && is set -e exempt).
    if jq --argjson new "$NEW_CONFIG" '. * $new' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null; then
      mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    else
      rm -f "$CONFIG_FILE.tmp"
      die "config.json merge failed — existing file left untouched at $CONFIG_FILE"
    fi
  else
    [ -f "$CONFIG_FILE" ] && warn "Existing config.json was not a JSON object — rewriting it"
    printf '%s\n' "$NEW_CONFIG" > "$CONFIG_FILE"
  fi
fi
ok "Wrote agent/config.json"

# Record the transport helper path as an env var too (mirrors the CLAUDE_NOTIFY_URL write
# below), so the hooks resolve it even if config.json is read before jq is available. The
# helper MUST stay under the clone ($SCRIPT_DIR) — it loads @unicitylabs/sphere-sdk from the
# clone's node_modules; copying it into .claude/ would find the file but break the sdk import.

# --- agent/daemon.json ---
# UNION-merged with the existing file: hand-added relays, extra dm contacts and
# extra group subscriptions are kept; hook paths are framework-owned (refreshed).
DAEMON_FILE="$CLAUDE_DIR/agent/daemon.json"
NEW_DAEMON=$(jq -n \
  --arg relay "$RELAY_URL" \
  --arg group_id "$GROUP_ID" \
  --arg group_name "$GROUP_NAME" \
  --arg owner_npub "$OWNER_NPUB" \
  '{
    relays: [$relay],
    subscriptions: {
      groups: [{id: $group_id, name: $group_name}],
      dm_contacts: ([$owner_npub] | map(select(. != "")))
    },
    hooks: {
      on_dm: ".claude/hooks/on-dm.sh",
      on_group_message: ".claude/hooks/on-group-message.sh"
    }
  }')
if [ "$DRY_RUN" = "true" ]; then
  if [ -f "$DAEMON_FILE" ]; then
    info "[dry-run] Union-merge relays/subscriptions into existing $DAEMON_FILE"
  else
    info "[dry-run] Write $DAEMON_FILE"
  fi
else
  if [ -f "$DAEMON_FILE" ] && jq -e 'type == "object"' "$DAEMON_FILE" >/dev/null 2>&1; then
    if jq --argjson new "$NEW_DAEMON" '
         def arr(f): f | if type == "array" then . else [] end;
         def obj(f): f | if type == "object" then . else {} end;
         .relays = ((arr(.relays) + $new.relays) | unique)
         | .subscriptions = (obj(.subscriptions)
             | .groups = ((arr(.groups) + $new.subscriptions.groups)
                          | map(select(type == "object")) | unique_by(.id))
             | .dm_contacts = ((arr(.dm_contacts) + $new.subscriptions.dm_contacts)
                               | map(select(. != "")) | unique))
         | .hooks = (obj(.hooks) * $new.hooks)
       ' "$DAEMON_FILE" > "$DAEMON_FILE.tmp" 2>/dev/null; then
      mv "$DAEMON_FILE.tmp" "$DAEMON_FILE"
    else
      rm -f "$DAEMON_FILE.tmp"
      die "daemon.json merge failed — existing file left untouched at $DAEMON_FILE"
    fi
  else
    [ -f "$DAEMON_FILE" ] && warn "Existing daemon.json was not a JSON object — rewriting it"
    printf '%s\n' "$NEW_DAEMON" > "$DAEMON_FILE"
  fi
fi
ok "Wrote agent/daemon.json"

# --- Update settings.json: CLAUDE_NOTIFY_URL + TEAM_SPHERE_HELPER ---
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
if [ -f "$SETTINGS_FILE" ] && [ "$DRY_RUN" != "true" ]; then
  if jq --arg url "$NOTIFY_URL" --arg helper "$SCRIPT_DIR/lib/sphere-helper.mjs" \
       '.env.CLAUDE_NOTIFY_URL = $url | .env.TEAM_SPHERE_HELPER = $helper' \
       "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" 2>/dev/null; then
    mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
    ok "Updated CLAUDE_NOTIFY_URL + TEAM_SPHERE_HELPER in settings.json"
  else
    rm -f "$SETTINGS_FILE.tmp"
    warn "Could not update env keys in settings.json — file left untouched"
  fi
elif [ "$DRY_RUN" = "true" ]; then
  info "[dry-run] Update CLAUDE_NOTIFY_URL + TEAM_SPHERE_HELPER in settings.json"
fi

# ============================================================
# Phase 9: Roadmap ⇄ board sync pipeline
# ============================================================
echo ""
info "Phase 9: Roadmap ⇄ project-board sync pipeline..."

# The roadmap-sync hook + /roadmap-sync skill were already copied into .claude/ by
# the Phase 1 `cp -r claude_conf/.` and registered via the deployed settings.json.
# Here we (a) ensure the target project has a docs/ROADMAP.md to reconcile against
# and (b) seed a per-project memory record documenting the always-in-sync rule.

# --- (a) Ensure docs/ROADMAP.md (create the four-state skeleton if absent) ---
ROADMAP_FILE="$TARGET_DIR/docs/ROADMAP.md"
ROADMAP_TEMPLATE="$CONF_DIR/templates/ROADMAP.md"
if [ -f "$ROADMAP_FILE" ]; then
  ok "docs/ROADMAP.md already present — leaving it untouched"
elif [ ! -f "$ROADMAP_TEMPLATE" ]; then
  warn "Roadmap template missing ($ROADMAP_TEMPLATE) — skipping ROADMAP.md seed"
elif [ "$DRY_RUN" = "true" ]; then
  info "[dry-run] mkdir -p $TARGET_DIR/docs && cp roadmap skeleton -> $ROADMAP_FILE"
else
  mkdir -p "$TARGET_DIR/docs"
  cp "$ROADMAP_TEMPLATE" "$ROADMAP_FILE"
  ok "Seeded docs/ROADMAP.md (four-state skeleton) — commit it and run /roadmap-sync"
fi

# --- (b) Seed the per-project memory record (guarded against clobber) ---
# Memory lives OUTSIDE the repo, under the user's Claude projects dir. The project
# slug is the absolute target path with every '/' replaced by '-' (e.g.
# /home/u/proj -> -home-u-proj), matching how Claude Code names the dir.
MEM_TEMPLATE="$CONF_DIR/templates/roadmap-memory.md"
MEM_SLUG=$(printf '%s' "$TARGET_DIR" | sed 's#/#-#g')
MEM_DIR="$HOME/.claude/projects/$MEM_SLUG/memory"
MEM_FILE="$MEM_DIR/roadmap-board-sync.md"
MEM_INDEX="$MEM_DIR/MEMORY.md"
MEM_INDEX_LINE="- [Roadmap ⇄ board sync](roadmap-board-sync.md) — docs/ROADMAP.md and the GitHub Project board stay auto-synced (four-state model); run /roadmap-sync to reconcile."

if [ ! -f "$MEM_TEMPLATE" ]; then
  warn "Memory template missing ($MEM_TEMPLATE) — skipping memory seed"
elif [ "$DRY_RUN" = "true" ]; then
  info "[dry-run] Seed memory record -> $MEM_FILE (+ index line in $MEM_INDEX)"
elif [ -f "$MEM_FILE" ]; then
  ok "Roadmap memory record already present — leaving it untouched"
else
  if mkdir -p "$MEM_DIR" 2>/dev/null; then
    cp "$MEM_TEMPLATE" "$MEM_FILE"
    # Create the index with a header if absent, then append the pointer once.
    if [ ! -f "$MEM_INDEX" ]; then
      printf '# Memory index\n\n' > "$MEM_INDEX"
    fi
    if ! grep -qF 'roadmap-board-sync.md' "$MEM_INDEX" 2>/dev/null; then
      printf '%s\n' "$MEM_INDEX_LINE" >> "$MEM_INDEX"
    fi
    ok "Seeded roadmap memory record -> $MEM_FILE"
  else
    warn "Could not resolve/create memory dir ($MEM_DIR) — skipped memory seed."
    warn "To seed it by hand: cp '$MEM_TEMPLATE' into that project's memory/ dir"
    warn "and add an index line to its MEMORY.md."
  fi
fi

# ============================================================
# Phase 11: gptbridge — ChatGPT/Codex coupling (install-only, OFF by default)
# ============================================================
# Seeds the full `gptbridge` config block (design §7.1) into agent/config.json —
# T1 (Codex coupling) wired here; T2 (relay) + T3 (model-consult) seeded OFF so
# the config surface is complete and extensible. Installs the fenced reverse
# wrapper (already copied by the Phase 1 recursive cp) + templates, reports a
# preflight (codex/cloudflared/OPENAI_API_KEY — absence is informational, the
# feature is OFF), and — ONLY when fully enabled AND `codex` is on PATH — merges
# the forward `codex` MCP server into the project .mcp.json. A fresh install lands
# DISABLED: nothing is enabled, no network surface, no API spend.
echo ""
info "Phase 11: gptbridge (ChatGPT/Codex coupling)..."

# Master gate: SETUP_GPTBRIDGE=1 pre-enables at install (non-interactive override
# contract), else existing config value, else OFF. setup.sh NEVER forces it true.
# Read existing values with an explicit `if` (NOT `[ -f ] && VAR=$(jq)`): jq as the
# last command of an &&-list is NOT set -e exempt, so a malformed config would
# abort the whole setup — the `|| echo` fallback keeps it robust.
GB_EX=false
if [ -f "$CONFIG_FILE" ]; then GB_EX=$(jq -r '.gptbridge.enabled // false' "$CONFIG_FILE" 2>/dev/null || echo false); fi
[ "$GB_EX" = "true" ] || GB_EX=false
# Treat SET-BUT-EMPTY as "no choice" (falls through to existing) — a stray empty
# export must not silently flip the gate.
if [ -n "${SETUP_GPTBRIDGE:-}" ]; then
  case "$SETUP_GPTBRIDGE" in 1|true|yes|on) GB_MASTER=true ;; *) GB_MASTER=false ;; esac
else
  GB_MASTER=$GB_EX
fi
# codex tier flag (default on — effective only when master gate on AND codex on PATH).
GB_CODEX_EX=true
if [ -f "$CONFIG_FILE" ]; then GB_CODEX_EX=$(jq -r '.gptbridge.codex.enabled // true' "$CONFIG_FILE" 2>/dev/null || echo true); fi
[ "$GB_CODEX_EX" = "false" ] || GB_CODEX_EX=true
if [ -n "${SETUP_GPTBRIDGE_CODEX:-}" ]; then
  case "$SETUP_GPTBRIDGE_CODEX" in 0|false|no|off) GB_CODEX=false ;; *) GB_CODEX=true ;; esac
else
  GB_CODEX=$GB_CODEX_EX
fi

# Default gptbridge block — the full §7.1 schema. All tiers OFF; codex tier flag on
# (gated by the master gate). Seeding T2/T3 keys now means the next feature deep-
# merges under them without a schema migration.
GPTBRIDGE_DEFAULTS=$(jq -n '{
  enabled: false,
  codex: { enabled: true, sandbox: "read-only", tool_timeout_s: 300,
           consult_claude: { max_turns: 15, timeout_s: 300, max_question_kb: 8,
                             allowed_tools: ["Read","Grep","Glob","LS"] } },
  relay: { enabled: false, port: 8873, expose: "quicktunnel", ttl_hours: 4,
           stop_with_session: true, sync_wait_s: 20, reply_policy: "owner_approve",
           max_consult_kb: 16, max_consults_per_hour: 30 },
  model_consult: { enabled: false, server: "mcp-chatgpt-responses" },
  advanced_read_tools: false
}')

if [ "$DRY_RUN" = "true" ]; then
  info "[dry-run] Seed .gptbridge defaults (enabled=$GB_MASTER, codex=$GB_CODEX) into $CONFIG_FILE"
else
  if [ -f "$CONFIG_FILE" ] && jq -e 'type=="object"' "$CONFIG_FILE" >/dev/null 2>&1; then
    # Deep-merge defaults UNDER the existing block (existing leaf wins → user
    # tuning of caps survives a re-run), then force the on/off flags deterministically.
    if jq --argjson def "$GPTBRIDGE_DEFAULTS" --argjson master "$GB_MASTER" --argjson codex "$GB_CODEX" '
          .gptbridge = ($def * (.gptbridge // {}))
          | .gptbridge.enabled = $master
          | .gptbridge.codex.enabled = $codex
        ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null; then
      mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
      ok "Seeded gptbridge config (enabled=$GB_MASTER, codex tier=$GB_CODEX; all tiers OFF unless enabled)"
    else
      rm -f "$CONFIG_FILE.tmp"
      warn "gptbridge config seed failed — existing config left untouched at $CONFIG_FILE"
    fi
  else
    warn "config.json missing/not-an-object — gptbridge seed skipped (identity phase must run first)"
  fi
fi

# Make the reverse-direction fenced wrapper node-runnable regardless of umask.
[ -f "$CLAUDE_DIR/hooks/gptbridge/consult-claude-mcp.mjs" ] && \
  run_or_dry chmod +x "$CLAUDE_DIR/hooks/gptbridge/consult-claude-mcp.mjs"

# Preflight report (informational — the feature is OFF; absence is not an error).
GB_HAVE_CODEX=no; command -v codex >/dev/null 2>&1 && GB_HAVE_CODEX=yes
GB_HAVE_CF=no; command -v cloudflared >/dev/null 2>&1 && GB_HAVE_CF=yes
GB_HAVE_KEY=no; [ -n "${OPENAI_API_KEY:-}" ] && GB_HAVE_KEY=yes

# T1 forward: merge the `codex` MCP server into the project .mcp.json ONLY when
# fully enabled AND codex is installed. Fresh (OFF) install → skipped.
GB_FWD_STATUS="not merged (gptbridge master gate OFF)"
GB_MCP_DEST="$TARGET_DIR/.mcp.json"
GB_TEMPLATE="$CLAUDE_DIR/templates/mcp-gptbridge.json"
if [ "$GB_MASTER" = "true" ] && [ "$GB_CODEX" = "true" ] && [ "$GB_HAVE_CODEX" = "yes" ] && [ -f "$GB_TEMPLATE" ]; then
  if [ "$DRY_RUN" = "true" ]; then
    GB_FWD_STATUS="[dry-run] would merge 'codex' server into $GB_MCP_DEST"
  elif [ -f "$GB_MCP_DEST" ]; then
    if jq -s '.[0] as $dst | .[1].mcpServers.codex as $codex
              | $dst | .mcpServers = ((.mcpServers // {}) + {codex:$codex})' \
          "$GB_MCP_DEST" "$GB_TEMPLATE" > "$GB_MCP_DEST.tmp" 2>/dev/null; then
      mv "$GB_MCP_DEST.tmp" "$GB_MCP_DEST"; GB_FWD_STATUS="merged 'codex' server into .mcp.json"
    else
      rm -f "$GB_MCP_DEST.tmp"; GB_FWD_STATUS="MERGE FAILED — add the codex entry manually (see template)"
    fi
  else
    # Create branch: write via .tmp+mv so a jq failure can't leave a truncated
    # zero-byte .mcp.json that Claude Code then fails to parse.
    if jq -n --slurpfile t "$GB_TEMPLATE" '{mcpServers:{codex:$t[0].mcpServers.codex}}' > "$GB_MCP_DEST.tmp" 2>/dev/null; then
      mv "$GB_MCP_DEST.tmp" "$GB_MCP_DEST"; GB_FWD_STATUS="created .mcp.json with 'codex' server"
    else
      rm -f "$GB_MCP_DEST.tmp"; GB_FWD_STATUS="CREATE FAILED — add the codex entry manually (see template)"
    fi
  fi
elif [ "$GB_MASTER" = "true" ] && [ "$GB_CODEX" = "true" ] && [ "$GB_HAVE_CODEX" != "yes" ]; then
  GB_FWD_STATUS="codex tier ON but 'codex' not on PATH — inert until Codex CLI is installed"
else
  # Feature (or codex tier) OFF: actively STRIP any previously-merged codex server
  # so "disabled" is honored for the forward direction too — Claude Code would
  # otherwise keep launching `codex mcp-server` every session. Idempotent.
  GB_FWD_STATUS="not merged (gptbridge master gate OFF)"
  [ "$GB_MASTER" = "true" ] && [ "$GB_CODEX" != "true" ] && GB_FWD_STATUS="codex tier disabled"
  if [ "$DRY_RUN" != "true" ] && [ -f "$GB_MCP_DEST" ] && \
     jq -e '.mcpServers.codex' "$GB_MCP_DEST" >/dev/null 2>&1; then
    if jq 'if .mcpServers then .mcpServers |= del(.codex) else . end' "$GB_MCP_DEST" > "$GB_MCP_DEST.tmp" 2>/dev/null; then
      mv "$GB_MCP_DEST.tmp" "$GB_MCP_DEST"; GB_FWD_STATUS="$GB_FWD_STATUS; removed stale 'codex' entry from .mcp.json"
    else
      rm -f "$GB_MCP_DEST.tmp"
    fi
  fi
fi

echo ""
echo "  gptbridge status (ChatGPT/Codex mutual-consult — docs/chatgpt-mcp-coupling-design.md):"
echo "    master gate:   $GB_MASTER   (T1 Codex coupling wired; T2 relay + T3 model-consult seeded OFF)"
echo "    codex tier:    $GB_CODEX"
echo "    preflight:     codex=$GB_HAVE_CODEX   cloudflared=$GB_HAVE_CF (T2)   OPENAI_API_KEY=$GB_HAVE_KEY (T3)"
echo "    forward (Claude to Codex): $GB_FWD_STATUS"
echo "    reverse (Codex to Claude): fenced wrapper $CLAUDE_DIR/hooks/gptbridge/consult-claude-mcp.mjs"
echo ""
echo "    To enable T1 (Claude <-> Codex; local stdio, no tunnel, no tokens, no API spend):"
echo "      1. Install Codex CLI, then:  codex login   (uses your existing ChatGPT subscription)"
echo "      2. Set .gptbridge.enabled=true in $CONFIG_FILE   (or re-run with SETUP_GPTBRIDGE=1)"
echo "      3. Forward (Claude consults Codex): re-run setup.sh (merges the codex .mcp.json entry), or:"
echo "           claude mcp add codex -- codex mcp-server"
echo "         Add MCP_TOOL_TIMEOUT=300000 to .claude/settings.json 'env' — agentic turns exceed the 60s default."
echo "      4. Reverse (Codex consults Claude, read-only + fenced) — append to ~/.codex/config.toml:"
if [ -f "$CLAUDE_DIR/templates/codex-config.toml.snippet" ]; then
  # LITERAL substitution via bash parameter expansion (no sed) so a `|`/`&`/regex
  # char in $TARGET_DIR can't break the delimiter or expand into the output.
  while IFS= read -r _gb_ln || [ -n "$_gb_ln" ]; do
    printf '           %s\n' "${_gb_ln//__PROJECT_DIR__/$TARGET_DIR}"
  done < "$CLAUDE_DIR/templates/codex-config.toml.snippet"
fi
echo "    Kill switch: GPTBRIDGE_DISABLE=1 (env) makes the reverse wrapper refuse; master gate OFF disables everything."

# ============================================================
# Phase 9.5: Transport preflight
# A fresh peer whose transport helper or identity is unresolved would SILENTLY dry-run every
# outbound coordination message (it looks connected; replies never come). Verify here, loudly,
# so it's caught at install — not on the first dropped consult. No network calls.
# ============================================================
PREFLIGHT_OK=true
if [ "$DRY_RUN" != "true" ]; then
  echo ""
  info "Preflight: verifying transport is actually usable…"

  # (a) identity present with an npub
  if [ -f "$CLAUDE_DIR/agent/identity.json" ] && \
     [ -n "$(jq -r '.npub // empty' "$CLAUDE_DIR/agent/identity.json" 2>/dev/null)" ]; then
    ok "  identity ok ($CLAUDE_DIR/agent/identity.json)"
  else
    warn "  identity MISSING or has no npub — outbound coordination will fail"
    PREFLIGHT_OK=false
  fi

  # (b) transport helper is present at the recorded path (stays under the clone for sdk resolution)
  PF_HELPER="$SCRIPT_DIR/lib/sphere-helper.mjs"
  if [ -f "$PF_HELPER" ]; then
    ok "  transport helper ok ($PF_HELPER)"
  else
    warn "  transport helper MISSING at $PF_HELPER"
    PREFLIGHT_OK=false
  fi

  # (c) the transport SDK resolves the SAME way the helper resolves it at runtime — a natural
  # node_modules walk from the helper's own directory (no NODE_PATH, no network). This catches
  # the "npm install never ran" / helper-in-wrong-location case reliably. (A bare
  # import('@unicitylabs/sphere-sdk') from here would false-fail — the package's ESM exports
  # only resolve for an importer that sits under the clone.)
  if [ -f "$PF_HELPER" ]; then
    if ( cd "$(dirname "$PF_HELPER")" && node -e "require.resolve('@unicitylabs/sphere-sdk')" ) >/dev/null 2>&1; then
      ok "  @unicitylabs/sphere-sdk resolves ok"
    else
      warn "  @unicitylabs/sphere-sdk NOT resolvable from $(dirname "$PF_HELPER") — run: (cd \"$SCRIPT_DIR\" && npm install)"
      PREFLIGHT_OK=false
    fi
  fi
fi

# ============================================================
# Phase 10: Summary
# ============================================================
echo ""
if [ "$PREFLIGHT_OK" != "true" ]; then
  echo "============================================"
  echo "  Setup INCOMPLETE — transport preflight FAILED"
  echo "============================================"
  echo ""
  echo "  The framework is installed but the message transport is NOT usable."
  echo "  If you proceed, your outbound coordination messages will fail LOUDLY"
  echo "  (they will NOT silently vanish — that bug is fixed), but you cannot"
  echo "  coordinate until the item(s) flagged above are resolved."
  echo "  Most common fix:  (cd \"$SCRIPT_DIR\" && npm install)   then re-run setup.sh"
  echo ""
  exit 1
fi
echo "============================================"
echo "  Setup Complete"
echo "============================================"
echo ""
echo "  Agent nametag:   $AGENT_NAMETAG"
echo "  Agent identity:  $AGENT_NPUB"
echo "  Owner:           $OWNER_NAMETAG${OWNER_NPUB:+ ($OWNER_NPUB)}"
echo "  Network:         $NETWORK ($RELAY_URL)"
echo "  Group:           $GROUP_NAME ($GROUP_ID)"
echo "  Notifications:   ${NOTIFY_URL:-disabled (desktop only)}"
echo "  Dep tracking:    ${SELECTED_DEPS[*]:-disabled}"
echo ""
echo "  Config dir:      $CLAUDE_DIR/"
echo "  Identity:        $CLAUDE_DIR/agent/identity.json"
echo "  Roadmap:         $TARGET_DIR/docs/ROADMAP.md (⇄ Project board — run /roadmap-sync)"
echo "  gptbridge:       installed ($([ "$GB_MASTER" = "true" ] && echo ENABLED || echo DISABLED) — ChatGPT/Codex mutual-consult; see docs/chatgpt-mcp-coupling-design.md)"
echo ""
info "Message daemon: starts AUTOMATICALLY on each Claude session (SessionStart hook →"
info "  .claude/hooks/daemon-session.sh) and stops when the last session ends. It runs"
info "  self-detached (survives the launching shell); concurrent sessions share one daemon."
info "  Manual control if you need it:"
info "    bash $CLAUDE_DIR/hooks/a2a.sh daemon status|start|stop|restart"
echo ""

# ============================================================
# Phase 9.6: End-to-end round-trip self-test (the missing check dmytro + claude-test1 flagged)
# The config-level preflight above proves resolution; this proves the transport actually MOVES
# a message both ways (identity → helper → relay → gift-wrap → back). LOUD PASS/FAIL with a
# diagnosis. Non-fatal: a transient relay outage must not block a completed local install
# (the fatal config checks already ran), but the result is printed unmissably.
# Skippable with SETUP_SKIP_VERIFY=1 (CI / offline upgrades).
# ============================================================
if [ "$DRY_RUN" != "true" ] && [ "${SETUP_SKIP_VERIFY:-}" != "1" ] && [ -x "$CLAUDE_DIR/hooks/a2a.sh" ]; then
  info "Round-trip self-test (live relay — send+receive to self)…"
  if CLAUDE_PROJECT_DIR="$TARGET_DIR" TEAM_SPHERE_HELPER="$SCRIPT_DIR/lib/sphere-helper.mjs" \
       bash "$CLAUDE_DIR/hooks/a2a.sh" verify --timeout 40; then
    ok "A2A transport round-trip verified"
  else
    warn "A2A round-trip self-test did NOT pass (diagnosis above). The framework IS installed;"
    warn "re-check with:  bash $CLAUDE_DIR/hooks/a2a.sh verify"
    warn "Most common causes: relay unreachable/flaky, or (cd \"$SCRIPT_DIR\" && npm install) not run."
  fi
  echo ""
elif [ "$DRY_RUN" != "true" ] && [ "${SETUP_SKIP_VERIFY:-}" = "1" ]; then
  info "Round-trip self-test skipped (SETUP_SKIP_VERIFY=1)."
fi

# ============================================================
# Phase 9.7: One-command mutual onboarding — redeem an invite ticket
# The redeem does its own check-messages polling, so it works BEFORE the daemon is started.
# ============================================================
if [ -n "$TICKET_STR" ] && [ "$DRY_RUN" != "true" ]; then
  echo ""
  info "Redeeming invite ticket (single-command mutual onboarding)…"
  # The ticket embeds a bearer SECRET — hand it to ticket.sh via a 0600 file (auto-removed),
  # NOT on argv, so no child process re-exposes it on `ps` / /proc/<pid>/cmdline.
  TICKET_TMP="$(umask 077; mktemp "${TMPDIR:-/tmp}/onboard-ticket.XXXXXX")"
  trap 'rm -f "$TICKET_TMP"' EXIT
  printf '%s' "$TICKET_STR" > "$TICKET_TMP"
  if CLAUDE_PROJECT_DIR="$TARGET_DIR" bash "$CLAUDE_DIR/hooks/ticket.sh" redeem --ticket-file "$TICKET_TMP" --yes; then
    echo ""
    echo "  ✅ MUTUAL AUTH complete — you and the issuer now recognize each other."
    echo "     Start the daemon (above), then:  /consult-coordinator <issuer-name> \"…\""
  else
    echo ""
    warn "Ticket redemption did NOT complete (reason above). The framework IS installed;"
    warn "once the issuer is reachable (their daemon up, same relay), re-run:"
    warn "  CLAUDE_PROJECT_DIR=$TARGET_DIR bash $CLAUDE_DIR/hooks/ticket.sh redeem '<ticket>'"
    exit 1
  fi
fi
