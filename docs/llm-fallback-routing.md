# LLM fallback routing for Claude Code (main-thread provider failover)

**Status:** DESIGN — off by default, no keys wired. Opt-in per operator.
**Date:** 2026-08-18. **Author:** coordinator (Claude Opus 4.8).

## The problem

Anthropic's API has occasional multi-hour capacity outages (429/529 storms). Our
[outage-resilience config](../claude_conf/settings.json) (`CLAUDE_CODE_RETRY_WATCHDOG=1`)
makes a session *wait out* such an outage by retrying 429/529 **indefinitely**. That keeps
work correct but makes the session **unresponsive** for the whole blackout — the orchestrator
can't even think.

The owner's requirement is stronger for the **main orchestration thread only**: if the
Anthropic (Sonnet) backend is failing, the main thread should **fall back to a non-Anthropic
model** (OpenAI GPT, or Kimi via OpenRouter) so the orchestrator *stays alive and responsive*
through the outage. **Sub-agents (Task/Agent tool) must stay Anthropic-only** — they run the
real coding/reasoning work where a weaker cross-provider model would degrade quality, so they
should simply wait for Anthropic to recover (the watchdog covers them).

## The hard constraint that shapes the whole design

**Claude Code cannot tell a proxy which requests are "main thread" vs "sub-agent."** Both the
main loop and every in-process sub-agent hit the **same** `ANTHROPIC_BASE_URL` with the same
auth. There is no header, path, or metadata field that distinguishes them at the HTTP layer.

Therefore the *only* discriminator available to a proxy is the **model id in the request
body**. So the design reduces to a **model-tier routing convention**:

| Model id in request | Who uses it | Routing policy |
|---|---|---|
| `claude-sonnet-*` | **main orchestration thread** (per our CLAUDE.md, Sonnet orchestrates) | Anthropic first → **fail over** to OpenAI / OpenRouter-Kimi |
| `claude-opus-*`, `claude-fable-*` | sub-agents (real coding / heavy reasoning) | **Anthropic-only** (retry, never cross-provider) |
| `claude-haiku-*` | Claude Code background chores (title-gen, etc.) | **Anthropic-only** (retry) |

This composes cleanly with our existing model-routing doctrine (`.claude/CLAUDE.md`: "Sonnet
orchestrates; sub-agents get Opus/Fable"). It has **one operational constraint**:

> **Sub-agents must never run on Sonnet** while the router is active — otherwise their
> requests are indistinguishable from the main thread and would also fail over to the
> non-Anthropic provider. Route sub-agents to Opus/Fable/Haiku only. (This is already the
> recommended default; the router just makes it load-bearing.)

If a task genuinely wants a Sonnet sub-agent, either accept that it is failover-eligible, or
give it a distinct alias model id that the router pins to Anthropic-only (see "Escape hatch").

## Tool choice: LiteLLM (recommended) vs claude-code-router

The requirement is **provider failover on primary error**. Two proxies can sit at
`ANTHROPIC_BASE_URL`:

### LiteLLM proxy — recommended for this requirement
- **First-class per-model `fallbacks`**: `fallbacks: [{"claude-sonnet": ["gpt-4o", "kimi"]}]`
  — on primary error (incl. 429/529/timeout) LiteLLM transparently retries the next model in
  the list. Models with **no** fallback entry stay on their single provider. This is exactly
  the model-tier policy above, expressed declaratively.
- Exposes an **Anthropic-format `/v1/messages` endpoint**, so Claude Code can point
  `ANTHROPIC_BASE_URL` straight at it and keep speaking the Anthropic wire format; LiteLLM
  translates to OpenAI/OpenRouter schema for the fallback providers.
- Also gives retries, timeouts, and `context_window_fallbacks` (fall back to a bigger-context
  model on overflow) for free.
- Cost: one extra Python service (`litellm[proxy]`). Runs locally on `:4000`.

### claude-code-router (musistudio) — viable alternative
- Category router (`default` / `background` / `think` / `longContext`) + Anthropic↔OpenAI
  **transformers**. Good at *steering* categories to providers, but **provider failover on
  error is not its core feature** — you'd write a **custom JS router** that catches the
  Anthropic error and re-dispatches to the fallback provider. More code, more moving parts.
- Choose this only if you already run it for other reasons.

**Recommendation: LiteLLM**, because the ask is failover and LiteLLM does failover natively.
The example config in this folder is LiteLLM; a claude-code-router sketch is in the README
appendix.

## Interaction with the outage watchdog (important)

The watchdog (`CLAUDE_CODE_RETRY_WATCHDOG=1`) and the fallback router are **two different
philosophies** and partially **conflict**:

- **Watchdog** = *wait* on Anthropic (retry 429/529 forever, client-side).
- **Router** = *switch providers* fast (fail the Anthropic attempt quickly at the proxy, then
  try OpenAI/Kimi).

If the watchdog retries Anthropic forever, a request **never returns an error** to the proxy,
so the router's fallback is never triggered. Reconcile them by **layer of responsibility**:

- The **proxy** owns fast-fail + failover for the **main thread** (`claude-sonnet-*`): give
  the proxy a short per-attempt Anthropic timeout so it can move on to the fallback provider.
- The **watchdog** owns *waiting* for the **sub-agent tiers** (`claude-opus/fable/haiku-*`),
  which the proxy pins to Anthropic-only — those requests ride out the outage as before.

Net effect during an Anthropic blackout: the **orchestrator keeps thinking** (on GPT/Kimi),
while **heavy sub-agent work pauses** and auto-resumes when Anthropic returns. That is exactly
the owner's intent.

## Quality caveats (why sub-agents stay Anthropic-only)

- A non-Anthropic fallback model runs the **orchestration** loop only — planning, reading
  results, deciding what to delegate. That is comparatively model-robust.
- Tool-call and long-context fidelity differ across providers even after schema translation;
  **do not** route real coding/refactor/security work through the fallback. That is the whole
  reason sub-agents are pinned to Anthropic.
- Treat fallback mode as **degraded/survival mode**, not steady state. When Anthropic
  recovers, the main thread transparently returns to Sonnet (LiteLLM tries the primary first
  every request).

## Enablement (off by default)

`setup.sh` **does not** install or launch any proxy and ships **no keys**. To turn this on, an
operator follows [`../claude_conf/llm-fallback-router/README.md`](../claude_conf/llm-fallback-router/README.md):
install LiteLLM, fill the provider key slots, launch the proxy, and set `ANTHROPIC_BASE_URL`.
Until then this is documentation + an example config only.

## Escape hatch: a pinned-Anthropic Sonnet for sub-agents

If you must run a Sonnet sub-agent that should NOT fail over, expose a second model alias in
the proxy (e.g. `claude-sonnet-pinned`) mapped to Anthropic with **no** fallback, and have
that sub-agent request that id. The main thread keeps using the plain `claude-sonnet-*` id
that carries the fallback list.
