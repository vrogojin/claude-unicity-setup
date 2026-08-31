# First-class blocking content-pipeline stage in AstridOS — feasibility & implementation plan (Fable)

**Investigated 2026-07-22** against `unicity-astrid/astrid @ c511f5f` (the pinned `ASTRID_REF`, cloned at the exact ref), the vendored `capsules/react` + first-party `capsules/prompt-builder`, `docker/astrid.Dockerfile` + `docker/patches/`, and the prior SIF-placement investigation.

## (a) Feasibility verdict: YES — and cheaper than assumed. Most of the "host" is already ours.

The prior framing ("this needs an upstream astrid feature") is too pessimistic: **the entire content pipeline above the bus is first-party or vendored code in the concierge repo**, and the one host primitive the feature needs (synchronous request/response with a hard timeout) already exists and is production-proven.

Five load-bearing discoveries, each verified in source:

1. **React consumes the `messages` array from prompt-builder's response.** `AssembleResponse` carries `messages` (prompt-builder `lib.rs:108-111`), populated by prompt-builder from the session capsule (`:1649-1653`, `:1555-1597`); react's `handle_prompt_response` feeds that array verbatim to `publish_llm_request` (react `lib.rs:862, 882`). **Whatever prompt-builder puts in `messages` is what the LLM sees** — message rewrite/redaction for the turn's first LLM call needs *zero* host changes. (React's doc comment at `:794-798` saying it "does not echo messages back" is stale — the code says otherwise.)

2. **The assemble step is already blocking and fail-closed at the turn level.** React is a phase state machine; `AwaitingPromptBuild` has a hard 30 s phase timeout (`:303-304, 462-465`); on expiry the turn is aborted with a final "Request timed out" response and reset to Idle (`:472-489`). If prompt-builder withholds its response, the turn dies — it does not proceed unguarded. The fail-open behavior the SIF doc condemned lives *only inside* prompt-builder's hook fan-out (the 250 ms `HOOK_FIRST_RESPONSE_MS` window, `:172-192, 401-450`) — code we own and can replace.

3. **A synchronous request/response primitive with a hard fail-closed timeout exists and is production-proven.** `ipc::request_response` (astrid-sdk 0.7): v4 correlation ID, subscribe-before-publish, correlation-scoped reply topic, teardown on Drop, `Err` on timeout — already used by prompt-builder for session fetches with a 5000 ms budget (`:1548-1572`). The fire-and-forget host dispatcher (drop-on-backpressure; per-(capsule,principal) queues cap 64; `hooks::trigger` fan-out-with-responses syscall **removed** in #752) does *not* block the feature: a dropped/slow stage request just times out and the caller **fails closed**. Every delivery-failure mode collapses into "turn held", never "turn proceeds unguarded" — satisfying requirements 3 and 4 with no bus change.

4. **The astrid host is ours to patch, via a proven mechanism.** `docker/astrid.Dockerfile:13-14` pins `ASTRID_REPO=github.com/unicity-astrid/astrid`, `ASTRID_REF=c511f5f`, and `docker/patches/0001…0004-*.patch` apply on top at build with **fail-on-conflict** (`:34-41`). Any host change is "add patch 0005" — no fork. And the needed change is tiny: capability names derive from the `CapabilitiesDef` struct — adding a `content_guard: bool` field in `crates/astrid-capsule/src/manifest/capabilities.rs` (~:82) flows through `held_names`/`has`/`check_capsule_capability` automatically (unknown names fail closed).

5. **The SSRF airlock has a per-capsule operator escape.** `[security.capsule_local_egress]` (astrid-config `types.rs:227`, `ssrf.rs`) exempts a named capsule for a named `host:port` — so a guard capsule can call `concierge-backend:8787` over the compose network without the deprecated global IP bypass. (Public-URL egress, as the openai-compat→`/api/llm` proxy already does, is the zero-config alternative.)

**The one genuine in-runtime hole:** mid-turn tool results **bypass prompt-builder** — react's `handle_tool_result` appends results and calls `publish_llm_request` directly (`:1146-1157`); no hook fires between a `fetch_url` result and the next LLM call. A prompt-builder stage guards only turn starts. In-runtime mid-turn coverage needs a react patch — feasible (react is vendored) — but it's the same content the backend `/api/llm` egress guard already covers.

**Verdict: fully feasible.** Requirements 1–4 all implementable: #1/#2 in prompt-builder + react (both in this repo), #3/#4 by replacing the open fan-out with an explicitly-registered, `request_response`-driven stage chain that fails closed. The only host change is an optional one-field capability patch. NOT worth building: a `blocking=true` `[subscribe]` flag with dispatcher-level await-all — the dispatcher is fire-and-forget by design and `hooks::trigger` was removed; re-adding host response-collection is a large risky rewrite that buys nothing over the pipeline-owner doing its own synchronous calls.

## (b) Design: the `content_guard` blocking stage

**Protocol** — a new, separate topic pair (existing `before_build` fan-out untouched → backward compat by construction):
- Request `prompt_builder.v1.stage.<name>` — `{messages, system_prompt, request_id, session_id, model, provider, correlation_id}`.
- Response (correlation-scoped reply topic):
```rust
struct StageResponse {
    verdict: String,                          // "allow" | "rewrite" | "veto"
    messages: Option<Vec<serde_json::Value>>, // full replacement array when "rewrite"
    reason: Option<String>,                   // required for veto; audit-logged
}
```
Full-array replacement (payload already round-trips whole arrays).

**Registration & ordering** — not open pub/sub. Prompt-builder reads `blocking_stages` (ordered comma-separated names) + `stage_timeout_ms` (default 2000). Empty list (default) = byte-identical to today. Per stage, in order, sequentially: `request_response("prompt_builder.v1.stage.<name>", …, stage_timeout_ms)`. Deterministic, no first-response race, no silent drop. Ship `blocking_stages` as **global container env** (kill-switch/rollout lever — no `[env]` declaration, can't silently 404) plus a declared per-principal `[env]` field for later per-principal policy.

**Fail-closed semantics** — `veto` → assemble responds `{veto: reason}`, no LLM request. Timeout/transport/malformed → same as veto, reason "content guard unavailable". Prompt-builder crash → react's `AwaitingPromptBuild` timeout aborts (platform backstop). Veto surfaced via a final `agent.v1.response` (`is_final:true`) — precedent at react `:1105-1114`, `:477-486`.

**Privilege gating** — `rewrite`/`veto` honored only from capsules holding the `content_guard` capability (patch 0005); unprivileged responses discarded + audit-logged. Interim zero-patch option: reuse `allow_prompt_injection` — but the dedicated 5-line capability is a real boundary; do it.

**Backward compatibility** — additive `before_build` subscribers (personality, current-awareness, compactor, structural-memory) untouched (different topic). Blocking stages run FIRST on raw messages; additive hooks then decorate the (possibly rewritten) turn. `AssembleResponse` gains optional `veto`; react reads defensively; both capsules bake into one image → atomic upgrade. Empty `blocking_stages` → no stage call, no behavior change (test byte-identical).

**Mid-turn coverage (optional Phase 2)** — patch react `handle_tool_result` to run the same stage chain on appended tool-result messages before `publish_llm_request` (`:1146-1157`). Closes the `fetch_url`-mid-turn hole in-runtime; backend `/api/llm` already closes it at egress.

## (c) IMPLEMENTATION INSTRUCTIONS — for Opus agents

All in `/home/vrogojin/concierge` unless noted. Branch `feat/blocking-content-stage` off `main`. Conventional commits; typecheck+tests before each commit. Don't touch `main` directly.

### WS1 — astrid kernel patch 0005 (capability)  *(smallest; first)*
- New `docker/patches/0005-content-guard-capability.patch` (generate via `git diff` in a scratch clone of `unicity-astrid/astrid@c511f5f` **with 0001–0004 applied first**, so it applies in the sequential loop).
- In `crates/astrid-capsule/src/manifest/capabilities.rs`, add to `CapabilitiesDef`:
```rust
/// Whether the capsule may return rewrite/veto verdicts from a prompt-builder
/// blocking content stage. Security boundary: without it, stage responses are
/// discarded (fail-closed at the consumer).
#[serde(default)]
pub content_guard: bool,
```
Update the two exhaustive tests in that file (`held_names_and_has_agree_when_all_held`, `default_holds_nothing`). Nothing else (derived). **Verify:** `docker compose build astrid` must succeed (Dockerfile fails on a non-applying patch — that's the gate).

### WS2 — prompt-builder blocking-stage dispatch
`capsules/prompt-builder/src/lib.rs` (+ `Capsule.toml`):
1. Config (`Config::load` ~:51-57): `blocking_stages: Vec<String>` (env, empty default) + `stage_timeout_ms: u64` (env, default 2000).
2. Types `StageRequest` (mirror `BeforePromptBuildPayload` ~:116-128) + `StageResponse` per (b).
3. `run_blocking_stages(...)`: for each stage in order, `ipc::request_response(...)`; on Ok validate responder UUID holds `content_guard` via `capabilities::check` (pattern :460-475; if source metadata isn't exposed, have the stage echo its UUID and verify — fails closed for unknown UUIDs); `allow`→continue, `rewrite`→replace messages (log lengths), `veto`→Err(reason). Err/unparseable/unprivileged→Err("content guard unavailable"). No first-response window/idle grace — full per-stage timeout, always consumed.
4. Wire into `assemble()` (:1600-1674): move `fetch_session_messages` BEFORE the hook fan-out; run `run_blocking_stages`; on veto publish `{request_id, session_id, veto: reason}` on `prompt_builder.v1.response.assemble` and return (skip hooks/tools/after_build); on allow/rewrite proceed as today but put the (possibly rewritten) messages in the response AND pass them into the `before_build` payload.
5. `Capsule.toml`: `[publish]` grant `"prompt_builder.v1.stage.*"`; `[env]` declarations for `blocking_stages` + `stage_timeout_ms` (undeclared per-principal writes 404 silently — CLAUDE.md gotcha #2).
Tests: empty-list byte-identical; veto short-circuits; rewrite replaces; malformed→veto; capability-denied→veto.

### WS3 — react veto handling (+ optional mid-turn guard)
`capsules/react/src/lib.rs`:
1. In `handle_prompt_response` (:832-883), after the redrive guard: non-empty `veto` → publish final `agent.v1.response` (copy iteration-cap pattern :1105-1117), `reset_conversation_turn()`, `Phase::Idle`, `save()`, return. Handle existing `{"error":…}` assemble responses the same way (they currently degrade — fix while here).
2. *(Phase 2, same flag)*: in `handle_tool_result` between `fetch_messages_with_append` (:1146) and `publish_llm_request` (:1157), run the stage chain on appended tool-result messages; veto/timeout → same abort.
3. Fix the stale comment :794-798.
Tests: veto→Idle+final; error→same; normal unchanged.

### WS4 — reference `content-guard` capsule + backend endpoint
- New `capsules/content-guard/` — copy `capsules/personality/` skeleton (thin backend-proxy, handler shape src/lib.rs:217-249; **copy its `.cargo/config.toml`** — wasm target + getrandom, per the agent-personality gotcha). `[capabilities] content_guard=true`, `net=["<backend host>"]`; `[subscribe] "prompt_builder.v1.stage.content_guard"`; `[publish]` reply grant; `[env]` `guard_proxy_url` + `guard_proxy_token`. Handler POSTs `{messages, session_id, principal}` to the backend guard endpoint; maps verdict → `StageResponse`; **on any HTTP error return `veto`** (inverts personality's fail-open :234-238 — that's the point). Register the capsule dir in `docker/astrid.Dockerfile`'s local-capsule loop (~:94-209). Egress: backend public URL (precedent: openai-compat→`/api/llm`) or a `[security.capsule_local_egress]` entry (`content-guard=["concierge-backend:8787"]`) in the astrid config the entrypoint provisions.
- Backend `backend/src/guard/route.ts` (zero-dep, `node:*`): `POST /api/guard/check`, token-gated, calls the SAME `semantic-firewall.ts` engine as the backend chokepoint, returns `{verdict, messages?, reason?}`. The capsule stage is a second enforcement POINT, not a second engine. `node:test`: allow/rewrite/veto/timeout/401.

### WS5 — build, deploy, live verification  *(only a live deploy catches manifest/env/timing issues)*
1. `cd backend && npm run typecheck && npm test`; `cargo check` each touched capsule in the rust:1.95 docker builder (host cargo too old).
2. `docker compose build astrid` (patches 0001–0005 must apply), deploy to a **staging** stack, never prod first.
3. Verify in order: `blocking_stages` unset → chat works, additive injections present, latency unchanged; `=content_guard` + healthy → benign passes, seeded injection rewritten (inspect via `/api/llm` logs), veto input → refusal not a 120 s stall; **kill the guard endpoint** → next turn refused within ~`stage_timeout_ms`, react returns to Idle (follow-up turn proves no wedge); per-principal `blocking_stages` write round-trips (read back — silent-404 channel).
4. Rollout: global flag off in `.env` → staging on → UAT soak → prod; flag = instant rollback (no rebuild to disable).

## (d) Sequencing, risk, cost/benefit
**Backend first, unchanged.** The backend ingestion-seam + `/api/llm` egress guard ships with no astrid rebuild, covers all LLM-bound bytes incl. mid-turn results, and hosts the real ML engine. The blocking stage is **defense-in-depth**, worth building second: (i) enforces even if `LLM_PROXY_TOKEN` is unset/reverted (the one residual `/api/llm` bypass); (ii) gives the platform a reusable veto/rewrite primitive (consent, quota, quarantine); (iii) the react veto handling fixes an existing latent bug (`error` assemble responses degrade instead of aborting). Order: backend guard → WS1-3+5 → WS3 Phase 2 only if in-runtime mid-turn coverage without the proxy token is required.

**Risks:** availability coupling (fail-closed = a guard outage refuses every turn — mitigate with the global kill-switch, the 2 s per-stage ceiling ~4-18% worst-case vs 11-50 s turns, and veto/timeout monitoring before prod); patch drift (0005 joins 0001-4 needing rebase on ASTRID_REF bumps — loud, Dockerfile fails on conflict); dispatch drops under storm (full queue → fail-closed refusal, user-visible under extreme load; watch `astrid_bus_receiver_lagged_total`). **What it does NOT change:** the capsule still cannot host semanticd's ML tier (`ort`/YARA/tokio don't compile to the capsule target); the stage's detection power is exactly the backend engine it proxies to — it buys **placement, not detection**.

**Bottom line:** the prior investigation's closing condition is satisfiable **today**, mostly in code this repo already owns, with one five-line kernel patch through an already-proven pipeline, at ~4–6 Opus-agent-days + a staging soak. Do the backend chokepoint first; then build this.
