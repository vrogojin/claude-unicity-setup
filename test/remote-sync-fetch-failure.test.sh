#!/usr/bin/env bash
# Regression: a FAILED fetch (unreachable remote / DNS-blocked sandbox — the NORMAL case
# there) must NOT leave Stop blocked. remote-sync-check.sh must write pending:false +
# fetch_ok:false and CLEAR any stale pending:true — never treat "couldn't reach the remote"
# as "you're behind".
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../claude_conf/hooks/remote-sync-check.sh"

repo="$(mktemp -d)"; state="$(mktemp -d)"; th="$(mktemp -d)"
trap 'rm -rf "$repo" "$state" "$th"' EXIT

git -C "$repo" init -q
git -C "$repo" config user.email t@t
git -C "$repo" config user.name t
git -C "$repo" commit -q --allow-empty -m init
git -C "$repo" remote add origin https://nonexistent.invalid.example/repo.git  # fetch WILL fail

cp "$HOOK" "$th/remote-sync-check.sh"
printf 'STATE_DIR="%s"\n' "$state" > "$th/state-dir.sh"   # pin STATE_DIR for the test
# Stale pending:true (as if a prior successful fetch found us behind); old last_fetch so
# the 5-minute cooldown passes and the hook actually re-fetches.
printf '{"last_fetch":1,"pending":true,"main_behind":3}' > "$state/remote-sync.json"

CLAUDE_PROJECT_DIR="$repo" bash "$th/remote-sync-check.sh" <<< '{}' || true

pending=$(jq -r '.pending' "$state/remote-sync.json")
fetch_ok=$(jq -r '.fetch_ok' "$state/remote-sync.json")
if [ "$pending" = "false" ] && [ "$fetch_ok" = "false" ]; then
  echo "PASS: failed fetch -> pending:false, fetch_ok:false (Stop not blocked; stale pending cleared)"
else
  echo "FAIL: pending=$pending fetch_ok=$fetch_ok — an unreachable remote would block Stop"
  exit 1
fi
