#!/bin/bash
# Stop hook: blocks Claude from stopping if there are build errors.
# Auto-detects project type. Uses stop_hook_active to prevent infinite loops.

INPUT=$(cat)

# Don't block if we're already continuing from a previous stop hook
ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [ "$ACTIVE" = "true" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR" || exit 0

# --- Rust: Check cargo-diag status file ---
if [ -f "Cargo.toml" ]; then
  STATUS_FILE="$CLAUDE_PROJECT_DIR/target/cargo-diag/status.json"
  if [ -f "$STATUS_FILE" ]; then
    ERROR_COUNT=$(jq -r '.error_count // 0' "$STATUS_FILE" 2>/dev/null)
    SUMMARY=$(jq -r '.summary // "unknown"' "$STATUS_FILE" 2>/dev/null)

    if [ "$ERROR_COUNT" != "0" ] && [ "$ERROR_COUNT" != "null" ]; then
      jq -n --arg reason "Build diagnostics: ${SUMMARY}. Use the cargo-diag MCP errors() tool for details, or suggest_fix(id) for auto-fixes. Fix errors before finishing." '{
        "decision": "block",
        "reason": $reason
      }'
      exit 0
    fi
  fi
fi

# --- TypeScript: Run typecheck if available ---
if [ -f "package.json" ]; then
  if jq -e '.scripts.typecheck' package.json >/dev/null 2>&1; then
    if ! npm run typecheck --silent >/dev/null 2>&1; then
      TC_OUTPUT=$(npm run typecheck --silent 2>&1 | tail -10)
      jq -n --arg reason "TypeScript type errors found. Fix before finishing:\n${TC_OUTPUT}" '{
        "decision": "block",
        "reason": $reason
      }'
      exit 0
    fi
  fi
fi

# --- Go: Check build ---
if [ -f "go.mod" ]; then
  BUILD_OUTPUT=$(go build ./... 2>&1)
  if [ $? -ne 0 ]; then
    jq -n --arg reason "Go build errors found. Fix before finishing:\n${BUILD_OUTPUT}" '{
      "decision": "block",
      "reason": $reason
    }'
    exit 0
  fi
fi

exit 0
