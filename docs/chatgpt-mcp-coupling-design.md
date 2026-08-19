# ChatGPT ⇄ Claude Code Coupling — MCP Bridge Design

**Status:** DESIGN (nothing here is implemented; see §9 for the work breakdown)
**Scope:** couple a running Claude Code session/project with an OpenAI ChatGPT
session, packaged as a framework feature every project gets via `setup.sh`
**Safety posture:** default-OFF, read-mostly curated tool surface, no remote
exec/write ever exposed to the external model, everything mutating routes
through the live session as an owner-approved proposal, kill-switches at every
layer, ChatGPT traffic is UNTRUSTED input.

---

## 0. Summary and owner decisions

**The owner's hypothesis — "Claude Code exposes its own MCP server; ChatGPT
connects as the client" — is CONFIRMED in direction and REFINED in mechanism.**

- **Direction is forced, not chosen.** ChatGPT today can only be an MCP
  *client* (developer-mode connectors, and the Responses API / Agents SDK
  `mcp` tool). There is no surface by which ChatGPT acts as an MCP *server*
  that Claude Code could dial into. So the Claude Code side must serve.
- **Mechanism must change.** The obvious implementation — `claude mcp serve`
  behind a tunnel — is **rejected** (§4.1): it exposes raw
  `Bash/Read/Write/Edit` (arbitrary remote code execution for a third-party
  model), effectively requires `--dangerously-skip-permissions` because server
  mode is headless, and it does **not** couple to the live session anyway
  (each connection spawns a fresh, stateless headless instance).
- **Recommended path (§4.2): a small curated broker MCP server —
  "gptbridge"** — shipped by the framework, speaking stateless Streamable
  HTTP on localhost, exposed via a `cloudflared` quick tunnel, presenting a
  hard-vocabulary toolset: read-only project inspection, a sandboxed
  `ask_claude` consult (headless `claude -p`, read-only tools), and a
  `send_to_session` mailbox that lands in the live session through the
  existing work-item/Stop-gate machinery as an owner-approved proposal.
  Modeled directly on the concierge MCP + delegated-agent-grant posture
  (concierge `mcp/src/main.ts`, `backend/src/agent-grants/grants.ts`, PR #582).

| Property | Value |
|---|---|
| Server side | Claude Code host (framework broker), **not** raw `claude mcp serve` |
| Client side | ChatGPT (developer-mode connector) and/or OpenAI Responses API `mcp` tool |
| Transport | Streamable HTTP (stateless JSON mode), localhost bind, HTTPS via tunnel |
| Auth | Capability-URL path token (rotated per start) + optional `Authorization: Bearer` for API clients; OAuth 2.1 = phase 2 |
| Tool surface | Read-only inspection + `ask_claude` consult + `send_to_session` mailbox — **no Bash, no Write, no Edit, ever** |
| Default | **OFF.** `setup.sh` installs plumbing, enables nothing |

### 0.1 OWNER DECISIONS (explicit sign-off needed)

Recommendations are marked ★.

| # | Decision | Options | Recommendation |
|---|---|---|---|
| OD-A | **Auth for the ChatGPT-UI path.** ChatGPT's connector dialog supports only OAuth or *no auth* — there is **no static bearer/API-key field** (§2.1). | (a) ★ capability-URL: 128-bit+ secret in the URL path, minted per bridge start, connector registered "no auth"; (b) full OAuth 2.1 authorization server on the bridge; (c) skip the ChatGPT UI, support only Responses-API clients (which *do* send bearer headers) | **(a)** for v1 — it is the only *easy* option the ChatGPT UI permits; combined with per-start rotation, TTL auto-stop, localhost bind and the read-mostly toolset the residual risk is acceptable. (b) is the correct end-state and is ticketed as phase 2 (E2). Be explicit: **this is the one place "easy" genuinely trades against the fence** (§8.7). |
| OD-B | **Default toolset tier** | (a) `read` only; (b) `read+consult`; (c) ★ `read+consult+mailbox` | **(c)** — the mailbox is the actual session *coupling* and it is the safest write-shaped thing here (it writes only a quarantined proposal file the owner approves in-session). Each tier is a config value; dropping to (a) is one line. |
| OD-C | **Exposure mode** | (a) ★ `cloudflared` quick tunnel (ephemeral random `trycloudflare.com` URL, zero account, dies with the process); (b) named Cloudflare tunnel on an owned domain (stable URL, CF account + DNS); (c) none (localhost only, for a locally-run Agents-SDK client) | **(a)** for v1. Ephemerality is a *feature*: the URL (which embeds reachability) rotates every start. Note Cloudflare flags quick tunnels as for testing, 200-concurrent cap, and **no SSE** — fine, we use Streamable HTTP JSON mode. (b) is a documented alternative for teams that want a stable connector entry. |
| OD-D | **`ask_claude` permission envelope** | (a) ★ read-only allowlist (`Read/Grep/Glob/LS` class tools only, no Bash/Write/Edit/WebFetch), capped turns/wall-time; (b) plan-mode headless | **(a)** — plan mode still permits broad tool access in some configurations; an explicit allowlist is auditable and testable. |
| OD-E | **Mailbox directionality** | (a) ★ one-way in v1: ChatGPT proposes → owner sees it in the live session (Stop gate / `/check-messages`) and decides; replies travel back through the human; (b) bidirectional: Claude session answers into a reply queue the broker serves back to ChatGPT | **(a)** for v1. (b) is the natural v2 (ticketed, D3) but turns the bridge into an autonomous agent-to-agent channel — that should be a deliberate second step with its own review, mirroring how the a2a peer layer was rolled out. |
| OD-F | **Protocol implementation** | (a) ★ official `@modelcontextprotocol/sdk` (repo already carries npm deps; stateless-per-request pattern proven in concierge `mcp/src/main.ts`); (b) hand-rolled minimal JSON-RPC (initialize / tools/list / tools/call) | **(a)** — protocol drift (ChatGPT's client evolves) is the real risk; the SDK tracks it. The framework is not a zero-dep repo (sphere-sdk is already a dependency), so the concierge zero-dep constraint does not transfer. |

### 0.2 Where the owner's intent rubbed against the safety rules (flags)

1. **"Couple the sessions" taken literally means ChatGPT drives the live Claude
   Code session.** A third-party model steering a session that holds
   Bash/Write/Edit is remote code execution by proxy, driven by text OpenAI's
   model generates — and transitively by whatever *that* model read (web pages,
   other chats: a prompt-injection relay). Resolution: ChatGPT never drives the
   session. It *proposes* via `send_to_session`; the proposal is quarantined
   DATA (never instructions), surfaced by the existing Stop-gate/work-item
   machinery, and executed only if the human owner picks it up in-session.
   This mirrors exactly how peer a2a content is handled today
   (`classify-inbound.sh`: default-deny, DATA-not-instructions).
2. **"Easy" vs auth.** The genuinely easy ChatGPT hookup (paste URL, no auth)
   is only safe because of the capability-URL + rotation + TTL + read-mostly
   surface stack (OD-A). The genuinely safe hookup (OAuth 2.1) is not easy.
   v1 ships easy-with-fences; phase 2 ships OAuth. This trade-off is explicit,
   not accidental.
3. **Everything a tool returns is sent to OpenAI.** File contents, git diffs,
   `ask_claude` answers — all become OpenAI-side conversation data, subject to
   their retention/training policies for the owner's plan. This is inherent to
   the coupling, not a bug; mitigations are the redaction fence (§5.3), the
   per-project opt-in, and a loud statement in docs + `gptbridge.sh start`
   output. Projects with sensitive code simply must not enable it.

---

## 1. Research: the landscape as verified (2026-08)

### 1.1 How ChatGPT connects to external MCP servers today

Three real surfaces:

| Surface | What it is | Transport | Auth | Reachability |
|---|---|---|---|---|
| **Developer-mode connectors** (Settings → Apps → Advanced → Developer mode; Plus/Pro/Business/Enterprise/Edu, web app) | Register any remote MCP server; all its tools (read and write) become available in conversations | **Streamable HTTP or SSE** | **OAuth or none** — no static API-key/custom-header field in the dialog | **Public HTTPS URL required**; local/stdio servers explicitly unsupported |
| **Responses API / Agents SDK `mcp` tool** (a.k.a. hosted MCP) | OpenAI's servers call your MCP server during a Responses API run; `require_approval` gates tool calls; `headers`/`authorization` fields carry credentials | Streamable HTTP | Bearer/custom headers supported | Publicly reachable from OpenAI's infra ("behind a firewall / on localhost" is called out as unreachable) |
| **Custom-GPT Actions** | OpenAPI (not MCP) function calling | HTTPS/OpenAPI | API key or OAuth | Public HTTPS |

Key consequences for this design:
- The server **must** be reachable over public HTTPS — a tunnel or reverse
  proxy is non-optional for a laptop-hosted bridge.
- Write-shaped tools trigger ChatGPT-side confirmation prompts by default
  (keep them on); read tools may run unprompted — so the *server-side* fence
  cannot rely on ChatGPT's confirmations.
- Because the connector UI has no bearer field, static-token auth must ride in
  the URL path (capability URL) if OAuth is not implemented (OD-A). API-side
  clients (Agents SDK) can and should use a real `Authorization` header.

Sources: [OpenAI help — Developer mode & MCP apps](https://help.openai.com/en/articles/12584461-developer-mode-and-mcp-apps-in-chatgpt),
[OpenAI — MCP & connectors guide](https://developers.openai.com/api/docs/guides/tools-connectors-mcp),
[Agents SDK — MCP](https://openai.github.io/openai-agents-python/mcp/),
[MCP tool cookbook guide](https://developers.openai.com/cookbook/examples/mcp/mcp_tool_guide),
[matagi 2026 guide](https://matagi.ai/blog/guides/how-to-connect-chatgpt-to-mcp-server),
[mcpservers.md ChatGPT guide](https://mcpservers.md/add-mcp/chatgpt),
[coworker.ai plan/limits](https://coworker.ai/blog/chatgpt-mcp).

### 1.2 Claude Code as an MCP server: `claude mcp serve`

Verified behavior:
- Exposes Claude Code's **raw tool surface** (Bash, Read/View, Write/Edit,
  LS, Grep/Glob, dispatch-agent) over **stdio only** — no HTTP mode, no auth.
- **Each client connection spawns a fresh headless Claude Code instance.** No
  state is shared between connections, and none is shared with an interactive
  session. It is *not* a handle onto the session you're sitting in.
- Server mode is headless and cannot prompt for permissions, which in practice
  pushes deployments to `--dangerously-skip-permissions`.
- No MCP passthrough: servers configured *in* Claude Code are not re-exported.

So `claude mcp serve` is a "remote hands on my machine" primitive, not a
session-coupling primitive — and its surface is exactly the one we must not
hand to an external model (§4.1).

Claude Code as MCP **client** is mature (this framework already launches
Serena via `.mcp.json`; HTTP/SSE/stdio transports, `--header` bearer support)
— relevant for the complementary outbound path (§4.4).

Sources: [Claude Code MCP docs](https://code.claude.com/docs/en/mcp),
[ksred — Claude Code as an MCP server](https://www.ksred.com/claude-code-as-an-mcp-server-an-interesting-capability-worth-understanding/).

### 1.3 The transport gap and the bridge options

ChatGPT needs public-HTTPS Streamable HTTP; anything stdio needs a bridge:

| Option | What it does | Trade-off |
|---|---|---|
| **Write the broker as a native Streamable-HTTP server** (★ chosen) | The framework's own Node process serves `POST /mcp/<token>` statelessly (one server+transport per request — the concierge `mcp/src/main.ts` pattern, ~100 lines with the SDK) | No extra hop, we control the whole surface, auth, and logging. This is only possible because we're *not* wrapping stdio `claude mcp serve` |
| [supergateway](https://github.com/supercorp-ai/supergateway) | stdio ⇄ SSE/WS/Streamable-HTTP gateway CLI | Needed only for the rejected raw-serve path; extra process, no opinion about auth |
| [mcp-proxy](https://github.com/sparfenyuk/mcp-proxy) | Python Streamable-HTTP ⇄ stdio bridge | Same role; adds a Python runtime requirement the framework doesn't otherwise have |
| **Exposure:** [cloudflared quick tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/) (★) | `cloudflared tunnel --url http://127.0.0.1:<port>` → random `https://<xyz>.trycloudflare.com`, lives only while the process runs | Zero-account, ephemeral (good: rotation), flagged "testing", 200-concurrent cap, **no SSE** (fine — Streamable HTTP JSON mode) |
| Exposure: named Cloudflare tunnel / existing reverse proxy | Stable URL on an owned domain | Stable connector entry in ChatGPT; requires CF account/DNS or an already-exposed host; stable URL = long-lived secret to protect (OD-C) |

Precedent: the Serena project documents exactly this shape (local MCP → mcpo →
cloudflared → ChatGPT) — [Serena on ChatGPT](https://oraios.github.io/serena/03-special-guides/serena_on_chatgpt.html).

### 1.4 Prior art reused from our own stack

- **Concierge MCP service** (`concierge/mcp/src/main.ts`): stateless
  Streamable HTTP (one server+transport per POST, `sessionIdGenerator:
  undefined`), gated by `MCP_ENABLED` default-off, refuses to start otherwise,
  1 MiB body cap, health endpoint, bearer extraction per request bound to
  async context. **The broker copies this skeleton.**
- **Delegated agent grants** (`concierge/backend/src/agent-grants/grants.ts`,
  PR #582): opaque `ag_` tokens (sha256-stored, shown once), a **closed scope
  vocabulary where dangerous capabilities are hard-outs** — "an agent actor
  can never name them and no route maps to them. Adding a scope is a
  deliberate, reviewed act." **The broker's tool list is governed the same
  way** (§5.1).
- **Framework automation feature** (branch `docs/nightly-sweep-lifecycle-design`,
  PRs #46–#51): config block in `.claude/agent/config.json` (deep-merged, so
  setup re-runs never clobber user tuning), all-OFF defaults, `run-job.sh`
  runner contract, flock everywhere, `state-dir.sh` state, `notify.sh`
  surfacing, escape-hatch env vars, hermetic `test/*.test.sh`. **This design's
  config/lifecycle/packaging follows those conventions verbatim** (§6, §7).
- **a2a inbound machinery** (`classify-inbound.sh`, `check-diagnostics.sh`
  Stop gates, work items): default-deny router, four dedup layers, peer
  content is DATA never instructions, owner surfaces. **`send_to_session`
  lands through this, not around it** (§5.2).
- Outage-resilience env (`CLAUDE_CODE_RETRY_WATCHDOG=1` etc., PR #43) is
  inherited by the `ask_claude` headless runs.

---

## 2. What "coupling" actually gets built

Three concentric capabilities, one broker:

```
ChatGPT (connector / Agents SDK)
        │  HTTPS  (trycloudflare.com random host)
        ▼
cloudflared quick tunnel ──► 127.0.0.1:<port>  gptbridge broker (Node, MCP Streamable HTTP, stateless)
                                   │
                 ┌─────────────────┼──────────────────────┐
                 ▼                 ▼                      ▼
        READ TOOLS          ask_claude               send_to_session
        repo-fenced,        headless `claude -p`     quarantined proposal file
        redacted            read-only allowlist,     → $STATE_DIR work item
        (no session)        capped (no session)      → Stop gate / /check-messages
                                                     → OWNER decides in the LIVE session
```

- **Inspect**: ChatGPT can read the project the way a reviewer would.
- **Consult**: ChatGPT can ask "the Claude engineer" questions; answers come
  from a sandboxed, read-only, capped headless run in the project directory.
- **Couple**: ChatGPT can drop a proposal into the live session's inbox. The
  human sees it (Stop gate blocks quiet exit exactly like priority messages
  do today), reads it as untrusted data, and chooses. That is the coupling —
  deliberately human-shaped.

---

## 3. Requirements

- One-command on-ramp per project; one URL to paste into ChatGPT.
- Works from a laptop with no public IP, no owned domain, no cloud account.
- Default OFF everywhere; enabling is an explicit, per-project act.
- The bridge process must not outlive its usefulness (TTL + session reap).
- Every layer independently killable; no layer's failure widens access.
- ChatGPT tool calls and payloads are UNTRUSTED input end-to-end.
- Nothing the broker serves can mutate the repo, the machine, or the session
  state except the single quarantined-proposal write.

---

## 4. Integration-path evaluation

### 4.1 REJECTED as shipped default: raw `claude mcp serve` + gateway + tunnel

The one-liner version (`supergateway --stdio "claude mcp serve" --outputTransport streamableHttp` + cloudflared). Rejected because:

1. **It is arbitrary remote code execution.** The exposed tool list *is*
   Bash/Write/Edit. Any client — or anyone holding the leaked URL — runs
   commands as the developer's user. ChatGPT's own confirmation prompts are
   client-side courtesy, not a server-side control.
2. **Headless permission collapse.** Server mode can't prompt, so real usage
   drifts to `--dangerously-skip-permissions` — the exact failure mode the
   permission system exists to prevent, now internet-reachable.
3. **It doesn't even couple sessions.** Each connection is a fresh instance;
   the interactive session the owner cares about is untouched.
4. **Injection relay.** Whatever poisoned a ChatGPT conversation (a web page,
   a document) can emit tool calls into your shell. There is no fence.

Not shipped, not documented as an "expert mode" — documenting it would be
publishing a foot-gun with our name on it.

### 4.2 ★ RECOMMENDED: the curated **gptbridge** broker (this design)

Claude-Code-side serves (hypothesis confirmed); the *surface* is a purpose-built
broker, not the raw session tools (hypothesis refined). Detailed in §5.

### 4.3 RUNNER-UP: broker in front of headless-only (no mailbox)

Identical broker minus `send_to_session` — pure inspect+consult (`tools:
"read+consult"` is literally this, one config value away). Strictly safer, but
it isn't a session *coupling*; it's "ChatGPT can review my repo." Kept as the
recommended tier for sensitive projects rather than as a separate path.

### 4.4 COMPLEMENT (not a substitute): Claude Code as *client* of an `ask_gpt` MCP server

The reverse coupling — an outbound-only MCP server wrapping OpenAI's API
(Responses API) that gives the Claude session an `ask_gpt` consult tool — has
none of the exposure problems (no inbound port, no tunnel, no token to leak;
just API spend). It is **not** what the owner asked for (it reaches the OpenAI
*API*, not the owner's ChatGPT session/UI/context) but it satisfies many of the
same "second opinion" use cases at ~zero risk. Ticketed as an optional
follow-on (E3) so the pair covers both directions.

### 4.5 Rejected alternatives, briefly

- **ChatGPT as MCP server:** no such product surface exists; not evaluable.
- **Fronting the session via the Nostr a2a channel end-to-end** (ChatGPT →
  relay → daemon): would reuse rich machinery but forces every ChatGPT tool
  call through relays with multi-second latency and gives no synchronous
  tool-call semantics; the mailbox tool already borrows the *ingest* half of
  a2a (the part that matters for safety) without the transport cost.
- **Custom-GPT Actions (OpenAPI):** second protocol to maintain, no MCP tool
  semantics, same exposure problem, fewer clients. MCP is the convergent
  standard both vendors now speak.

---

## 5. The gptbridge broker — surface, fences, lifecycle

### 5.1 Tool vocabulary (closed; hard-outs by construction)

Exactly like `AGENT_SCOPES` in the concierge grant model: this list is the
whole surface; a tool not named here cannot be called because no handler
exists. **Adding a tool is a deliberate, reviewed act** — PR + this doc
updated. `Bash`, `Write`, `Edit`, arbitrary-path reads, and network egress are
hard-outs: not disabled — *absent*.

| Tool | Tier | Contract |
|---|---|---|
| `project_info` | read | Repo name, current branch, HEAD, last 20 `git log --oneline`, ROADMAP.md summary if present. Read-only `git` invocations with fixed argv (no shell interpolation of caller input). |
| `read_file` | read | Path must resolve (after `realpath`) inside the project root; denylist (§5.3) applied; ≤ `max_file_kb`; binary files refused; response passed through the redaction filter. |
| `list_dir` / `glob` | read | Same fence; bounded result counts. |
| `search_code` | read | `rg --fixed-strings` (caller input is a *pattern argument*, never shell) over the fenced tree; denylisted paths excluded from the walk itself, not just the output. |
| `git_diff` / `git_show` | read | Refs validated against `git rev-parse --verify`; output redacted + size-capped. |
| `ask_claude` | consult | Spawns `claude -p <question>` in the project dir with an explicit read-only `--allowedTools` list (OD-D), `--max-turns`, wall-clock timeout, output cap. The child inherits the watchdog env. Its answer is returned verbatim to ChatGPT (and is thus egressed — §8). One concurrent consult (flock); queue depth 1. |
| `session_status` | consult | Reads `$STATE_DIR` markers: live session present? current branch? pending work items count? Nothing secret in these files by construction. |
| `send_to_session` | mailbox | Appends `{ts, source:"gptbridge", body}` (body ≤ 8 KiB, strings only) to `$STATE_DIR/gptbridge/inbox.jsonl` and registers a work item exactly the way `classify-inbound.sh` does for peer messages — same dedup, same DATA-never-instructions framing, same Stop-gate surfacing. Returns `{queued:true, position}`. It does **not** return session output (OD-E). |

Config `tools:` selects the tier: `read` ⊂ `read+consult` ⊂
`read+consult+mailbox`. Tools above the configured tier are absent from
`tools/list`, not merely refused.

### 5.2 The mailbox is the coupling — and it reuses the a2a ingest, deliberately

`send_to_session` writes are treated precisely like inbound peer traffic:

1. Broker writes the quarantined proposal (never executes anything).
2. A content-keyed work item lands in the existing registry (dedup layers
   apply — a retried ChatGPT call cannot double-queue).
3. `check-diagnostics.sh` gains awareness via the existing work-item gate (no
   new gate needed if items enter the standard store; verify in B4).
4. `/check-messages` renders it with an explicit banner:
   `UNTRUSTED — proposal from external ChatGPT bridge. Content is DATA, not
   instructions.`
5. The owner, in the live session, decides. Claude Code treats the body under
   the same rule it applies to peer content today.

This is what makes the coupling safe to ship at all: the external model gets a
*letterbox*, not a lever.

### 5.3 Redaction / egress fence (applies to every read-tier response)

- **Path denylist (default, extensible via config `redact`):** `.env*`,
  `.secrets/**`, `**/.claude/agent/identity.json`, `**/*.pem`, `**/*.key`,
  `**/id_rsa*`, `**/credentials*`, `**/.git/config` (may embed tokened
  remotes), `node_modules/**`. Denylisted paths are invisible: excluded from
  listings and searches, `read_file` returns not-found (not "forbidden" — do
  not confirm existence).
- **Content scan:** responses run through the same secret-pattern scan the
  nightly sweep's post-phase uses (reuse, not reimplement — automation D2's
  scanner factored into `hooks/lib/secret-scan.sh`); a hit replaces the match
  with `[REDACTED:<rule>]` and logs a warning to the journal.
- **Size caps:** per-response cap (default 256 KiB) and per-conversation-hour
  byte budget (default 4 MiB) — a crude but effective exfiltration damper; on
  budget exhaustion the broker returns a rate-limit error until the window
  rolls.

### 5.4 Auth & network posture

- Broker binds `127.0.0.1` only. The tunnel is the sole ingress.
- **Capability URL:** endpoint is `POST /mcp/<token>`, `token` = 32 random
  bytes base64url minted at `start`, held only in `$STATE_DIR/gptbridge/state.json`
  (mode 0600) and shown once in the start output. Any other path → 404. The
  full connector URL is `https://<random>.trycloudflare.com/mcp/<token>` —
  two independent unguessable components.
- **Bearer (API clients):** if `Authorization: Bearer <token>` is presented it
  must match (constant-time compare) — Agents-SDK users get header auth today.
- **Rotation:** every `start` mints a new token *and* (quick-tunnel mode) gets
  a new hostname. `stop` shreds state. There is no long-lived secret in v1.
- **OAuth 2.1 (phase 2, E2):** MCP-spec authorization (dynamic client
  registration + PKCE) so the connector registers as OAuth and per-user
  consent replaces the capability URL. Only then does a stable named-tunnel
  URL (OD-C b) become a recommended default.

### 5.5 Lifecycle — `gptbridge.sh start|stop|status|url` (deterministic shell)

- `start`: config gate (`enabled:true` or explicit `--force` with a printed
  warning), flock singleton, mint token, launch broker (Node) + `cloudflared`
  as children of a small supervisor, wait for the tunnel URL, write state
  file, print the paste-into-ChatGPT URL + a security notice (what is
  exposed, egress warning, TTL, how to stop), `notify.sh` ping.
- **TTL auto-stop** (default 4 h, config `ttl_hours`): supervisor kills both
  children and shreds state. A bridge nobody remembered is the classic leak.
- **Session reap** (config `stop_with_session`, default `true`): a SessionEnd
  hook stops the bridge when the last live session ends — refcount pattern
  copied from `daemon-session.sh`. The bridge must not outlive the session it
  couples to.
- `status`/`url`: read-only views of the state file (token masked in `status`;
  `url` prints the full connector URL for re-pasting).
- Crash-safety: flock means a dead supervisor releases the lock; `start`
  detects stale state (pid liveness) and cleans it.
- **Kill-switches**, outermost-in: delete the ChatGPT connector; `gptbridge.sh
  stop`; `GPTBRIDGE_DISABLE=1` env (broker refuses requests mid-flight);
  `enabled:false` in config (next start refuses); kill `cloudflared` (ingress
  gone even if the broker lives).

### 5.6 Observability

Append-only JSONL journal at `$STATE_DIR/gptbridge/journal.jsonl`: every tool
call (name, arg digest — not full args, they may embed pasted secrets from the
ChatGPT side), byte counts, redaction hits, auth failures, start/stop events.
`status` summarizes the last N entries. Auth failures also `notify.sh` (someone
is probing the URL → rotate now).

---

## 6. Framework packaging (claude-unicity-setup)

Follows the automation-feature conventions exactly.

### 6.1 Config block — `.claude/agent/config.json` (deep-merged; survives setup re-runs)

```jsonc
"gptbridge": {
  "enabled": false,                    // master gate; setup.sh NEVER sets true
  "port": 8873,
  "tools": "read+consult+mailbox",     // "read" | "read+consult" | "read+consult+mailbox" (OD-B)
  "expose": "quicktunnel",             // "quicktunnel" | "named" | "none" (OD-C)
  "named_tunnel_hostname": "",         // only for expose:"named"
  "ttl_hours": 4,
  "stop_with_session": true,
  "max_file_kb": 256,
  "hourly_egress_mb": 4,
  "redact": [],                        // ADDITIONS to the built-in denylist (never replaces it)
  "ask_claude": {
    "enabled": true,
    "max_turns": 15,
    "timeout_s": 300,
    "model": "sonnet"                  // consults don't need Opus
  }
}
```

### 6.2 Files

```
claude_conf/hooks/gptbridge/gptbridge.sh      lifecycle (start|stop|status|url), supervisor, TTL
claude_conf/hooks/gptbridge/broker.mjs        the MCP server (SDK, stateless streamable HTTP)
claude_conf/hooks/gptbridge/tools.mjs         tool vocabulary + fences (pure, unit-testable)
claude_conf/hooks/lib/secret-scan.sh          shared with automation D2 (whichever lands first creates it)
claude_conf/skills/gptbridge/SKILL.md         /gptbridge start|stop|status|url + guided ChatGPT hookup
docs/chatgpt-mcp-coupling-design.md           this doc
test/gptbridge.test.sh                        hermetic tests (§6.5)
```

### 6.3 `setup.sh` — new phase (install-only, enables nothing)

- Seed the `gptbridge` block (deep-merge, absent keys only).
- Copy hooks/skill; wire the SessionEnd reap hook into `settings.json`
  (the hook exits 0 instantly when the feature is disabled — zero cost).
- Preflight *report* (not hard requirement): `node` present, `cloudflared`
  present or "install hint", `claude` on PATH. Absence is fine — the feature
  is off; `gptbridge.sh start` re-checks and fails loudly with the same hints.
- Setup summary line: `gptbridge: installed (DISABLED — see docs/chatgpt-mcp-coupling-design.md)`.

### 6.4 The developer on-ramp (the "easy" being bought)

```bash
# once per project (opt in):
jq '.gptbridge.enabled=true' .claude/agent/config.json | sponge .claude/agent/config.json
# each working session that wants ChatGPT coupled:
.claude/hooks/gptbridge/gptbridge.sh start     # or: /gptbridge start
#   → prints: https://<random>.trycloudflare.com/mcp/<token>
```

In ChatGPT (once per bridge start, because the URL rotates): Settings → Apps →
Advanced → Developer mode ON → Add custom connector → paste URL → auth: *none*
→ create. Then talk: *"Using the gptbridge connector, review the diff on my
current branch and send my Claude session a summary of concerns."*

The re-paste-per-start friction is the price of rotation (OD-A/OD-C); a named
tunnel + OAuth (phase 2) removes it for teams that want permanence.

### 6.5 Tests (hermetic, `test/gptbridge.test.sh` conventions)

- Fence: path traversal (`../`, symlink out of root, absolute), denylist
  invisibility (listing + search + read), size caps, redaction corpus.
- Auth: wrong/missing path token → 404; bearer mismatch → 401; constant-time
  compare exercised.
- Vocabulary: tier config removes tools from `tools/list`; unknown tool call →
  JSON-RPC method-not-found; mailbox body >8 KiB refused.
- Lifecycle: flock singleton, stale-state cleanup, TTL fires (fake clock),
  SessionEnd reap refcount, `GPTBRIDGE_DISABLE=1` mid-flight refusal.
- Broker protocol smoke against a scripted MCP client (initialize → list →
  call) with `cloudflared` and `claude` stubbed by mock binaries.

### 6.6 Docs

- `CLAUDE.md` template section: what gptbridge is, the one-paragraph security
  model ("ChatGPT can read fenced project files, consult a sandboxed Claude,
  and leave proposals; it can never execute or write; everything it reads is
  sent to OpenAI"), on-ramp, kill-switches.
- This design doc is the authoritative reference.

---

## 7. Reuse map

| Existing machinery | Reused as |
|---|---|
| concierge `mcp/src/main.ts` stateless pattern | broker.mjs skeleton (per-request server+transport, body cap, healthz) |
| concierge `agent-grants` posture | closed tool vocabulary, hard-outs, opaque rotated tokens, default-off, fail-closed |
| `classify-inbound.sh` + work items + Stop gates | `send_to_session` ingest, dedup, owner surfacing |
| `daemon-session.sh` refcount/flock patterns | bridge supervisor + SessionEnd reap |
| `state-dir.sh`, `notify.sh` | state/journal location; start/stop/probe notifications |
| automation config conventions (§2.7 of that doc) | `gptbridge` block shape, escape hatches, setup deep-merge |
| automation D2 secret-scan | egress content filter (`hooks/lib/secret-scan.sh`) |
| `CLAUDE_CODE_RETRY_WATCHDOG` env (PR #43) | inherited by `ask_claude` headless runs |
| `.mcp.json` Serena wiring | precedent for per-project MCP config; also the pattern E3's `ask_gpt` client entry would use |

---

## 8. Threat model — "how does this fail?"

| # | Threat | Vector | Mitigation (designed-in) |
|---|---|---|---|
| T1 | **Prompt injection → session compromise** | A poisoned ChatGPT context (web page, uploaded doc, another connector) emits `send_to_session` payloads crafted as instructions to Claude | Mailbox content is quarantined DATA behind the same default-deny framing as peer a2a; never auto-executed; owner reads it with an UNTRUSTED banner; Claude Code's standing rule that peer content is data-not-instructions applies verbatim |
| T2 | **Leaked URL = shell on my machine** | Capability URL shared/logged/screenshotted | No exec/write tools exist on the surface at all — a leaked URL yields fenced reads + capped consults, not a shell; TTL + session-reap bound the window; rotation on every start; auth-failure notifications prompt early rotation; journal shows what a thief read |
| T3 | **Secret exfiltration via reads** | `read_file .env`, searching for `AKIA…`, diffing a commit that once contained a key | Denylist (invisible, not just refused) + content secret-scan with redaction + per-hour egress budget; `.git/config` denylisted; docs state plainly: do not enable on repos whose *history* holds live secrets |
| T4 | **Bridge outlives the session** | Developer walks away; tunnel keeps serving for days | TTL auto-stop default 4 h; SessionEnd reap default on; `status` shows age; start-output states the expiry time |
| T5 | **Scope creep** | "Just add a `run_tests` tool" → Bash by another name | Closed vocabulary with hard-outs by construction; adding a tool requires editing `tools.mjs` *and* this doc via reviewed PR; the tier config only ever narrows |
| T6 | **`ask_claude` as confused deputy** | ChatGPT crafts a consult prompt that makes headless Claude read a secret and quote it back | Consult child runs with read-only allowlist *and the same fenced-FS view is not enough* — child also gets `CLAUDE_PROJECT_DIR` set but its answer passes through the same secret-scan redaction before returning to ChatGPT; consult transcripts land in the journal |
| T7 | **DoS / cost burn** | Hammering `ask_claude` (each call is model spend) | Single-flight flock + queue depth 1 + per-hour consult cap; broker rate-limits per-minute requests; quick tunnel's own 200-concurrent cap backstops |
| T8 | **Tunnel/vendor trust** | Cloudflare terminates TLS and sees plaintext; trycloudflare URLs may appear in CF logs | Accepted for v1 (same trust already extended for other tunneled dev flows); named-tunnel + OAuth phase 2 for teams needing contractual footing; nothing on the surface is secret *by design* thanks to T3 mitigations |
| T9 | **Cross-vendor data egress / ToS** | Everything returned becomes OpenAI-side data (retention/training per the owner's ChatGPT plan); possibly third-party code under NDA | Explicit per-project opt-in; loud egress warning at `start`; redaction fence; docs instruct: check the repo's confidentiality obligations *and* the ChatGPT workspace's data controls before enabling. This is a policy risk no code fully removes |
| T10 | **State-file theft** | Local malware reads `state.json` token | Mode 0600, token useless after stop/TTL, and a local attacker with FS access already has more than the bridge grants |

### 8.7 Where "easy" trades against the fence (explicit)

1. **No-auth connector + capability URL** (OD-A) instead of OAuth — easy wins
   v1, with rotation/TTL/read-mostly as compensating controls; OAuth is the
   ticketed correction.
2. **URL re-paste every start** — security (rotation) deliberately costs
   convenience; permanence is available only bundled with the stronger auth.
3. **No write/exec tools** — some "just fix it from my phone via ChatGPT"
   dreams stay dreams in v1; the mailbox + the human in the live session is
   the designed answer. Loosening this is not a config flip anywhere.

---

## 9. Implementation work breakdown

Legend as in the automation doc: **[hook]** deterministic shell (+ hermetic
tests), **[js]** Node broker code, **[skill]** SKILL.md, **[plumb]** setup
wiring, **[doc]** docs. Each item sized for a single Opus implementation agent.

### Group A — substrate

| id | Title | Scope / files | Reuse vs new | Deps |
|---|---|---|---|---|
| A1 | **[plumb]** Config schema + setup phase (install-only) + preflight report | `setup.sh` new phase; seed `gptbridge` block (deep-merge); summary line | Reuses setup merge contract from automation A1 | — |
| A2 | **[hook]** `gptbridge.sh` lifecycle: flock singleton, token mint, supervisor (broker+cloudflared), TTL, state file 0600, start-output security notice, `stop`/`status`/`url`, `GPTBRIDGE_DISABLE` | `claude_conf/hooks/gptbridge/gptbridge.sh` | New; patterns from `daemon-session.sh` + automation `run-job.sh` | A1 |
| A3 | **[hook]** SessionEnd reap hook + `settings.json` wiring (instant no-op when disabled) | small hook + settings entry | Refcount pattern from `daemon-session.sh` | A2 |
| A4 | **[hook]** `hooks/lib/secret-scan.sh` shared scanner (rule corpus + redact function) — coordinate with automation D2; whichever lands first creates it, the other consumes | `claude_conf/hooks/lib/secret-scan.sh` + corpus tests | Shared with nightly-sweep D2 | — |

### Group B — broker

| id | Title | Scope / files | Reuse vs new | Deps |
|---|---|---|---|---|
| B1 | **[js]** broker.mjs: stateless Streamable-HTTP MCP server (SDK per OD-F), capability-URL + bearer auth (constant-time), body cap, healthz, journal, rate limits, `GPTBRIDGE_DISABLE` mid-flight refusal | `claude_conf/hooks/gptbridge/broker.mjs`; `package.json` adds `@modelcontextprotocol/sdk` | Skeleton = concierge `mcp/src/main.ts` | A1 |
| B2 | **[js]** tools.mjs read tier: `project_info`, `read_file`, `list_dir`, `glob`, `search_code`, `git_diff`, `git_show` — realpath fence, denylist-invisible, size caps, fixed-argv subprocess calls, secret-scan on every response | `claude_conf/hooks/gptbridge/tools.mjs` | Fence semantics per §5.1/5.3; scanner from A4 | B1, A4 |
| B3 | **[js]** consult tier: `ask_claude` (read-only allowedTools per OD-D, turn/time/output caps, single-flight, watchdog env, redacted answer) + `session_status` | tools.mjs | Headless contract mirrors automation `run-job.sh` | B2 |
| B4 | **[js+hook]** mailbox tier: `send_to_session` → inbox.jsonl + work-item registration through the existing store (verify Stop-gate pickup; add UNTRUSTED banner rendering in `/check-messages`) | tools.mjs + small patch to `classify-inbound.sh`/`check-messages` | Reuses dedup + gates wholesale | B2 |
| B5 | **[hook]** Hermetic test suite per §6.5 (mock `claude`, mock `cloudflared`, scripted MCP client, traversal/redaction corpus, lifecycle/TTL fake clock) | `test/gptbridge.test.sh` | `test/*.test.sh` conventions | A2–A3, B1–B4 |

### Group C — client-side UX

| id | Title | Scope / files | Reuse vs new | Deps |
|---|---|---|---|---|
| C1 | **[skill]** `/gptbridge` skill: start/stop/status/url + guided ChatGPT connector walkthrough + egress warning echo | `claude_conf/skills/gptbridge/SKILL.md` | Skill conventions | A2 |
| C2 | **[doc]** CLAUDE.md template section + setup summary text + this doc cross-links | per §6.6 | — | A–B landed |

### Group D/E — phase 2 (separately approvable)

| id | Title | Scope | Deps |
|---|---|---|---|
| E1 | **[js]** Named-tunnel mode (`expose:"named"`): cloudflared config template, stable hostname, docs on CF account setup | broker unchanged | B-group |
| E2 | **[js]** OAuth 2.1 authorization (MCP spec: dynamic client registration + PKCE) replacing capability-URL for the ChatGPT UI path; then recommend named tunnel as default | biggest single item; consider `mcp-auth`-style library vs SDK support at build time | E1 |
| E3 | **[js]** Complementary outbound `ask_gpt` MCP server (Claude Code as client → OpenAI Responses API), `.mcp.json` template entry, spend caps | independent of A–C | — |
| E4 | **[js]** Bidirectional mailbox (OD-E b): reply queue the live session writes into, broker serves to ChatGPT with provenance framing | its own security review | B4 |

**Suggested landing order:** A1→A2→A3 · A4 (parallel) · B1→B2→B3→B4→B5 ·
C1→C2. Group E items are individually owner-approvable later.

---

*Design: Fable 5 session, 2026-08-19. Grounded in framework `main` @ `ab5b150`,
concierge PR #582 (`mcp/`, `backend/src/agent-grants/`), and the scheduled-
automation design (`docs/nightly-sweep-lifecycle-design.md`, PRs #46–#51).
Web research verified 2026-08-19 (sources in §1).*
