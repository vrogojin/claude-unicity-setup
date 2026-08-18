#!/bin/bash
# housekeeping.test.sh — hermetic proof of the F3 nightly-sweep machinery
# (Group D: sweep-worktree.sh §5.2, sweep-scope.sh §5.4.1, sweep-post.sh §5.4
# post-phase + §5.6 report). No network, no real gh/claude: a scratch git repo
# with a bare "origin" is the fixture; gh is mocked on PATH; the model session is
# NOT run — sweep-post.sh is driven directly with a synthesized hand-off and
# SWEEP_TEST_CMD forcing the green check. STATE_DIR + sweep HOME are sandboxed.
#
# Run:  bash test/housekeeping.test.sh
set -uo pipefail

FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }
chk()  { if eval "$2"; then pass "$1"; else fail "$1 — [$2]"; fi; }

REPO_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTO_SRC="$REPO_SRC/claude_conf/hooks/automation"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hk.XXXXXX")"
export HOME="$TMP/home"; mkdir -p "$HOME"
export AUTOMATION_STATE_DIR="$TMP/state"; mkdir -p "$AUTOMATION_STATE_DIR"
export SWEEP_HOME="$TMP/sweeps"
trap 'rm -rf "$TMP"' EXIT

WT_SH="$AUTO_SRC/sweep-worktree.sh"
SCOPE_SH="$AUTO_SRC/sweep-scope.sh"
POST_SH="$AUTO_SRC/sweep-post.sh"

# --- mock gh on PATH: pr create → fake URL; api/label/others → ok --------------
mkdir -p "$TMP/bin"; export PATH="$TMP/bin:$PATH"
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$GH_CALLS"
case "$1 $2" in
  "pr create") echo "https://github.com/o/r/pull/42" ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"
export GH_CALLS="$TMP/gh-calls.log"; : > "$GH_CALLS"

# --- build a scratch repo with a bare origin on main --------------------------
mk_repo() {
  rm -rf "$TMP/origin.git" "$TMP/repo"
  # clear per-run state so one test can't inherit another's hand-off/marker
  rm -rf "$AUTOMATION_STATE_DIR/automation/housekeeping/handoff" \
         "$AUTOMATION_STATE_DIR/automation/housekeeping/last-sweep.json" 2>/dev/null
  git init -q --bare "$TMP/origin.git"
  git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
  cd "$TMP/repo" || return 1
  git config user.email t@t; git config user.name t
  printf '.claude/\n' > .gitignore
  mkdir -p backend/src backend/test docs
  printf 'export function f(){ return 1 }\n' > backend/src/app.ts
  printf '# docs\n' > docs/readme.md
  mkdir -p .claude/agent .claude/hooks
  cp -r "$REPO_SRC/claude_conf/hooks/." .claude/hooks/ 2>/dev/null
  printf 'PRIVATE_IDENTITY_SECRET\n' > .claude/agent/identity.json
  printf '%s\n' '{"automation":{"housekeeping":{"scope_days":30,"max_items":3,"max_diff_lines":400,"max_prs":3}}}' > .claude/agent/config.json
  git add -A; git commit -qm "chore: base"
  git push -q origin HEAD:main
  git fetch -q origin
}

# make N benign committed changes on the sweep branch, each a theme commit
commit_theme() { # <wt> <theme> <relpath> <content>
  local wt="$1" theme="$2" rel="$3" content="$4"
  mkdir -p "$wt/$(dirname "$rel")"
  printf '%s\n' "$content" >> "$wt/$rel"
  git -C "$wt" add -A
  git -C "$wt" commit -q -m "refactor($theme): change" -m "Sweep-Theme: $theme"
}

write_handoff() { # <handoff-dir> <themes-json>
  mkdir -p "$1"; printf '%s' "$2" > "$1/themes.json"
  printf 'pass-with-notes\n' > "$1/steelman-verdict.txt"
}

echo "== T0: scripts parse (bash -n) =="
for f in sweep-worktree.sh sweep-scope.sh sweep-post.sh run-job.sh; do
  chk "bash -n $f" "bash -n '$AUTO_SRC/$f'"
done

echo "== T1: worktree create — branch, base, .claude minus agent =="
mk_repo
export SWEEP_DATE=20260101
WT="$(bash "$WT_SH" create "$TMP/repo")"
chk "create prints a worktree path"      "[ -n \"$WT\" ] && [ -d \"$WT\" ]"
chk "branch is sweep/<date>"             "[ \"\$(git -C \"$WT\" rev-parse --abbrev-ref HEAD)\" = sweep/20260101 ]"
chk "based on origin/main"               "[ \"\$(git -C \"$WT\" rev-parse HEAD)\" = \"\$(git -C \"$TMP/repo\" rev-parse origin/main)\" ]"
chk ".claude materialized in worktree"   "[ -d \"$WT/.claude/hooks\" ]"
chk "agent/ EXCLUDED from worktree"      "[ ! -e \"$WT/.claude/agent\" ]"
chk "no identity secret leaked"          "[ ! -e \"$WT/.claude/agent/identity.json\" ]"

echo "== T2: collision → second create exits 3 (skip, not stack) =="
bash "$WT_SH" create "$TMP/repo" >/dev/null 2>&1
chk "second create exit 3" "[ \$? -eq 3 ]"

echo "== T3: prune removes >7d sweep dirs, keeps fresh =="
OLD="$SWEEP_HOME/$(bash "$WT_SH" slug "$TMP/repo")/19990101"
mkdir -p "$OLD"; touch -d '30 days ago' "$OLD"
bash "$WT_SH" prune "$TMP/repo"
chk "ancient sweep dir pruned"  "[ ! -e \"$OLD\" ]"
chk "fresh worktree survives prune" "[ -d \"$WT\" ]"

echo "== T4: marker write/read + scope range floor =="
BASE_SHA="$(git -C "$TMP/repo" rev-parse origin/main)"
bash "$WT_SH" marker-write "$TMP/repo" "$BASE_SHA"
chk "marker-read returns the sha" "[ \"\$(bash \"$WT_SH\" marker-read \"$TMP/repo\")\" = \"$BASE_SHA\" ]"
# add a new commit to origin so scope has a range above the marker
( cd "$TMP/repo" && printf 'x\n' >> backend/src/app.ts && git commit -qam "feat(backend): more" && git push -q origin HEAD:main && git fetch -q origin )
SCOPE_OUT="$(bash "$SCOPE_SH" "$TMP/repo")"
chk "scope emits valid JSON"          "echo '$SCOPE_OUT' | jq -e '.themes|type==\"array\"' >/dev/null"
chk "scope range floors at marker"    "echo '$SCOPE_OUT' | jq -e '.range.from==\"$BASE_SHA\"' >/dev/null"
chk "scope found the backend theme"   "echo '$SCOPE_OUT' | jq -e '[.themes[].theme]|index(\"backend/src\")!=null' >/dev/null"
# clean the leftover T1 worktree before secret/clean runs
bash "$WT_SH" destroy "$WT" >/dev/null 2>&1

echo "== T5: SECRET-SCAN corpus — every planted secret ABORTS the push =="
SECRETS=(
  "AKIAIOSFODNN7EXAMPLE"
  "ghp_0123456789012345678901234567890123"
  "-----BEGIN RSA PRIVATE KEY-----"
  "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
)
i=0
for sec in "${SECRETS[@]}"; do
  i=$((i+1)); export SWEEP_DATE="2026020$i"
  mk_repo
  WTS="$(bash "$WT_SH" create "$TMP/repo")"
  commit_theme "$WTS" "backend/src" "backend/src/leak.ts" "const k = \"$sec\""
  write_handoff "$AUTOMATION_STATE_DIR/automation/housekeeping/handoff" '[{"theme":"backend/src","what_why":"x","status":"shipped"}]'
  SWEEP_TEST_CMD=true SWEEP_GH_BIN="$TMP/bin/gh" bash "$POST_SH" "$WTS" "$TMP/repo" >/dev/null 2>&1
  rc=$?
  chk "secret #$i ($sec…) → exit 21" "[ $rc -eq 21 ]"
  chk "secret #$i → NOTHING pushed"  "[ -z \"\$(git -C \"$TMP/repo\" ls-remote origin \"refs/heads/sweep/2026020$i\" 2>/dev/null)\" ]"
  chk "secret #$i → report says secret detected" "grep -qi 'secret' \"$AUTOMATION_STATE_DIR/automation/housekeeping/report-2026020$i.md\""
done
# .env file addition is a secret-bearing path
export SWEEP_DATE=20260209; mk_repo
WTS="$(bash "$WT_SH" create "$TMP/repo")"
mkdir -p "$WTS"; printf 'API_KEY=zzz\n' > "$WTS/.env"; git -C "$WTS" add -f .env
git -C "$WTS" commit -q -m "chore: env" -m "Sweep-Theme: backend/src"
write_handoff "$AUTOMATION_STATE_DIR/automation/housekeeping/handoff" '[{"theme":"backend/src","what_why":"x","status":"shipped"}]'
SWEEP_TEST_CMD=true SWEEP_GH_BIN="$TMP/bin/gh" bash "$POST_SH" "$WTS" "$TMP/repo" >/dev/null 2>&1
chk ".env addition → exit 21"        "[ \$? -eq 21 ]"
chk ".env addition → not pushed"     "[ -z \"\$(git -C \"$TMP/repo\" ls-remote origin refs/heads/sweep/20260209 2>/dev/null)\" ]"

echo "== T6: clean sweep → push + PR + report + artifacts + destroy =="
export SWEEP_DATE=20260301; mk_repo
WTC="$(bash "$WT_SH" create "$TMP/repo")"
commit_theme "$WTC" "backend/src" "backend/src/app.ts" "// tidy: extract helper"
write_handoff "$AUTOMATION_STATE_DIR/automation/housekeeping/handoff" \
  '[{"theme":"backend/src","what_why":"extracted duplicated retry helper","residual_risks":["none"],"skipped_tests":["e2e: needs creds"],"status":"shipped"}]'
: > "$GH_CALLS"
SWEEP_TEST_CMD=true SWEEP_GH_BIN="$TMP/bin/gh" bash "$POST_SH" "$WTC" "$TMP/repo" >/dev/null 2>&1
chk "clean sweep → exit 0"                "[ \$? -eq 0 ]"
RPT="$AUTOMATION_STATE_DIR/automation/housekeeping/report-20260301.md"
chk "morning-review report written"       "[ -f \"$RPT\" ]"
chk "report front-loads accept=merge PR"  "grep -q 'Accept = merge PR #42' \"$RPT\""
chk "report has the what/why one-liner"   "grep -q 'extracted duplicated retry helper' \"$RPT\""
chk "report lists steelman verdict"       "grep -qi 'pass-with-notes' \"$RPT\""
chk "gh pr create was invoked"            "grep -q 'pr create' \"$GH_CALLS\""
chk "PR labeled sweep:auto"               "grep -q 'sweep:auto' \"$GH_CALLS\""
chk "PR body prepended via gh api PATCH"  "grep -q 'api -X PATCH' \"$GH_CALLS\""
chk "branch pushed to origin"             "[ -n \"\$(git -C \"$TMP/repo\" ls-remote origin refs/heads/sweep/20260301 2>/dev/null)\" ]"
ART="$AUTOMATION_STATE_DIR/automation/housekeeping/artifacts.json"
chk "artifacts.json has PR url"           "jq -e 'index(\"https://github.com/o/r/pull/42\")!=null' \"$ART\" >/dev/null"
chk "artifacts.json has report path"      "jq -e 'index(\"$RPT\")!=null' \"$ART\" >/dev/null"
chk "worktree destroyed after PR"         "[ ! -d \"$WTC\" ]"
chk "marker advanced to swept sha"        "[ \"\$(bash \"$WT_SH\" marker-read \"$TMP/repo\")\" = \"\$(git -C \"$TMP/repo\" rev-parse origin/main)\" ]"

echo "== T7: RED final tests → abort, no PR =="
export SWEEP_DATE=20260401; mk_repo
WTR="$(bash "$WT_SH" create "$TMP/repo")"
commit_theme "$WTR" "backend/src" "backend/src/app.ts" "// change"
write_handoff "$AUTOMATION_STATE_DIR/automation/housekeeping/handoff" '[{"theme":"backend/src","what_why":"x","status":"shipped"}]'
SWEEP_TEST_CMD=false SWEEP_GH_BIN="$TMP/bin/gh" bash "$POST_SH" "$WTR" "$TMP/repo" >/dev/null 2>&1
chk "red tests → exit 20"           "[ \$? -eq 20 ]"
chk "red tests → not pushed"        "[ -z \"\$(git -C \"$TMP/repo\" ls-remote origin refs/heads/sweep/20260401 2>/dev/null)\" ]"
chk "red tests → report ❌"         "grep -q 'tests red' \"$AUTOMATION_STATE_DIR/automation/housekeeping/report-20260401.md\""

echo "== T8: diff-cap drops the LARGEST theme (never truncates) =="
export SWEEP_DATE=20260501; mk_repo
# tiny cap so a big theme must be dropped
( cd "$TMP/repo" && jq '.automation.housekeeping.max_diff_lines=3' .claude/agent/config.json > c && mv c .claude/agent/config.json )
WTD="$(bash "$WT_SH" create "$TMP/repo")"
commit_theme "$WTD" "docs" "docs/readme.md" "one small line"
big="$(printf 'l%s\n' 1 2 3 4 5 6 7 8 9 10)"
commit_theme "$WTD" "backend/src" "backend/src/big.ts" "$big"
write_handoff "$AUTOMATION_STATE_DIR/automation/housekeeping/handoff" \
  '[{"theme":"docs","what_why":"tiny","status":"shipped"},{"theme":"backend/src","what_why":"huge","status":"shipped"}]'
SWEEP_TEST_CMD=true SWEEP_GH_BIN="$TMP/bin/gh" bash "$POST_SH" "$WTD" "$TMP/repo" >/dev/null 2>&1
chk "diff-cap sweep still exits 0"  "[ \$? -eq 0 ]"
git -C "$TMP/repo" fetch -q origin sweep/20260501 2>/dev/null
DCAP_FILES="$(git -C "$TMP/repo" diff --name-only origin/main...FETCH_HEAD 2>/dev/null)"
chk "large theme reverted (big.ts NOT in pushed net diff)" "! printf '%s' \"$DCAP_FILES\" | grep -q big.ts"
chk "small theme survived (readme IN pushed net diff)"     "printf '%s' \"$DCAP_FILES\" | grep -q readme.md"
chk "report notes the dropped theme" \
  "grep -qi 'diff-cap' \"$AUTOMATION_STATE_DIR/automation/housekeeping/report-20260501.md\""

echo "== T9: nothing shipped → ❌ report, no PR, exit 10 =="
export SWEEP_DATE=20260601; mk_repo
WTN="$(bash "$WT_SH" create "$TMP/repo")"   # no commits on top of origin/main
SWEEP_TEST_CMD=true SWEEP_GH_BIN="$TMP/bin/gh" bash "$POST_SH" "$WTN" "$TMP/repo" >/dev/null 2>&1
chk "nothing shipped → exit 10"     "[ \$? -eq 10 ]"
chk "nothing shipped → report ❌"   "grep -q 'nothing shipped' \"$AUTOMATION_STATE_DIR/automation/housekeeping/report-20260601.md\""
chk "nothing shipped → no push"     "[ -z \"\$(git -C \"$TMP/repo\" ls-remote origin refs/heads/sweep/20260601 2>/dev/null)\" ]"

echo "== T10: branch guard — refuse a non-sweep branch =="
export SWEEP_DATE=20260701; mk_repo
WTG="$(bash "$WT_SH" create "$TMP/repo")"
git -C "$WTG" switch -C notsweep >/dev/null 2>&1
SWEEP_TEST_CMD=true SWEEP_GH_BIN="$TMP/bin/gh" bash "$POST_SH" "$WTG" "$TMP/repo" >/dev/null 2>&1
chk "non-sweep branch → exit 20 (refused)" "[ \$? -eq 20 ]"

echo "== T11: UNTRAILERED commit → hand-off anomaly (exit 11), NOTHING pushed, worktree LEFT =="
export SWEEP_DATE=20260801; mk_repo
WTU="$(bash "$WT_SH" create "$TMP/repo")"
printf '// tidy\n' >> "$WTU/backend/src/app.ts"
git -C "$WTU" add -A; git -C "$WTU" commit -q -m "refactor: no trailer"   # <-- NO Sweep-Theme trailer
write_handoff "$AUTOMATION_STATE_DIR/automation/housekeeping/handoff" '[]'
SWEEP_TEST_CMD=true SWEEP_GH_BIN="$TMP/bin/gh" bash "$POST_SH" "$WTU" "$TMP/repo" >/dev/null 2>&1
chk "untrailered commit → exit 11"          "[ \$? -eq 11 ]"
chk "untrailered commit → NOTHING pushed"   "[ -z \"\$(git -C \"$TMP/repo\" ls-remote origin refs/heads/sweep/20260801 2>/dev/null)\" ]"
chk "untrailered commit → worktree LEFT (surface, don't destroy)" "[ -d \"$WTU\" ]"
chk "untrailered commit → marker NOT advanced" "[ \"\$(bash \"$WT_SH\" marker-read \"$TMP/repo\")\" != \"\$(git -C \"$TMP/repo\" rev-parse origin/main)\" ]"
bash "$WT_SH" destroy "$WTU" >/dev/null 2>&1

echo "== T12: secret ONLY in the model's what_why prose → caught (exit 21) =="
export SWEEP_DATE=20260802; mk_repo
WTP="$(bash "$WT_SH" create "$TMP/repo")"
commit_theme "$WTP" "backend/src" "backend/src/app.ts" "// clean change"
write_handoff "$AUTOMATION_STATE_DIR/automation/housekeeping/handoff" \
  '[{"theme":"backend/src","what_why":"pasted a key AKIAIOSFODNN7EXAMPLE into the note","status":"shipped"}]'
SWEEP_TEST_CMD=true SWEEP_GH_BIN="$TMP/bin/gh" bash "$POST_SH" "$WTP" "$TMP/repo" >/dev/null 2>&1
chk "secret in PR-body prose → exit 21"     "[ \$? -eq 21 ]"
chk "secret in prose → NOTHING pushed"      "[ -z \"\$(git -C \"$TMP/repo\" ls-remote origin refs/heads/sweep/20260802 2>/dev/null)\" ]"

echo "== T13: diff-cap revert CONFLICT → clean abort (exit 30), no push, tree not mid-revert =="
export SWEEP_DATE=20260803; mk_repo
( cd "$TMP/repo" && jq '.automation.housekeeping.max_diff_lines=1' .claude/agent/config.json > c && mv c .claude/agent/config.json )
WTX="$(bash "$WT_SH" create "$TMP/repo")"
# alpha is the LARGER (older) theme; beta later rewrites alpha's lines. diff-cap
# drops the largest (alpha) FIRST → reverting the older commit whose lines beta
# changed → merge conflict on revert → must clean-abort, not push a dirty branch.
printf 'L1\nL2\nL3\n' > "$WTX/backend/src/shared.ts"
printf 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n' > "$WTX/backend/src/big.ts"
git -C "$WTX" add -A; git -C "$WTX" commit -q -m "theme A (large)" -m "Sweep-Theme: alpha"
printf 'L1-x\nL2-x\nL3-x\n' > "$WTX/backend/src/shared.ts"; git -C "$WTX" add -A
git -C "$WTX" commit -q -m "theme B" -m "Sweep-Theme: beta"
write_handoff "$AUTOMATION_STATE_DIR/automation/housekeeping/handoff" \
  '[{"theme":"alpha","what_why":"a","status":"shipped"},{"theme":"beta","what_why":"b","status":"shipped"}]'
SWEEP_TEST_CMD=true SWEEP_GH_BIN="$TMP/bin/gh" bash "$POST_SH" "$WTX" "$TMP/repo" >/dev/null 2>&1
rc=$?
chk "revert conflict → exit 30 (clean abort)"    "[ $rc -eq 30 ]"
chk "revert conflict → NOTHING pushed"           "[ -z \"\$(git -C \"$TMP/repo\" ls-remote origin refs/heads/sweep/20260803 2>/dev/null)\" ]"
chk "revert conflict → tree NOT left mid-revert"  "[ ! -e \"$WTX/.git\" ] || ! git -C \"$WTX\" rev-parse -q --verify REVERT_HEAD >/dev/null 2>&1"
bash "$WT_SH" destroy "$WTX" >/dev/null 2>&1

echo "== T14: collision scoping — a human sweep/* worktree ELSEWHERE does NOT wedge the job =="
export SWEEP_DATE=20260901; mk_repo
HUMANWT="$TMP/human-sweep"
git -C "$TMP/repo" worktree add -b sweep/human-experiment "$HUMANWT" >/dev/null 2>&1   # human's own sweep/* checkout, OUTSIDE our base dir
WTH="$(bash "$WT_SH" create "$TMP/repo" 2>/dev/null)"; rc=$?
chk "human sweep/* elsewhere → create still succeeds (rc 0)" "[ $rc -eq 0 ] && [ -d \"$WTH\" ]"
git -C "$TMP/repo" worktree remove --force "$HUMANWT" >/dev/null 2>&1
bash "$WT_SH" destroy "$WTH" >/dev/null 2>&1

echo
if [ "$FAIL" = 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit "$FAIL"
