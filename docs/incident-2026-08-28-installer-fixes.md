# Installer/hook fixes — 2026-08-28 (from a fresh install)

Four bugs surfaced on a single fresh install (a new peer's macOS host). All are the same
class: an installer step or Stop/commit-gate hook that is **confidently wrong in a way that
blocks work** — and one is a **security** bug. All four are fixed on `main`.

| # | File | Bug | Fix |
|---|------|-----|-----|
| 1 | `setup.sh` (.mcp.json substitution) | `sed -i "expr" file` is GNU-only; on BSD/macOS `-i` consumes the next arg as a backup suffix, so the substitution silently no-ops and `.mcp.json` ships full of `__PLACEHOLDER__`s while the installer reports success. Hits every Mac. | Portable temp-file edit (`sed … > f.tmp && mv f.tmp f`), matching the jq-merge just above. **PR #64** |
| 2 | `setup.sh` (.gitignore appends) | Raw `echo "$x" >> .gitignore` with no trailing-newline guard. On a `.gitignore` whose last line lacked a newline (`.bug-hunt/`), the entry glued on → `.bug-hunt/.claude`: the previous entry stopped being ignored **and `.claude` was never ignored**, exposing `.claude/agent/identity.json` (nsec + mnemonic). | New portable `gi_append()` that guarantees a trailing newline first; used at all three append sites. Regression test `test/gitignore-append.test.sh`. **PR #64** |
| 3 | `claude_conf/hooks/pre-commit-check.sh` | Tested linter **output shape** (`… \| tail -1 \| grep -q '^$'`) instead of **exit status** — a repo whose linter prints a success summary line was treated as failing and **blocked every commit**. | Gate on exit status for npm-lint, cargo-clippy, and go-vet (cargo-fmt / typecheck / gofmt were already correct). **PR #65** |
| 4 | `claude_conf/hooks/remote-sync-check.sh` | Treated a **failed fetch** as *behind*: `git fetch \|\| exit 0` left any stale `pending:true` in place, so an **unreachable remote** (DNS blocked in a sandbox — the *normal* case there) blocked Stop indefinitely with no way to clear it. | A failed fetch now writes `pending:false` + `fetch_ok:false` (never behind) and clears stale pending; only a **successful** fetch can set pending. Regression test `test/remote-sync-fetch-failure.test.sh`. **PR #65** |

## Remediation for any host that ran the pre-fix installer

1. **Get the fixes:** `git pull` in `claude-unicity-setup` (or re-clone). All four are on `main`.
2. **Security check** (bug #2 may have left `.claude` un-ignored):
   ```bash
   cd <your-repo>
   git ls-files | grep '.claude/agent/identity.json'      # tracked now?
   git log --all --oneline -- .claude/agent/identity.json # ever committed?
   ```
   - Nothing prints → clean.
   - Committed/pushed → **rotate the key** (it is compromised): `rm -f .claude/agent/identity.json && ./setup.sh <your-repo>` (mints a fresh keypair), re-redeem a fresh `ut2_…` invite from the coordinator, and if it was pushed, purge it from history (`git filter-repo --path .claude/agent/identity.json --invert-paths` + force-push).
3. **Un-glue the corrupted `.gitignore`** (the fixed installer adds `.claude` correctly but won't repair the old glued line): split `.bug-hunt/.claude` back into `.bug-hunt/` and `.claude` on separate lines.

## Prevention
Each fix ships with a regression test under `test/`. The shared root cause across all four:
**gate on the tool's exit status / real reachability, never on output shape or a best-effort
side effect** — and treat "couldn't determine" as "don't block," not as failure.
