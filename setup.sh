#!/bin/bash
# Interactive setup script for Unicity Claude Code instances.
# Deploys claude_conf/ to a target project's .claude/ directory,
# creates a Unicity identity (secp256k1 keypair), configures owner
# and group membership, and sets up agent communication.
#
# Usage: ./setup.sh <target-project-dir> [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$SCRIPT_DIR/claude_conf"
DRY_RUN=false
SERENA_ONLY=false

# --- Helpers ---

info()  { printf '\033[1;34m[info]\033[0m  %s\n' "$1"; }
ok()    { printf '\033[1;32m[ok]\033[0m    %s\n' "$1"; }
warn()  { printf '\033[1;33m[warn]\033[0m  %s\n' "$1"; }
err()   { printf '\033[1;31m[error]\033[0m %s\n' "$1" >&2; }
die()   { err "$1"; exit 1; }

prompt_yn() {
  local msg="$1" default="${2:-y}"
  local yn
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
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$msg" "$default" >&2
  else
    printf '%s: ' "$msg" >&2
  fi
  read -r val
  echo "${val:-$default}"
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
    --ticket) TICKET_STR="${2:-}"; shift 2 ;;
    --ticket=*) TICKET_STR="${1#--ticket=}"; shift ;;
    --help|-h)
      echo "Usage: $0 <target-project-dir> [--dry-run] [--serena-only] [--ticket '<t>']"
      echo ""
      echo "Deploys Unicity Claude Code configuration to a target project."
      echo ""
      echo "Options:"
      echo "  --dry-run      Print actions without executing"
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
  die "Usage: $0 <target-project-dir> [--dry-run] [--serena-only]"
fi

# Resolve to absolute path
TARGET_DIR="$(cd "$TARGET_DIR" 2>/dev/null && pwd)" || die "Target directory does not exist: $TARGET_DIR"

echo ""
echo "============================================"
echo "  Unicity Claude Code Setup"
echo "============================================"
echo ""
info "Target project: $TARGET_DIR"
[ "$DRY_RUN" = "true" ] && warn "DRY RUN mode — no changes will be made"
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
  CLAUDE_DIR="$TARGET_DIR/.claude"
  GITIGNORE="$TARGET_DIR/.gitignore"
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
# Phase 1: File deployment
# ============================================================
info "Phase 1: Deploying configuration files..."

# Validate target is a git repo
if [ ! -d "$TARGET_DIR/.git" ]; then
  die "Target directory is not a git repository: $TARGET_DIR"
fi

# Copy claude_conf/ → <target>/.claude/
CLAUDE_DIR="$TARGET_DIR/.claude"
if [ -d "$CLAUDE_DIR" ] && [ "$DRY_RUN" != "true" ]; then
  if ! prompt_yn "  .claude/ already exists in target. Overwrite?"; then
    die "Aborted."
  fi
fi

run_or_dry cp -r "$CONF_DIR/." "$CLAUDE_DIR/"
ok "Copied claude_conf/ → .claude/"

# Ensure hook scripts are executable after deployment. cp -r preserves source
# modes, but make the +x bit explicit so the harness can always invoke them
# (and so a checkout that lost the bit doesn't silently break the hooks).
if [ -d "$CLAUDE_DIR/hooks" ]; then
  run_or_dry chmod +x "$CLAUDE_DIR/hooks"/*.sh
  ok "Made hook scripts executable"
fi

# Append .claude to .gitignore
GITIGNORE="$TARGET_DIR/.gitignore"
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

if [ -f "$IDENTITY_FILE" ] && [ "$DRY_RUN" != "true" ]; then
  EXISTING_NPUB=$(jq -r '.npub // "unknown"' "$IDENTITY_FILE" 2>/dev/null)
  info "Existing identity found: $EXISTING_NPUB"
  if ! prompt_yn "  Create a new identity? (existing will be overwritten)"; then
    ok "Keeping existing identity"
    IDENTITY_CREATED=false
  else
    IDENTITY_CREATED=true
  fi
else
  IDENTITY_CREATED=true
fi

SPHERE_SDK_AVAILABLE=true

# Agent nametag — ask first, before identity generation
AGENT_NAMETAG=$(prompt_input "Agent nametag for this instance (e.g., claude-otc-bot, claude-sphere)" "claude-$(basename "$TARGET_DIR")")
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
    else
      warn "sphere-sdk not available — falling back to manual import."
      IMPORT_NPUB=$(prompt_input "Enter existing npub")
      IMPORT_NSEC=$(prompt_input "Enter existing nsec")
      AGENT_NPUB="$IMPORT_NPUB"

      if [ "$DRY_RUN" != "true" ]; then
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
      ok "Imported identity: $AGENT_NPUB"
    fi
  else
    # Import existing identity
    IMPORT_NPUB=$(prompt_input "Enter existing npub")
    IMPORT_NSEC=$(prompt_input "Enter existing nsec")
    AGENT_NPUB="$IMPORT_NPUB"

    if [ "$DRY_RUN" != "true" ]; then
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
    ok "Imported identity: $AGENT_NPUB"
  fi
else
  AGENT_NPUB=$(jq -r '.npub // "unknown"' "$IDENTITY_FILE" 2>/dev/null)
fi

# Store nametag in identity file (after it's been created/imported above)
if [ -f "$IDENTITY_FILE" ] && [ "$DRY_RUN" != "true" ]; then
  jq --arg nametag "$AGENT_NAMETAG" '.nametag = $nametag' "$IDENTITY_FILE" > "$IDENTITY_FILE.tmp" \
    && mv "$IDENTITY_FILE.tmp" "$IDENTITY_FILE"
  chmod 600 "$IDENTITY_FILE"
fi

# ============================================================
# Phase 3: Owner configuration
# ============================================================
echo ""
info "Phase 3: Owner configuration..."

OWNER_NAMETAG=$(prompt_input "Enter the owner's nametag (e.g., babaika10)")
OWNER_NAMETAG="${OWNER_NAMETAG#@}"  # strip leading @ if present

OWNER_NPUB=$(prompt_input "Enter the owner's npub (leave empty if unknown)" "")

if [ -z "$OWNER_NPUB" ]; then
  info "Owner npub not set — nametag '$OWNER_NAMETAG' will be resolved at runtime by the agent."
fi

ok "Owner: $OWNER_NAMETAG${OWNER_NPUB:+ ($OWNER_NPUB)}"

# ============================================================
# Phase 3b: Coordinator (optional) — pre-record its nametag → npub
# ============================================================
# If this instance is a TEAMMATE joining a coordination circle, pre-recording the
# coordinator's Unicity nametag lets you address it by name from the first boot
# (e.g. `/consult-coordinator concierge-coord …`), resolving to its npub locally via
# the agent-registry cache instead of a network lookup. Entirely optional and
# backward compatible: leave the nametag empty to skip.
COORD_NAMETAG=$(prompt_input "Coordinator nametag to pre-record (empty to skip)" "")
COORD_NAMETAG="${COORD_NAMETAG#@}"  # strip leading @ if present
COORD_NPUB=""
if [ -n "$COORD_NAMETAG" ]; then
  COORD_NPUB=$(prompt_input "Coordinator npub (leave empty to resolve '$COORD_NAMETAG' now)" "")
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

echo "  1) testnet (default)"
echo "  2) mainnet"
echo "  3) devnet (localhost)"
NETWORK=$(prompt_input "Network environment" "testnet")

case "$NETWORK" in
  1|testnet)
    NETWORK="testnet"
    RELAY_URL="wss://nostr-relay.testnet.unicity.network"
    ;;
  2|mainnet)
    NETWORK="mainnet"
    RELAY_URL="wss://relay.unicity.network"
    ;;
  3|devnet)
    NETWORK="devnet"
    RELAY_URL="ws://localhost:7777"
    ;;
  *)
    warn "Unknown network '$NETWORK', defaulting to testnet"
    NETWORK="testnet"
    RELAY_URL="wss://nostr-relay.testnet.unicity.network"
    ;;
esac

ok "Network: $NETWORK ($RELAY_URL)"

# ============================================================
# Phase 5: Notification URL
# ============================================================
echo ""
info "Phase 5: Notification configuration..."

NOTIFY_URL=$(prompt_input "Mobile notification URL (ntfy.sh/<topic>, leave empty to skip)" "")

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

# Read available deps from dep-map.json
DEP_MAP_FILE="$CONF_DIR/hooks/dep-map.json"
if [ -f "$DEP_MAP_FILE" ]; then
  # Check if this repo is in the dep-map
  REPO_DEPS=$(jq -r --arg repo "$REPO_BASENAME" '.repos[$repo].deps // [] | .[].name' "$DEP_MAP_FILE" 2>/dev/null)

  if [ -n "$REPO_DEPS" ]; then
    info "Detected repo: $REPO_BASENAME"
    info "Available upstream dependencies:"
    i=1
    declare -a DEP_LIST=()
    while IFS= read -r dep; do
      DEP_LIST+=("$dep")
      CHECK_TYPE=$(jq -r --arg repo "$REPO_BASENAME" --arg dep "$dep" \
        '.repos[$repo].deps[] | select(.name == $dep) | .check' "$DEP_MAP_FILE" 2>/dev/null)
      printf '  [%d] %s (%s)\n' "$i" "$dep" "$CHECK_TYPE"
      i=$((i + 1))
    done <<< "$REPO_DEPS"

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
    info "Repo '$REPO_BASENAME' not found in dep-map.json"
    if prompt_yn "  Add custom dependency tracking?" "n"; then
      CUSTOM_DEP=$(prompt_input "Dependency name (e.g., sphere-sdk)")
      if [ -n "$CUSTOM_DEP" ]; then
        SELECTED_DEPS+=("$CUSTOM_DEP")
      fi
    fi
  fi
else
  warn "dep-map.json not found, skipping dependency configuration"
fi

if [ ${#SELECTED_DEPS[@]} -gt 0 ]; then
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

GROUP_NAME="UNICITY_DEV_AGENTS"
GROUP_ID=""

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

# ============================================================
# Phase 8: Write configuration files
# ============================================================
echo ""
info "Phase 8: Writing configuration files..."

# Build selected_deps JSON array
DEPS_JSON="[]"
if [ ${#SELECTED_DEPS[@]} -gt 0 ]; then
  DEPS_JSON=$(printf '%s\n' "${SELECTED_DEPS[@]}" | jq -R . | jq -s .)
fi

# --- agent/config.json ---
CONFIG_FILE="$CLAUDE_DIR/agent/config.json"
if [ "$DRY_RUN" = "true" ]; then
  info "[dry-run] Write $CONFIG_FILE"
else
  jq -n \
    --arg agent_nametag "$AGENT_NAMETAG" \
    --arg owner_npub "$OWNER_NPUB" \
    --arg owner_nametag "$OWNER_NAMETAG" \
    --arg notification_url "$NOTIFY_URL" \
    --arg group_name "$GROUP_NAME" \
    --arg group_id "$GROUP_ID" \
    --arg relay "$RELAY_URL" \
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
        relays: [$relay]
      },
      transport: {
        helper_path: $helper_path
      },
      dep_tracking: {
        enabled: $dep_enabled,
        selected_deps: $selected_deps
      }
    }' > "$CONFIG_FILE"
fi
ok "Wrote agent/config.json"

# Record the transport helper path as an env var too (mirrors the CLAUDE_NOTIFY_URL write
# below), so the hooks resolve it even if config.json is read before jq is available. The
# helper MUST stay under the clone ($SCRIPT_DIR) — it loads @unicitylabs/sphere-sdk from the
# clone's node_modules; copying it into .claude/ would find the file but break the sdk import.

# --- agent/daemon.json ---
DAEMON_FILE="$CLAUDE_DIR/agent/daemon.json"
if [ "$DRY_RUN" = "true" ]; then
  info "[dry-run] Write $DAEMON_FILE"
else
  jq -n \
    --arg relay "$RELAY_URL" \
    --arg group_id "$GROUP_ID" \
    --arg group_name "$GROUP_NAME" \
    --arg owner_npub "$OWNER_NPUB" \
    '{
      relays: [$relay],
      subscriptions: {
        groups: [{id: $group_id, name: $group_name}],
        dm_contacts: [$owner_npub]
      },
      hooks: {
        on_dm: ".claude/hooks/on-dm.sh",
        on_group_message: ".claude/hooks/on-group-message.sh"
      }
    }' > "$DAEMON_FILE"
fi
ok "Wrote agent/daemon.json"

# --- Update settings.json: CLAUDE_NOTIFY_URL + TEAM_SPHERE_HELPER ---
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
if [ -f "$SETTINGS_FILE" ] && [ "$DRY_RUN" != "true" ]; then
  jq --arg url "$NOTIFY_URL" --arg helper "$SCRIPT_DIR/lib/sphere-helper.mjs" \
     '.env.CLAUDE_NOTIFY_URL = $url | .env.TEAM_SPHERE_HELPER = $helper' \
     "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" \
    && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
  ok "Updated CLAUDE_NOTIFY_URL + TEAM_SPHERE_HELPER in settings.json"
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
echo ""
info "To start the message daemon (run from the clone so the transport helper resolves):"
info "  nohup node $SCRIPT_DIR/lib/sphere-daemon.mjs start --project $TARGET_DIR --live >/tmp/sphere-daemon.log 2>&1 &"
info "  # --live = sub-second push; polls every 5s as fallback (default)."
info "  # The daemon runs in the FOREGROUND; a bare '… &' dies with your shell. Use nohup"
info "  #   (above) or a systemd --user unit for durability across logout/session-end."
echo ""

# ============================================================
# Phase 9.7: One-command mutual onboarding — redeem an invite ticket
# The redeem does its own check-messages polling, so it works BEFORE the daemon is started.
# ============================================================
if [ -n "$TICKET_STR" ] && [ "$DRY_RUN" != "true" ]; then
  echo ""
  info "Redeeming invite ticket (single-command mutual onboarding)…"
  if CLAUDE_PROJECT_DIR="$TARGET_DIR" bash "$CLAUDE_DIR/hooks/ticket.sh" redeem "$TICKET_STR" --yes; then
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
