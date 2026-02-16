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
    info "[dry-run] node $helper $*"
    echo '{"dry_run": true}'
    return 0
  fi
  NODE_PATH="$SCRIPT_DIR/node_modules:${NODE_PATH:-}" node "$helper" "$@"
}

# --- Parse arguments ---

TARGET_DIR=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --help|-h)
      echo "Usage: $0 <target-project-dir> [--dry-run]"
      echo ""
      echo "Deploys Unicity Claude Code configuration to a target project."
      echo ""
      echo "Options:"
      echo "  --dry-run   Print actions without executing"
      echo "  --help      Show this help"
      exit 0
      ;;
    *) TARGET_DIR="$arg" ;;
  esac
done

if [ -z "$TARGET_DIR" ]; then
  die "Usage: $0 <target-project-dir> [--dry-run]"
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
    RELAY_URL="wss://relay.testnet.unicity.network"
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
    RELAY_URL="wss://relay.testnet.unicity.network"
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
    --argjson dep_enabled "$DEP_TRACKING_ENABLED" \
    --argjson selected_deps "$DEPS_JSON" \
    '{
      agent_nametag: $agent_nametag,
      owner_npub: $owner_npub,
      owner_nametag: $owner_nametag,
      notification_url: $notification_url,
      group: {
        name: $group_name,
        id: $group_id,
        relays: [$relay]
      },
      dep_tracking: {
        enabled: $dep_enabled,
        selected_deps: $selected_deps
      }
    }' > "$CONFIG_FILE"
fi
ok "Wrote agent/config.json"

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

# --- Update settings.json: CLAUDE_NOTIFY_URL ---
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
if [ -f "$SETTINGS_FILE" ] && [ "$DRY_RUN" != "true" ]; then
  jq --arg url "$NOTIFY_URL" '.env.CLAUDE_NOTIFY_URL = $url' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" \
    && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
  ok "Updated CLAUDE_NOTIFY_URL in settings.json"
fi

# ============================================================
# Phase 9: Summary
# ============================================================
echo ""
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
echo ""
info "Run 'sphere-daemon start' in the project directory to begin listening."
echo ""
