#!/usr/bin/env bash
# Regression test for the flock-on-macOS bug.
#
# The hooks serialized JSON read-modify-writes with `flock -w 5 9`. flock(1) does
# NOT exist on macOS/BSD, so on a Mac the fail-closed path (_rc_write) refused every
# coordinated write (blocking ticket redemption), and the best-effort paths silently
# ran UNLOCKED. The fix is `_pflock` (in agent-registry.sh): prefer real flock when
# present, else an atomic mkdir spinlock that auto-releases on subshell exit.
#
# This test forces the mkdir path (PFLOCK_FORCE_MKDIR=1) so it exercises the macOS
# code path even on a Linux CI runner, and asserts genuine mutual exclusion.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AR="$HERE/../claude_conf/hooks/agent-registry.sh"

# shellcheck disable=SC1090
. "$AR" >/dev/null 2>&1
if ! declare -f _pflock >/dev/null 2>&1; then echo "FAIL: _pflock not defined by agent-registry.sh"; exit 1; fi

export PFLOCK_FORCE_MKDIR=1
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# 1. Mutual exclusion: N concurrent locked increments of a counter file must land
#    exactly N. Without a real lock, racing read-modify-write loses updates (< N).
lk="$tmp/lock1"; cnt="$tmp/counter"; printf '0' > "$cnt"
N=8
inc() {
  ( _pflock "$lk" 5 || exit 9
    n="$(cat "$cnt" 2>/dev/null || echo 0)"; n=$((n + 1))
    # widen the race window so an unlocked version would reliably corrupt
    printf '%s' "$n" > "$cnt"
  ) 9>"$lk"
}
i=0; while [ "$i" -lt "$N" ]; do inc & i=$((i + 1)); done
wait
got="$(cat "$cnt")"
if [ "$got" = "$N" ]; then echo "PASS: $N concurrent locked writes -> $got"; else echo "FAIL: count=$got (want $N)"; exit 1; fi

# 2. Auto-release: the lock directory must be gone once the subshell exits.
if [ -d "$lk.d" ]; then echo "FAIL: lockdir $lk.d not released after subshell exit"; exit 1; else echo "PASS: lock auto-released"; fi

# 3. Stale-steal: a lockdir owned by a dead PID must be reclaimable, not a deadlock.
lk2="$tmp/lock2"; mkdir "$lk2.d"; echo 999999 > "$lk2.d/pid"   # PID (almost certainly) not alive
if ( _pflock "$lk2" 3 || exit 1; true ) 9>"$lk2"; then echo "PASS: stole stale lock from dead PID"; else echo "FAIL: could not steal stale lock (deadlock risk)"; exit 1; fi

# 4. Exclusion under a live holder: while one subshell HOLDS the lock, a second acquirer
#    with a short timeout must FAIL to acquire (return non-zero) rather than barge in.
lk3="$tmp/lock3"; res3="$tmp/res3"
( _pflock "$lk3" 30 || exit 1
  # Second acquirer, backgrounded, 2s timeout. It must NOT acquire while we hold the lock.
  ( if _pflock "$lk3" 2; then echo acquired > "$res3"; else echo blocked > "$res3"; fi ) 9>"$lk3" &
  child=$!
  wait "$child" 2>/dev/null
) 9>"$lk3"
if [ "$(cat "$res3" 2>/dev/null)" = blocked ]; then
  echo "PASS: contended acquire correctly blocked while lock held"
else
  echo "FAIL: second acquire got the lock while it was held (got: $(cat "$res3" 2>/dev/null))"; exit 1
fi

echo "ALL PASS: portable-lock"
