# LLM fallback router (main-thread provider failover) — OFF by default

Keeps the Claude Code **main orchestration thread** alive through an Anthropic outage by
failing over to a non-Anthropic model (OpenAI GPT or Kimi via OpenRouter), while **sub-agents
stay Anthropic-only**. Full rationale: [`../../docs/llm-fallback-routing.md`](../../docs/llm-fallback-routing.md).

**`setup.sh` does not install, launch, or key this.** It is opt-in. Nothing here runs until an
operator does the steps below and provides keys.

## Why it's designed the way it is (one paragraph)

Claude Code sends main-thread and sub-agent requests to the *same* `ANTHROPIC_BASE_URL` with
no distinguishing metadata, so the only lever is the **model id**. We therefore route
`claude-sonnet-*` (the main thread) through an Anthropic→fallback chain and pin
`claude-opus-*` / `claude-fable-*` / `claude-haiku-*` (sub-agents + background) to
Anthropic-only. **Consequence: while the router is active, don't run sub-agents on Sonnet** —
use Opus/Fable (already the default).

## Enable it (manual, ~5 min)

1. **Install LiteLLM** (isolated; not a project dep):
   ```bash
   pipx install 'litellm[proxy]'      # or: uv tool install 'litellm[proxy]'
   ```
2. **Copy + fill the config** (keys come from the environment — never inline them):
   ```bash
   cp litellm.example.yaml litellm.yaml
   export ANTHROPIC_API_KEY=...              # your existing Anthropic key
   export OPENAI_API_KEY=...                 # SLOT — set to enable GPT fallback
   # and/or
   export OPENROUTER_API_KEY=...             # SLOT — set to enable Kimi fallback
   ```
   Leave a provider's key unset to disable that fallback leg; the other still works.
3. **Launch the proxy** (local only):
   ```bash
   litellm --config litellm.yaml --port 4000
   ```
4. **Point Claude Code at it** (this shell / session only):
   ```bash
   export ANTHROPIC_BASE_URL=http://127.0.0.1:4000
   # keep ANTHROPIC_API_KEY set — LiteLLM uses it for the Anthropic primary leg
   ```
   Then start Claude Code. The main (Sonnet) thread now fails over on Anthropic errors;
   Opus/Fable sub-agents ride out any outage on Anthropic (helped by the retry watchdog).

## Verify

- Kill/deny Anthropic (e.g. temporarily unset `ANTHROPIC_API_KEY` in the proxy env) and send a
  main-thread turn → it should answer via the fallback provider.
- Spawn an Opus sub-agent under the same condition → it should **fail/retry**, not silently
  answer on GPT/Kimi. That proves the tier pin holds.

## Compose with the outage watchdog

Both can be on at once. Keep the proxy's Anthropic **timeout short** (see `timeout: 30` in the
example) so the main thread fails over quickly; the watchdog (`CLAUDE_CODE_RETRY_WATCHDOG=1`,
in [`../settings.json`](../settings.json)) then only governs the Anthropic-only sub-agent
tiers, which *wait* for recovery. See the design doc's "Interaction with the watchdog" section.

## Security

- **Keys live only in the environment / your secret store** — never in `litellm.yaml`, never
  committed. The example uses `os.environ/...` slots for exactly this reason.
- Run the proxy on **loopback** (`127.0.0.1`) only. If you must expose it, set
  `general_settings.master_key`.
- The fallback providers see your prompts — treat that as a data-egress decision per provider.

## Appendix: claude-code-router alternative

If you prefer musistudio/claude-code-router, it does category routing + Anthropic↔OpenAI
transformers but **not** error-triggered provider failover out of the box — you must add a
**custom JS router** that catches the Anthropic error and re-dispatches to the fallback
provider, keyed on the same `claude-sonnet-*` vs `claude-opus/fable-*` model-tier split. LiteLLM
is recommended because it does the failover declaratively.
