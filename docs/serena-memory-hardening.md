# Serena / harness memory hardening

Fixes for a measured, slow-building memory leak in the shared Claude Code harness. Root
cause (diagnosed on a real host, 2026-08-22): **uncapped + orphaned Serena Docker containers
accumulating across Claude Code session restarts**, each holding a full language-server fleet
(tsserver / rust-analyzer / gopls / clangd), compounded by a too-wide bind-mount and an
append-only agent-message state file.

## What changed

### 1. Per-container resource caps (`claude_conf/.mcp.json`)
The Serena `docker run` now carries:
`--memory=4g --memory-swap=4g --pids-limit=256 --label=unicity-serena --init`.

- `--memory` / `--memory-swap` equal ⇒ a hard 4 GB ceiling with **no swap** for the
  container, so a runaway language server can't thrash host swap.
- `--pids-limit=256` bounds a fork storm.
- `--label=unicity-serena` makes containers findable for the reaper.
- `--init` gives Serena a real PID-1 that reaps zombies and forwards signals.

Applies to fresh installs and to `setup.sh --serena-only` re-runs (the template is the source
of truth; the merge path overwrites the `serena` server entry). Existing live deploys pick it
up on the next `setup.sh` run.

### 2. SessionStart orphan-reaper (`claude_conf/hooks/serena-reaper.sh`)
`docker run --rm` only removes the container when the CONTAINER exits — and Serena does not
exit on stdin EOF, so a session that dies uncleanly leaves the container running. The reaper,
wired into `SessionStart`, force-removes a labelled container **only when BOTH**:

1. it is older than the grace window (`SERENA_ORPHAN_MAX_AGE_HOURS`, default **48h**), AND
2. **no live Serena `docker run` client exists for its project** — proven by scanning `/proc`
   for live processes whose argv contains the Serena image ref (`unicity/serena`; only the
   `docker run` client's argv carries it, never the in-container language servers) and
   collecting their `--project` dirs. A container whose `--project` is in that live set is
   KEPT.

**Provable safety.** We never kill a container a live session could be using: a live client
for the project ⇒ keep; and the 48h grace independently protects this session's own fresh
container even during the startup race where its client isn't yet visible in `/proc`. Because
every `docker run --rm` makes a NEW container, any ≥48h container is necessarily from an
earlier client — never the current session's. The tradeoff is deliberately conservative: we
would rather leak an orphan (bounded by the memory cap above) than risk killing a live one.

Escape hatch `SERENA_REAPER_DISABLE=1`; `serena-reaper.sh list` dry-runs (prints candidates,
removes nothing). Covered by `test/serena-reaper.test.sh` (fake docker + `/proc` scan).

### 3. Narrower default mount (`setup.sh`)
The Serena read-only mount default changed from `dirname "$TARGET_DIR"` (which for
`/home/<user>/<repo>` mounted the ENTIRE home dir — language servers then roamed every sibling
repo, one tsserver/rust-analyzer/… per repo) to **the target repo itself**. Worktrees created
UNDER the project (`<repo>/.claude/worktrees/<name>`) stay visible.

For a deliberate multi-repo workspace, set `SERENA_WORKSPACE_ROOT` to the shared parent
explicitly — and the `--memory`/`--pids-limit` caps then bound whatever breadth is mounted.

### 4. Bounded agent-message state (`agent-comms-check.sh`, `on-dm.sh`, `on-group-message.sh`, `classify-inbound.sh`)
`agent-messages.json` was append-only (`.messages += …`, no trim) — it grew to MBs and made
`classify-inbound.sh` re-parse the whole file per index in an O(messages²) loop (~30s ingest
timeouts). Now:

- every merge trims `.messages` to the newest **N** (`AGENT_MESSAGES_MAX`, default **500**);
- `classify-inbound.sh` extracts the unclassified messages in a **single** `jq` pass (fed on
  fd 3 so body commands keep the caller's stdin) instead of re-reading the file per index.
  Trimmed-off messages are already classified/acted-on, and the authorization logic is
  unchanged (owner→owner, unknown→pending default-deny, classified untouched).

## Tunables
| Env | Default | Effect |
|---|---|---|
| `SERENA_ORPHAN_MAX_AGE_HOURS` | 48 | reaper grace window |
| `SERENA_REAPER_DISABLE` | 0 | `1` disables the reaper |
| `SERENA_WORKSPACE_ROOT` | target repo | broaden the Serena mount (multi-repo) |
| `AGENT_MESSAGES_MAX` | 500 | retained agent-message history |
