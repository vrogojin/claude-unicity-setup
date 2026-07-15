#!/bin/bash
# PreToolUse hook: steers code search from the native Grep tool to Serena's
# semantic (symbol-aware) tools. Documentation alone doesn't stick — agents drift
# back to grep — so this enforces the preference deterministically, the same way
# branch-guard.sh enforces the branching rule.
#
# Grep is ALLOWED for genuinely non-code text (logs, *.md, JSON, YAML, configs).
# Code-symbol / code-regex searches are BLOCKED with a redirect to Serena.
#
# Escape hatches (so this never traps you):
#   - Give Grep a non-code glob (e.g. glob:"*.md", glob:"*.json") → passes through.
#   - Export CLAUDE_PREFER_SERENA=0 → disables this hook entirely.
#   - Auto-disabled when Docker is unavailable (Serena can't run, so grep is all
#     you have).

INPUT=$(cat)

# --- Kill switch -------------------------------------------------------------
[ "${CLAUDE_PREFER_SERENA:-1}" = "0" ] && exit 0

# --- If Serena can't run, never block the only search tool -------------------
# Serena runs in Docker; no Docker means no Serena, so let grep through.
command -v docker >/dev/null 2>&1 || exit 0

GLOB=$(printf '%s' "$INPUT" | jq -r '.tool_input.glob // ""')
TYPE=$(printf '%s' "$INPUT" | jq -r '.tool_input.type // ""')
GPATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.path // ""')

# ripgrep --type names that are non-code → grep is the right tool
case "$TYPE" in
  md|markdown|json|yaml|yml|toml|txt|text|log|html|xml|config|csv|css|svg)
    exit 0 ;;
esac

# Non-code extensions / paths where grep is legitimately the right tool.
NONCODE_RE='\.(md|markdown|mdx|txt|text|log|json|jsonc|ya?ml|toml|lock|env|ini|cfg|conf|csv|tsv|html?|xml|rst|svg|properties)$|(^|/)(docs?|logs?|\.github|fixtures?|testdata|node_modules|dist|build|coverage)(/|$)|package(-lock)?\.json|yarn\.lock|pnpm-lock\.yaml|go\.(mod|sum)|Cargo\.(toml|lock)|(^|/)(CHANGELOG|README|LICENSE)'

if printf '%s' "$GLOB"  | grep -Eiq "$NONCODE_RE"; then exit 0; fi
if printf '%s' "$GPATH" | grep -Eiq "$NONCODE_RE"; then exit 0; fi

# --- Otherwise: this is a code search → redirect to Serena -------------------
read -r -d '' REASON <<'EOF'
Prefer Serena over grep for code search — it is semantic (symbol-aware) and far
cheaper than scanning raw text. Use the Serena MCP tools instead:

  • Find a symbol by name (class/function/method/var):  mcp__serena__find_symbol
  • Find all callers / usages of a symbol:              mcp__serena__find_referencing_symbols
  • Regex / string search across the codebase:          mcp__serena__search_for_pattern
  • Overview of what a file defines:                    mcp__serena__get_symbols_overview
  • Jump to a definition / implementations:             mcp__serena__find_declaration, mcp__serena__find_implementations

grep/Grep is reserved for NON-code text. If you truly are searching non-code
(logs, *.md, JSON, YAML, configs), restrict the Grep with a matching glob —
e.g. glob:"*.md" or glob:"*.json" — and it will be allowed.
EOF

jq -n --arg reason "$REASON" '{
  "decision": "block",
  "reason": $reason
}'
exit 0
