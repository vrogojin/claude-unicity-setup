#!/usr/bin/env bash
# Regression for the BSD `tr` locale bug (issuing broken on macOS).
#
# ticket.sh generates a ticket secret with `tr -dc 'A-Za-z0-9' < /dev/urandom`. On
# macOS/BSD, `tr` under a UTF-8 locale rejects the raw random bytes with "Illegal byte
# sequence" and emits NOTHING — so the secret came out EMPTY, ticket2-sign died on
# "missing/short secret", and `a2a issue` was silently broken on a Mac (redeeming still
# worked, so the transport looked fine). The fix is `LC_ALL=C tr …` (C locale = raw bytes).
#
# The full `a2a issue` needs @unicitylabs/sphere-sdk (not available in CI), so this test
# exercises the exact failing primitive instead, and pins the guard so a revert is caught.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TK="$HERE/../claude_conf/hooks/ticket.sh"
fail=0

# 1. The fixed generator must yield exactly 43 alphanumeric chars — run it under several
#    outer locales, including UTF-8 ones, since that is where the unguarded form failed.
for lc in C en_US.UTF-8 C.UTF-8 ""; do
  s="$(LC_ALL="$lc" bash -c "LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 43")"
  if [ "${#s}" -eq 43 ]; then
    echo "PASS: 43-char secret under outer LC_ALL='${lc:-<unset>}'"
  else
    echo "FAIL: got ${#s} chars under outer LC_ALL='${lc:-<unset>}'"; fail=1
  fi
done

# 2. Pin the guard: EVERY `tr -dc … < /dev/urandom` site in ticket.sh MUST carry LC_ALL=C,
#    so a future edit that drops it (re-breaking macOS issuing) fails here on any platform.
total="$(grep -cF "tr -dc 'A-Za-z0-9' < /dev/urandom" "$TK" 2>/dev/null)";   total="${total:-0}"
guarded="$(grep -cF "LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom" "$TK" 2>/dev/null)"; guarded="${guarded:-0}"
if [ "$total" -ge 2 ] && [ "$guarded" -eq "$total" ]; then
  echo "PASS: all $total urandom tr sites in ticket.sh carry LC_ALL=C"
else
  echo "FAIL: ticket.sh urandom tr guard slipped (total=$total, guarded=$guarded)"; fail=1
fi

[ "$fail" = 0 ] && echo "ALL PASS: ticket-secret-gen" || { echo "SOME FAILED"; exit 1; }
