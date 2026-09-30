#!/bin/bash
# Block git commit if language-specific checks fail.
# Auto-detects project type from Cargo.toml, package.json, or go.mod.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Only intercept git commit commands
if ! echo "$COMMAND" | grep -q "git commit"; then
  exit 0
fi

# Resolve which repo this commit actually targets — NOT always $CLAUDE_PROJECT_DIR.
# A session can run `git commit` against a different repo entirely (another checkout,
# a worktree, a sibling project) by leading the command with `cd <path>`. Blindly
# checking $CLAUDE_PROJECT_DIR in that case lints/typechecks the WRONG repository and
# can block (or wrongly pass) a commit based on an unrelated project's pre-existing
# issues.
#
# Base directory: the hook payload's own `.cwd` (the session's actual tracked
# directory when this command was issued), else $CLAUDE_PROJECT_DIR as a last resort.
# If the command's first line leads with `cd <path>`, resolve it with a REAL `cd` in a
# subshell seeded at that base — not a textual/sed extraction fed straight to
# `git -C`, which can't expand `$HOME`, honour quoting/escaped spaces, or resolve a
# relative path (`cd ..`, `cd ../sibling`) against the right starting point. A
# textual guess that's merely wrong can silently land on a different, real, EXISTING
# directory with no error at all — worse than failing open. Only trust the result if
# the `cd` actually succeeds; otherwise keep the base rather than proceed on a guess.
BASE_DIR="$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)"
[ -n "$BASE_DIR" ] || BASE_DIR="$CLAUDE_PROJECT_DIR"

TARGET_DIR="$BASE_DIR"
FIRST_LINE="$(printf '%s\n' "$COMMAND" | head -1)"
if echo "$FIRST_LINE" | grep -qE '^cd[[:space:]]'; then
  # Truncate at the FIRST '&', ';' or '|' (a single class, so it catches '&&' and
  # '||' too, and a bare '&' background operator) — not one anchored at the end of
  # the line. A trailing-only anchor leaves the whole rest of an ordinary single-line
  # compound command (`cd apps/web && git commit -m "msg"`, the common shape for
  # this harness's Bash tool) inside CD_ARG, and the eval below would then execute
  # that tail for real — including a genuine `git commit` — as a side effect of
  # computing a path. This must stop at the first occurrence, wherever it falls.
  CD_ARG="$(echo "$FIRST_LINE" | sed -E 's/^cd[[:space:]]+//' | sed -E 's/[[:space:]]*[&;|].*$//')"

  # Defense in depth, in case the truncation above ever has its own gap: eval is
  # meant to see nothing but a plain `cd <path>`. Refuse to eval anything that could
  # DO more than that — command substitution, backticks, redirection/process
  # substitution — so a future parsing gap fails CLOSED (falls back to the base
  # directory) instead of reopening this exact class of bug.
  if printf '%s' "$CD_ARG" | grep -qE '\$\(|`|[<>]'; then
    CD_ARG=""
  fi

  if [ -n "$CD_ARG" ]; then
    RESOLVED="$(cd "$BASE_DIR" 2>/dev/null && eval "cd $CD_ARG" 2>/dev/null && pwd)"
    [ -n "$RESOLVED" ] && TARGET_DIR="$RESOLVED"
  fi
fi

REPO_ROOT="$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="$TARGET_DIR"

cd "$REPO_ROOT" || exit 0

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
