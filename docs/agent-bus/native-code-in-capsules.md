# Native code in AstridOS capsules — runtime investigation (Fable)

**Question:** can non-WASM (native) code run inside/under AstridOS capsules, and does any such path change the SIF-placement verdict?
**Method:** read the astrid kernel source at the concierge-pinned ref `unicity-astrid/astrid @ c511f5f` (astrid v0.8.0, per `docker/astrid.Dockerfile:14`), cross-checked against the live `concierge-astrid-1` container + concierge capsule manifests.

**Headline (both change the prior picture):**
1. AstridOS has **two first-class, capability-gated native-execution paths** — a per-capsule native host process (the "Airlock Override" MCP engine) and an `astrid:process` spawn API callable from WASM guests — both OS-sandboxed via bubblewrap. The "accidental `.so`" was NOT a native module loader (dead end); the real native paths are process-based.
2. **The prior report's "no blocking capsule stage exists" claim is wrong at the kernel layer.** The event dispatcher runs priority-ordered **interceptor chains with `Deny`/`Final`/payload-rewrite semantics** over `user.v1.prompt` and `tool.v1.execute.result`. The blocking, redacting, veto-capable pipeline stage the prior investigation said would need an upstream feature **already exists** — with one fail-open caveat.

## 1. Runtime + module model (from source)

**WASM runtime:** wasmtime **46.0.1** (`component-model` + `cranelift`) + wasmtime-wasi 46. Epoch-interrupt timeouts (100ms tick, 5-min wall cap), per-principal fuel telemetry, memory ledger, pooled instances (`crates/astrid-capsule/src/engine/wasm/mod.rs:111-117,350`).

**Guest ABI:** wasmtime **component model** with a fully Astrid-owned WIT world (`astrid:ipc/http/fs/kv/net/process/sys`). **Zero `wasi:*` registration** — a capsule importing `wasi:*` fails to instantiate at load "that is the intended posture" (`mod.rs:357-372`). Canonical target `wasm32-unknown-unknown` + getrandom-custom.

**Loader = "Composite Capsule" factory, THREE engine kinds** (`crates/astrid-capsule/src/loader.rs:82-126`):

| Engine | Trigger in `Capsule.toml` | Runs |
|---|---|---|
| `WasmEngine` | any `[[component]]` (`.wasm` path) | wasmtime component, sandboxed |
| `McpHostEngine` — "Legacy Host MCP Engine (Airlock Override)" | `[[mcp_server]]` `type="stdio"` + `command` | a **native host process** over stdio MCP |
| `StaticEngine` | always | context files/commands/skills, no VM |

**No dlopen/libloading path.** WASM loads only via `Component::from_binary` (rejects native ELF). **The `.so` clue resolved:** `astrid-build` doesn't pass `--target`; with no `.cargo/config.toml` the host triple builds a `.so`, then packaging fails "Could not locate compiled WASM binary…" (`crates/astrid-build/src/rust.rs:121-149,346-353`). A never-loadable build artifact, not a native capsule kind.

**Native-process controls (shared by both native paths):** capability gate `[capabilities] host_process = ["<cmd>",…]` (`engine/mcp.rs:58-71`); command may be a local binary / fat-binary dir with per-triple slices (capsules are designed to ship native binaries); OS sandbox `bwrap --ro-bind / / --tmpfs /tmp --unshare-all [--share-net] --die-with-parent` (`crates/astrid-workspace/src/sandbox/bwrap.rs:128-201`); **`SandboxPolicy::Required` is default** — no bwrap ⇒ spawn refused (escape: `ASTRID_SANDBOX_POLICY=off`). `astrid:process` WIT gives guests `spawn`/`spawn-background`/`spawn-persistent`, BLAKE3-verified ro file injection, per-principal quotas, audit.

**Deployment reality (live):** `concierge-astrid-1` has **no `bwrap`** and `ASTRID_SANDBOX_POLICY` unset ⇒ policy `Required` ⇒ every native-process path **fails closed today**. Enabling needs `bubblewrap` in the astrid image + Docker seccomp/userns handling (or policy `off`).

**The interceptor discovery (kernel dispatch):** `InterceptResult = Continue(payload) | Final(payload) | Deny{reason}` (`crates/astrid-capsule/src/capsule.rs:28-35`); guests express `CapsuleResult{action:"continue"|"final"|"deny"/"abort", data}` (`:60-75`); astrid-sdk 0.7 macro emits `deny` on handler `Err`. The dispatcher runs matches at **distinct priorities as an ordered middleware chain** — lower priority first, each may rewrite the payload passed to the next, `Final`/`Deny` short-circuits (`crates/astrid-capsule/src/dispatcher.rs:420-437,500-586`). The gateway publishes every prompt as `user.v1.prompt` (`crates/astrid-gateway/src/routes/agent.rs:12`); the vendored react loop intercepts it at priority 100 and `tool.v1.execute.result` likewise (`concierge/capsules/react/Capsule.toml:75,79`). **Neither topic is grant-gated** — only `tool.v1.execute.<name>` + `cli.v1.command.execute` pass the per-principal access gate (`access.rs:62-92`) — so a baked guard capsule at priority <100 fires for EVERY principal, no grant, no env write. Two caveats: (i) interceptor **error/epoch-kill → "continuing chain"** = fail-open on guard crash/timeout (`dispatcher.rs:566-586`); (ii) the **MCP-engine interceptor cannot short-circuit** ("no wire format for short-circuit", `engine/mcp.rs:266-268`) — blocking is WASM-guest-only.

## 2. Options to run native code

| # | Option | Real @ c511f5f? | Sandbox/trust | Effort | Runs SIF ML? |
|---|---|---|---|---|---|
| a | Native `.so` (dlopen) | **No — dead end** (`Component::from_binary` only; `.so` = failed build) | — | — | No |
| a′ | Native host process capsule (`[[mcp_server]] stdio` + `host_process`) | **Yes, first-class** | bwrap, Required default; net iff declared | Medium; **deploy-blocked on concierge (no bwrap)** | **Yes** (native ort/YARA/tokio) — but **cannot veto** (MCP interceptors can't short-circuit); advisory only |
| a″ | WASM capsule spawns native worker via `astrid:process` `spawn-persistent` | **Yes, first-class** | same bwrap; quotas; verified ro model/rule injection | Med-high; same deploy blocker | **Yes** — and the WASM front keeps `Deny`/`Final` ⇒ strongest "SIF in a capsule" |
| b | Custom host imports (`host.infer`) | Native to astrid ABI (kernel patch; concierge already carries patches 0001/0002) | host fn = full-trust in daemon; pulls ort/tokio into astrid-daemon | High, permanent patch burden | Yes, but TCB moves into the kernel — worse than backend |
| c | **wasi-nn** | **No** — not in Cargo.lock; zero wasi:* is deliberate. wasmtime 46 could host it ⇒ upstream feature request | host inference/guest calls | Upstream RFC | Eventually, not today |
| d | Component model / preview2 | Component model IS the substrate; "richer interfaces" = (b) | as (b) | as (b) | as (b) |
| e | WASM capsule → co-located native sidecar over HTTP | **Yes** — (e1) public URL via `astrid:http` today; (e2) **operator-blessed local egress** `[security.capsule_local_egress]` punches specific loopback/private `host:port` through the airlock (`host/consent_egress.rs`, `ssrf.rs:184-205`) | sidecar outside TCB; capsule sandboxed; uniquely composable with interceptor `Deny` | **Low** — config + small guard capsule, no bwrap | Full (sidecar); capsule enforces |
| f | Compile engine to WASM (tract/candle/aho-corasick) | Rules tier: portable with a fork (aho-corasick/regex → wasm32, simd128, no threads). ML tier: infeasible at semanticd scale | sandboxed | High, ongoing drift | Rules only |

## 3. Verdict

**Native code "in a capsule"? Yes — as a capability-gated, OS-sandboxed child process (a′, a″).** No in-process native plugins (a dead), no wasi-nn today (c dead, reasonable upstream ask).

**Does it change SIF placement? Refines substantially without overturning:**
1. **The prior "no veto/redaction path" claim is falsified at the kernel layer.** That was true only of prompt-builder's `before_build` HOOK protocol. The kernel event dispatcher gives any baked WASM capsule a priority-ordered interceptor with **payload rewrite, `Final`, and `Deny`** over `user.v1.prompt` AND `tool.v1.execute.result` — the latter being exactly the mid-turn `fetch_url` seam the prior report said only `/api/llm` could catch. Ungated per-principal, no 250ms drop-window (that race is prompt-builder-internal), no env write. **The upstream feature the prior report proposed to file already ships.**
2. **The honest remaining gap is failure posture:** the chain **continues on interceptor error/epoch-kill** (`dispatcher.rs:566-586`) — fail-open under the guard's own crash/timeout; a guest catch-all returning `deny` closes most, not all. The backend `/api/llm` + ingestion-seam guard remains the only place a *genuine* fail-closed guarantee + native ML + hot-reload coexist. **Primary SIF placement stands: backend chokepoint.**
3. **But an in-runtime SIF layer is now a real, cheap defense-in-depth — recommended spike:** a small first-party **guard capsule** subscribed to `user.v1.prompt` + `tool.v1.execute.result` at `priority = 10`, running the rules tier in-guest (aho-corasick → wasm32 fine) and optionally calling the semanticd sidecar via an `[security.capsule_local_egress]`-blessed loopback endpoint (option e2), returning `deny`/`final` on hits and on scan-unreachable (guest fail-closed). ~days, no kernel patch, no bwrap, blocks *before the react loop sees the event*.
4. **Fully native SIF under astrid** (a″: WASM guard + `spawn-persistent` native semanticd worker) is architecturally supported but **operationally blocked on this deployment** (no bwrap in image, Docker seccomp/userns, Required policy) — an image + container-security work item.
5. **Worth filing upstream (unicity-astrid/astrid):** (i) a per-subscription fail-closed knob (`on_error = "deny"` in `[subscribe]`) — this single flag makes the in-runtime guard a true enforcement point; (ii) wasi-nn / an `astrid:nn` host interface for in-capsule ML.

**Bottom line:** keep the SIF ML tier + the fail-closed guarantee at the backend chokepoints as decided — but the "capsules can't filter" premise is dead. Build the priority-10 guard capsule as defense-in-depth (rules in-guest, sidecar via blessed local egress), and file the `on_error="deny"` upstream ask that promotes it to a second enforcement point.
