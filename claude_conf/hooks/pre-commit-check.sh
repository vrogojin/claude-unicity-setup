#!/bin/bash
# Block git commit if language-specific checks fail.
# Auto-detects project type from Cargo.toml, package.json, or go.mod.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Only intercept git commit commands
if ! echo "$COMMAND" | grep -q "git commit"; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR" || exit 0

BLOCKED=false
REASONS=""

# --- Rust ---
if [ -f "Cargo.toml" ]; then
  if ! cargo fmt --all --check >/dev/null 2>&1; then
    BLOCKED=true
    REASONS="${REASONS}cargo fmt --all --check failed. Run cargo fmt --all to fix formatting.\n"
  fi

  if ! cargo clippy --workspace -- -D warnings >/dev/null 2>&1; then
    CLIPPY_OUTPUT=$(cargo clippy --workspace -- -D warnings 2>&1 | tail -5)
    BLOCKED=true
    REASONS="${REASONS}cargo clippy failed:\n${CLIPPY_OUTPUT}\n"
  fi
fi

# --- TypeScript / Node.js ---
if [ -f "package.json" ]; then
  # Honor the project's ACTUAL package manager (repo may be pnpm/yarn, not npm) — a hardcoded
  # `npm run` in a pnpm repo runs against the wrong / an absent node_modules. Detect by lockfile,
  # fall back to npm. Output is redirected anyway, so `<pm> run <script>` (no --silent) is uniform.
  if [ -f "pnpm-lock.yaml" ] && command -v pnpm >/dev/null 2>&1; then PM=pnpm
  elif [ -f "yarn.lock" ] && command -v yarn >/dev/null 2>&1; then PM=yarn
  else PM=npm; fi

  # Check if lint script exists
  if jq -e '.scripts.lint' package.json >/dev/null 2>&1; then
    if ! "$PM" run lint >/dev/null 2>&1; then
      LINT_OUTPUT=$("$PM" run lint 2>&1 | tail -5)
      BLOCKED=true
      REASONS="${REASONS}${PM} run lint failed:\n${LINT_OUTPUT}\n"
    fi
  fi

  # Check if typecheck script exists
  if jq -e '.scripts.typecheck' package.json >/dev/null 2>&1; then
    if ! "$PM" run typecheck >/dev/null 2>&1; then
      TC_OUTPUT=$("$PM" run typecheck 2>&1 | tail -5)
      BLOCKED=true
      REASONS="${REASONS}${PM} run typecheck failed:\n${TC_OUTPUT}\n"
    fi
  fi
fi

# --- Go ---
if [ -f "go.mod" ]; then
  if ! go vet ./... >/dev/null 2>&1; then
    VET_OUTPUT=$(go vet ./... 2>&1 | tail -5)
    BLOCKED=true
    REASONS="${REASONS}go vet failed:\n${VET_OUTPUT}\n"
  fi

  # Check gofmt
  UNFORMATTED=$(gofmt -l . 2>/dev/null)
  if [ -n "$UNFORMATTED" ]; then
    BLOCKED=true
    REASONS="${REASONS}gofmt: unformatted files:\n${UNFORMATTED}\n"
  fi
fi

if [ "$BLOCKED" = true ]; then
  jq -n --arg reason "Pre-commit checks failed. Fix before committing:\n${REASONS}" '{
    "decision": "block",
    "reason": $reason
  }'
  exit 0
fi

exit 0
