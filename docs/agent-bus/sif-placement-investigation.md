# SIF placement — capsule runtime vs backend chokepoint (Fable investigation)

**Question investigated:** should the Semantic Firewall (SIF / `semanticd`) run as an in-runtime
AstridOS capsule (an always-on stage that "cannot be turned off"), or as a backend module calling
an external SIF service? Produced by a Fable investigation, 2026-07-22, against the live Concierge
capsule/astrid code and the `unicitynetwork/semanticd` source.

---

## Verdict: SIF placement — capsule runtime vs backend chokepoint

**Bottom line up front:** The critique of the prior reasoning is valid — "a capsule is an opt-in LLM tool" was an incomplete characterization, because capsules do have mandatory, non-LLM-invoked lifecycle hooks (`before_build` fires on every prompt assembly). But the proposed architecture (SIF as an in-runtime capsule filter) is wrong on the current platform, for three independently fatal reasons: (1) the only mandatory capsule hook is **additive-only and cannot modify, redact, or veto content**; (2) that hook is **fail-open by construction** (a 250 ms first-response window silently drops slow responders — this exact mechanism caused a real production bug); (3) the SIF detection engine **cannot run in the WASM sandbox** (native ONNX Runtime, YARA-X, tokio, ~1.4 GB ML workers). Meanwhile the Concierge backend already possesses a chokepoint strictly stronger than anything a capsule can offer: **every LLM request of every turn transits the backend's `/api/llm` router**, including mid-turn tool results that never touch any other backend seam. The prior recommendation's conclusion stands — for better reasons than it originally gave.

---

## 1. What an AstridOS capsule can actually do — the full extension-point inventory

Enumerated from the 36 capsule manifests in `/home/vrogojin/concierge/capsules/` and the prompt-builder source:

| # | Extension point | Mandatory or opt-in? | Evidence |
|---|---|---|---|
| 1 | **LLM tools** (`tool.v1.execute.<name>` + describe fan-out) | **Opt-in** — the model chooses to call; further gated per-principal by the capsule access gate (astrid#993 — ungranted tool calls hang the turn) | e.g. `capsules/conversation-memory/Capsule.toml` `[subscribe]` |
| 2 | **`before_build` prompt hook** (`prompt_builder.v1.hook.before_build`) | **Mandatory-fire** — prompt-builder publishes it to all subscribers on *every* prompt assembly, LLM has no say | `capsules/prompt-builder/src/lib.rs:366-395`; used by personality, current-awareness, conversation-compactor, structural-memory |
| 3 | **`after_build` event** | Mandatory-fire, **notification only** (no response consumed) | `lib.rs:16, 161-168` |
| 4 | **Passive turn observers** (`user.v1.prompt`, `agent.v1.response`, with subscriber `priority`) | Mandatory delivery, **non-blocking by design** — "fire-and-forget and swallow their own errors, so a capture failure can never break a turn"; priority 200 deliberately runs *after* the react loop's 100 | `capsules/conversation-memory/Capsule.toml` capture block; same in structural-memory |
| 5 | **Per-principal env** (`[env]` + gateway env-write API) | Config channel, not an execution hook; gateway **404s any undeclared field and the backend only warns** -> silent failure class | prompt-builder `Capsule.toml` `[env]` comments; CLAUDE.md gotcha #2 |
| 6 | **Capabilities** (`net`, `allow_prompt_injection`) + pub/sub ACLs | Static grants in the manifest; the host *strips* prompt-mutating hook fields from capsules lacking `allow_prompt_injection` | `lib.rs:205-236` (`filter_hook_responses`) |

**The crux question — can a capsule be a mandatory filter over content entering the turn? No.** The `before_build` hook response type is exhaustively (`lib.rs:136-149`):

```rust
struct HookResponse {
    prepend_system_context: Option<String>,
    append_system_context:  Option<String>,
    system_prompt:          Option<String>,   // full override, last-non-null wins
    prepend_context:        Option<String>,   // prepended to the user message
}
```

The hook *receives* the conversation `messages` (`BeforePromptBuildPayload`, `lib.rs:113-128`) but can only **add** text or replace the *system prompt*. There is no field to rewrite messages, no redaction path, no veto/abort. A capsule SIF could see an injected payload and at best append "warning: the following is suspicious" — it cannot strip the payload, cannot block the turn, and cannot stop the LLM call from proceeding. The claimed "always-on stage that filters content" **does not exist as a capsule extension point today**.

And the hook is **fail-open with hard timing walls** (`lib.rs:172-192, 401-437`): a 250 ms first-response window (`HOOK_FIRST_RESPONSE_MS`), 100 ms idle grace, 2 s outer cap — a responder that misses the window is *silently excluded* and the turn proceeds without it. This is not hypothetical: the July 9 "personality won't persist" incident was exactly this race dropping the HTTP-fetching injection plugins in production (memory: personality-injection-race; fix was widening the windows to 3000/1500/5000 ms, not making them blocking).

## 2. Where untrusted content enters a principal's runtime

Traced entry paths:

| Untrusted source | Path into the turn | Earliest mandatory chokepoint |
|---|---|---|
| **Cross-agent DM (A2A)** | Backend `POST /api/agent-message` -> store -> `a2a/inject.ts` `injectAgentMessage()` -> `buildProvenanceSeed()` wraps body in trust framing -> `astrid.prompt()` seeds a turn (`backend/src/a2a/inject.ts:50-82, 286-350`) | **Backend**, before AstridOS ever sees it |
| **IMAP mail body** | mailbox capsule -> backend proxy (`backend/src/imap/`) -> tool result | Backend |
| **Uploads (PDF/CSV/images)** | `backend/src/uploads/` -> manifest -> prompt | Backend |
| **Fetched URL / web search / browser page** | `http` and `web-search` capsules fetch **directly** (`net = ["*"]`, astrid:http airlock — `capsules/http/Capsule.toml:14`) -> tool result -> react loop -> next LLM request. **Never transits a backend ingestion seam.** | Only the LLM egress router (below) |

The decisive discovery: **the backend is the LLM egress for every turn.** When `LLM_PROXY_TOKEN` is set (it is, in this stack's `.env`), `configureLlm` points the openai-compat capsule's `base_url` at the backend's router (`backend/src/astrid/live.ts:125-139`, `config.ts:240` — `LLM_PROXY_URL` default `https://.../api/llm`), and every react-loop iteration — including the requests carrying capsule-fetched tool results — arrives at `POST /api/llm/v1/chat/completions` (`backend/src/app.ts:2303-2387`) before any provider sees it. This route sees the **complete message array of every LLM call**. No capsule hook sits earlier than the ingestion seams, and *no* seam — capsule or backend — is more universal than this one.

So the untrusted-content->LLM path has **two backend-owned chokepoints**: per-source ingestion seams (A2A/IMAP/uploads — where quarantine and per-sender policy belong) and the universal `/api/llm` egress (which catches what the seams can't, e.g. `fetch_url` results). A capsule `before_build` hook sits *later* than the ingestion seams, *earlier* than nothing, and can modify nothing. This matches the design.md §6.1 call-site plan — except design.md missed the `/api/llm` catch-all, which materially strengthens the backend option.

## 3. Can the SIF engine run inside a WASM capsule?

Primary evidence from `unicitynetwork/semanticd` (Cargo manifests fetched via `gh api`, v0.1.7) plus `research/03-semanticd-reference.md`:

semanticd is a **hybrid** engine: Aho-Corasick + regex rules, ONNX ML classifiers (prompt-injection + jailbreak), DLP regex/Luhn, optional YARA-X. Workspace deps: `ort = "2.0.0-rc.11"` (ONNX Runtime), `tokenizers`, `yara-x = "1.6"`, `tokio` (full), `sqlx`/Postgres, `deadpool-redis`, `axum`. `semd-engine` features: `ml = ["dep:ort", "dep:tokenizers", "dep:ndarray"]`, `yara`; `aho-corasick` and `regex` are non-optional.

Feasibility by tier:

- **Rules/regex/DLP tier:** `aho-corasick` + `regex` compile to wasm32 in principle. But `semd-engine` as written is tokio/`async-trait`/`flume`/`bumpalo`-structured — embedding it in an astrid capsule (astrid_sdk runtime, `getrandom` custom, no threads, no tokio) means a **fork-and-port**, not a reuse. Feasible with real effort; you'd get roughly the `low-latency-cascade` Stage-1 detectors.
- **ML tier: infeasible.** `ort` binds the native ONNX Runtime C++ library — it does not compile to `wasm32-unknown-unknown`. The deployed classifiers need ~1.4 GB RAM of pooled workers (1024 MB + 384 MB) and 4 intra-op threads each (R3 §5); the sub-20 ms p99 depends on native SIMD/threads. `tract`/`candle` could theoretically run small models in WASM, but hundreds of MB of model weights baked into a `.capsule`, single-threaded, inside a sandboxed per-turn hook is not a serious deployment. Also unavailable in WASM: YARA-X, the Postgres audit trail, Redis rate-limiting.
- **Hot-reload: destroyed.** semanticd hot-reloads rules via Postgres->Redis pub/sub->`ArcSwap` with zero restart (R3 §4). A baked capsule requires **rebuild capsule -> rebuild astrid image -> redeploy** for every rule update (CLAUDE.md gotcha #2), or smuggling rule strings through per-principal declared `[env]` fields — a channel whose documented failure mode is a *silent* 404 leaving the stale baked default in place. For a security control whose value is rapid rule response to new attack patterns, this is disqualifying on its own.
- **Note:** `semd-sdk`'s "compiles to WASM" is a *client* (wasm-bindgen/web-sys/gloo-net, browser/Node) — it calls the service over HTTP; it is not the engine in WASM, and its JS bindings don't even fit the astrid capsule runtime.

**Conclusion: at most a degraded, rules-only, hot-reload-less fork of the SIF could live in a capsule. The actual detection engine cannot.**

## 4. Is "cannot be turned off" true for a capsule? No — and the backend chokepoint is strictly stronger

Honest trust-boundary accounting:

**The capsule option is governed by exactly the config machinery the user hopes to escape:**
- Per-principal **grants** (astrid#993): capsule availability is provisioned per principal — by the backend, via `system.token`.
- **`[env]` declaration mechanics**: any per-principal configuration (proxy URL, token, rule tuning) rides the env-write API whose undeclared-field failure is a silent 404 + backend warning — the documented `tool_denylist` bug class where "PAYMENTS_ENABLED=false reported success while the money tools stayed advertised" (CLAUDE.md).
- **Capability stripping**: without `allow_prompt_injection`, the host discards the hook's prompt-mutating fields (`lib.rs:205-236`) — an image/manifest change silently neuters it.
- **The timing race**: even fully granted and configured, a hook that misses the 250 ms window is dropped and the turn runs unguarded — the *fail-open* posture is baked into the host, and it has already fired in production once.
- And the deepest point: per `docs/astrid-integration-a1.md:49-54`, **the backend holding `system.token` is "root-equivalent over all principals" and "fully trusted."** The backend is already the TCB root — it creates principals, grants capsules, writes capsule env, and bakes the astrid image. A capsule cannot be more mandatory than the entity that installs and configures it. Moving the SIF into a capsule doesn't shrink the TCB; it *adds* the hook fan-out, IPC bus, env-write API, and image pipeline to it.

**The backend chokepoint**: an in-process guard in `injectAgentMessage()` / `/api/llm` is a single synchronous code path — no timing window, no grant table, no env write, no image rebuild. It can genuinely **fail closed**: on SIF error/timeout, refuse the turn with the repo's truthful-503 pattern (design.md §6.1 already specifies fail-closed for A2A traffic, correctly deviating from R3's fail-open sketch). Is it "bypassable if placed at prompt-assembly"? A guard *only* at the A2A/IMAP/upload seams misses capsule-side fetches — but the `/api/llm` egress closes that hole for every byte that reaches the model. The one residual bypass of `/api/llm` is configuration (someone unsetting `LLM_PROXY_TOKEN` reverts capsules to direct Moonshot) — but note that the equivalent misconfiguration in the capsule option (a failed env write) fails *silently*, whereas the router token is one env var whose absence is visible at `/api/llm/health` (`app.ts:2391`) and monitorable.

**Which is simpler, stronger, harder to misconfigure? The backend chokepoint, decisively** — one process, one code path, fail-closed on purpose rather than fail-open by platform design.

## 5. Trade-off matrix and verdict

| Dimension | **(A) SIF in a WASM capsule** | **(B) Backend module -> sidecar/hosted SIF** (prior rec) | **(C) Hybrid: `before_build` hook calls out to SIF** |
|---|---|---|---|
| Enforcement guarantee | **Illusory** — hook is additive-only (can't redact/block), fail-open on 250 ms race, governed by grants/env/capabilities | **Strong** — synchronous in-process gate; fail-closed implementable; `/api/llm` covers *all* LLM-bound content | Worst of both — inherits the hook's can't-block + fail-open, plus a network hop inside the hook window |
| Detection power | Rules-only fork; **no ML, no YARA** (native deps) | Full hybrid engine, tuned policies, `low-latency-cascade`/`mission-critical` | Full engine, but verdict unenforceable (can only append warnings) |
| Hot-reload of rules | **Lost** — capsule + astrid image rebuild per rule change; env-string smuggling fails silently | Native (Postgres->Redis->ArcSwap, no restart) | Native |
| Latency | Unknown WASM perf, single-threaded; sits in the per-prompt hook window | ~25 ms p99 against 11-50 s turns; batch endpoint available | SIF p99 + public-domain HTTP round-trip (airlock blocks compose-private IPs) inside a 250 ms-3 s window -> guarantees drops |
| Per-principal isolation/policy | Via per-principal env (silent-404 channel) | Backend call site knows the principal; picks `policy_id` per source/risk | Via env, same fragility |
| Availability / fail-closed | Fail-open by host design | Choose per path: fail-closed for A2A/auto-exec, monitored `degraded` flag | Fail-open, unavoidably |
| Zero-runtime-dep rule | N/A (Rust side) but new capsule to maintain | **Perfect fit** — plain `fetch`, no npm dep, no exception needed (R3 §8B) | Both burdens |
| Capsule gotchas exposure | Full: flat schemas (if tools added), `[env]` declaration, rebuild-to-deploy, grant stalls | None | Full |
| Operational/upgrade complexity | Fork of semanticd tracked forever; redeploy astrid per rule update | `SIF_URL`+`SIF_API_KEY` env; Unicity already runs `sif.unicity.network` in prod | Service ops **plus** capsule ops |

### Verdict

**The user is wrong on the architecture, right about the flaw in the prior argument.** The prior rec's stated reason ("a capsule is a tool the LLM chooses to call") was incomplete — `before_build` proves capsules can act every turn without the LLM's consent. But the correct reasons all point the same way as the prior conclusion: the mandatory hook that exists **cannot filter** (additive-only), **cannot be relied on** (fail-open timing), and **cannot host the engine** (native ML/YARA/tokio, no hot-reload). A separate HTTP service is not overkill; it is the only placement where the engine's ML tier, hot-reloadable rules, audit trail, and a genuine fail-closed guarantee are all simultaneously achievable — and it costs one `fetch` under the zero-dep rule against an already-running hosted instance.

**Recommended architecture (Concierge):**
1. **`backend/src/a2a/semantic-firewall.ts`** guard module (plain `fetch`, `AbortSignal.timeout`), **fail-closed** for A2A and any auto-executed path, called at the ingestion seams: `injectAgentMessage()`/`driveConversationReply()` before `astrid.prompt`, IMAP bodies, upload manifests. This is where quarantine, per-sender policy, and `modified_content` redaction belong — per design.md §6.1.
2. **Add the `/api/llm` egress guard** (an improvement over the prior rec): scan the new tail messages of each forwarded completion request in `app.ts:2320` before `forwardChatCompletion`. This is the only seam that catches `fetch_url`/`web-search`/browser content entering mid-turn, and it is the single most mandatory point in the whole system. Use `low-latency-cascade`; treat `degraded:true` as uninspected.
3. **Keep a capsule role — but for framing, not filtering.** A `before_build` contribution injecting the standing `<peer_message>`-style provenance contract into the system prompt (the "P3 prompt-builder provenance section" already anticipated in `inject.ts:10-11`) is exactly what the hook is good at: additive, non-critical, harmless if dropped. That is the legitimate kernel of the user's intuition.
4. **Claude Code side (`claude_unicity_setup`)**: unchanged from design.md — there is no capsule runtime there at all; daemon/hook-layer calls to the hosted SIF plus the envelope quarantine remain correct as designed.

**Conditions under which the user's position would become right:** if AstridOS grew a first-class *blocking* content-pipeline stage — a hook with message-rewrite/veto semantics, guaranteed-delivery (no timing drop), fail-closed on responder error — *and* the rules-only tier were an acceptable detection floor, then an in-runtime SIF stage would be a defensible defense-in-depth layer (still calling out to the sidecar for ML). That is an upstream astrid feature request worth filing; it is not the platform that exists today. Until then: never let the filter's placement depend on the same machinery (grants, env writes, hook windows) whose silent failures are this repo's best-documented bug class.
