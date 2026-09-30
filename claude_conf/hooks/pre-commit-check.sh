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
# If the command's first line leads with `cd <path>`, resolve it WITHOUT ever handing
# the extracted text back to the shell parser (no `eval`). Three eval-based attempts
# at this were each found to execute arbitrary content as a side effect of computing
# a path — a trailing real command after `&&`/`;`/`|`, a bare `&` the separator list
# didn't cover, and then command/backtick/process substitution (`$(...)`, `` `...` ``,
# `<(...)`), which need no separator at all to run. `eval` cannot be made safe here by
# enumerating more separators; the fix is to never call it. Instead: extract only a
# plain-path-shaped token, expand the one or two things a real `cd` argument
# legitimately needs (`~`, a single `$VAR`) via bash's OWN parameter expansion rather
# than re-parsing text as code, whitelist the result, and pass it to `cd --` — which,
# unlike eval, treats its argument as inert data and can never turn it back into
# shell syntax, however it's spelled.
BASE_DIR="$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)"
[ -n "$BASE_DIR" ] || BASE_DIR="$CLAUDE_PROJECT_DIR"

TARGET_DIR="$BASE_DIR"
FIRST_LINE="$(printf '%s\n' "$COMMAND" | head -1)"
if echo "$FIRST_LINE" | grep -qE '^cd[[:space:]]'; then
  # Best-effort isolation of the argument: truncate at the FIRST '&', ';' or '|' (one
  # class, so it also catches the first char of '&&'/'||') rather than one anchored at
  # the end of the line, so an ordinary single-line compound command
  # (`cd apps/web && <rest>`) doesn't leave the rest of the line in CD_ARG. This step
  # is no longer the security boundary — the whitelist below is — so a gap here now
  # fails CLOSED (the leftover text won't pass the whitelist) instead of executing.
  CD_ARG="$(echo "$FIRST_LINE" | sed -E 's/^cd[[:space:]]+//' | sed -E 's/[[:space:]]*[&;|].*$//; s/[[:space:]]+$//')"

  # ~ expansion — only a bare leading '~' or '~/...'.
  case "$CD_ARG" in
    "~") CD_ARG="$HOME" ;;
    "~/"*) CD_ARG="$HOME/${CD_ARG#\~/}" ;;
  esac

  # A single $VAR or ${VAR} reference at the very start, resolved via bash's own
  # indirect parameter expansion (${!name}) after validating the NAME is a real
  # identifier — never by handing the text to eval/the shell parser. The variable's
  # VALUE is used as plain data below; it is never re-interpreted as code, so it
  # cannot smuggle a second command however it's spelled.
  if [[ "$CD_ARG" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(.*)$ ]]; then
    CD_ARG="${!BASH_REMATCH[1]:-}${BASH_REMATCH[2]}"
  fi

  # A bare '-' is bash's own "go to $OLDPWD" idiom, not a path — an entirely benign
  # `cd -` as the first line (nothing adversarial about it) passes the whitelist
  # below (a hyphen is a whitelisted character) and reaches `cd -- "$CD_ARG"`, but
  # bash's cd builtin still special-cases a lone '-' even after `--`: it both jumps
  # to $OLDPWD AND echoes the new path to stdout. That stray echo lands inside
  # RESOLVED alongside the subsequent `pwd`, producing a two-line, embedded-newline
  # "directory" that no `git -C` can resolve — REPO_ROOT falls back to that same
  # garbled value, the final `cd "$REPO_ROOT"` fails, and the WHOLE hook silently
  # exits 0, skipping every check. Reject it explicitly before it ever reaches `cd`.
  if [ "$CD_ARG" = "-" ]; then
    CD_ARG=""
  fi

  # Final whitelist: after expansion, CD_ARG must look like a plain path — reject
  # anything else (command/process substitution, backticks, stray operators, quotes,
  # a leftover unexpanded '$') rather than trying to enumerate every dangerous
  # construct. `cd --` below cannot re-parse its argument as shell syntax regardless,
  # but this also stops a malformed extraction from resolving somewhere unintended.
  if [[ "$CD_ARG" =~ ^[A-Za-z0-9_./-]+$ ]]; then
    RESOLVED="$(cd "$BASE_DIR" 2>/dev/null && cd -- "$CD_ARG" 2>/dev/null && pwd)"
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
