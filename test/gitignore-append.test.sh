#!/usr/bin/env bash
# Regression test for the .gitignore trailing-newline bug.
#
# The installer appended entries with `echo "$x" >> .gitignore`. If the target
# .gitignore had NO trailing newline (last line e.g. ".bug-hunt/"), the entry got
# glued onto that line -> ".bug-hunt/.claude": the previous entry stopped being
# ignored AND ".claude" was never ignored, exposing .claude/agent/identity.json
# (nsec + mnemonic). gi_append() must guarantee a trailing newline first, portably.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SETUP="$HERE/../setup.sh"

# Load ONLY the gi_append function from the installer (don't run the whole thing).
eval "$(sed -n '/^gi_append() {/,/^}/p' "$SETUP")"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GITIGNORE="$tmp/.gitignore"

# The exact trigger: last line has NO trailing newline.
printf 'node_modules/\n.bug-hunt/' > "$GITIGNORE"

gi_append '.mcp.json'
gi_append '.serena/'
gi_append '.claude'

fail=0
check() { grep -qxF "$1" "$GITIGNORE" || { echo "FAIL: '$1' is not on its own line"; fail=1; }; }
check 'node_modules/'
check '.bug-hunt/'   # must NOT have been corrupted into ".bug-hunt/.mcp.json"
check '.mcp.json'
check '.serena/'
check '.claude'      # the security-critical one

# No glued line: nothing should end with one of our entries yet not equal it.
if grep -qE '.+\.(claude|mcp\.json|serena/)$' "$GITIGNORE"; then
  echo "FAIL: an entry was glued onto another line"; fail=1
fi

# Appending onto a file that ALREADY ends with a newline must not add a blank line.
printf 'foo/\n' > "$GITIGNORE"
gi_append '.claude'
if [ -n "$(grep -cxF '' "$GITIGNORE" | grep -v '^0$' || true)" ]; then
  echo "FAIL: introduced a blank line when the file already ended in a newline"; fail=1
fi
grep -qxF '.claude' "$GITIGNORE" || { echo "FAIL: .claude missing on newline-terminated file"; fail=1; }

if [ "$fail" = 0 ]; then
  echo "PASS: gitignore-append newline guard (Mike-host regression)"
else
  echo "gitignore-append test FAILED"; exit 1
fi
