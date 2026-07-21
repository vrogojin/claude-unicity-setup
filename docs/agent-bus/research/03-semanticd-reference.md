# Semantic Firewall (semanticd / SIF Security Gateway v0.1.5) — Integration Reference

Source: `github.com/unicitynetwork/semanticd` (Rust, Apache-2.0), pulled via `gh api` — README.md, all of `docs/*.md`, `config.example.toml`, `semanticd.toml`, `policies/*.yaml`, and sample `rules/*.yaml`. **Everything fetched was readable; nothing was blocked or missing.** Not deep-dived (out of scope for this pass, but present in the repo): `crates/` Rust source, `sdk-wrappers/{python,typescript,go}` implementation code, `rules/yara/*.yar`, `training/`, `dashboard/` React source, `deploy/{nginx,systemd,helm,grafana}/*`.

**Important discovery: this is not just a library to self-host — Unicity already runs it in production.** `docs/operations.md` documents live deployments at `https://sif.unicity.network` (prod) and `https://sif.staging.unicity.network` (staging), both on a Contabo VPS (`75.119.142.140`), fronted by nginx+TLS, backed by Postgres+Redis, with Grafana metrics and daily backups. **Concierge and claude_unicity_setup can likely call the existing staging/prod instance directly rather than standing up new infrastructure** — subject to getting an API key issued (see Deployment section).

---

## 1. Architecture / how it works

```
Client ──► Guard API ──► Detection Pipeline ──► Response
                              │
                    ┌─────────┼─────────────┐
                    ▼         ▼             ▼
              Rule Engine  ML Models    DLP Scanner
              (Aho-Corasick  (ONNX)    (Regex + NER)
               + Regex)
```

9 Rust crates in one Cargo workspace: `semd-core` (types), `semd-engine` (detectors + pipeline), `semd-rules` (YAML rule compilation, hot-reload via `ArcSwap`), `semd-api` (Axum Guard API), `semd-manage` (management API + CRUD + WebSocket events), `semd-db` (SQLx/Postgres), `semd-telemetry` (OTel + Prometheus + audit log), `semd-sdk` (Rust/WASM/C-FFI client), `semanticd` (binary).

Request flow: auth middleware → rate-limit middleware → parse request → **run all configured detectors concurrently** (rule engine, ML classifiers, DLP scanner, optional YARA-X) → signal combiner does weighted scoring → policy engine applies thresholds → response. An optional **short-circuit** mode cancels remaining detectors once one signal crosses a confidence threshold (`futures::select_all`), trading completeness for latency.

Hot-reload: Management API writes a rule/policy change to Postgres → publishes to Redis `rules:updated` channel → a background subscriber reloads + recompiles + atomically swaps the `ArcSwap<CompiledRuleEngine>`. Readers holding the old snapshot finish using it (no locking, no restart).

**It is a hybrid rules+ML engine, not purely one or the other, and it is CPU-only (no GPU requirement).** ML models are pre-trained ONNX (not trained at request time) run via ONNX Runtime (`ort` crate) on CPU threads.

---

## 2. REST API — every endpoint

Base URL: `http://localhost:8080` (Guard API port; management API is a separate port, default 8081).

### Auth
`Authorization: Bearer <api-key>` **or** `X-API-Key: <api-key>` (both accepted; all 4 official SDKs currently send `X-API-Key`). Keys look like `semd_live_...` / `semd_test_...`, issued via the dashboard or management API, shown **once** at creation.

### `POST /api/v1/guard`

Request:
```json
{
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "What's the weather today?"}
  ],
  "policy_id": "strict",
  "config": {
    "return_detections": true,
    "threshold": 0.5,
    "categories": ["pii", "prompt_injection"]
  }
}
```
- `messages[].role`: `system | user | assistant | tool`
- `policy_id` is **top-level**, not nested in `config`. Omitted → server's default policy.
- `config` is fully optional (omit entirely if you don't need `return_detections`/`threshold`/`categories`).
- `config.return_detections` defaults `false` (response `detections` stays empty — do this in production to shrink payload/audit-log size).
- `config.categories` empty/omitted = all categories.

Response (200 OK):
```json
{
  "request_id": "01234567-89ab-cdef-0123-456789abcdef",
  "action": "block",
  "blocked": true,
  "risk_score": 0.92,
  "detections": [
    {"category": "prompt_injection", "confidence": 0.95,
     "description": "Instruction override pattern matched", "rule_id": "pi-direct-001"}
  ],
  "processing_time_ms": 12,
  "policy_applied": "strict",
  "degraded": false,
  "timestamp": "2026-05-08T10:00:00Z",
  "versions": {
    "ruleset": "core-1.4.0",
    "prompt_injection_model": "pi-v2",
    "jailbreak_model": "jb-v2",
    "dlp_model": "dlp-v1"
  }
}
```
- `action`: `allow | flag | modify | block`. `blocked` mirrors `action == "block"`.
- `risk_score`: aggregate 0.0–1.0.
- `degraded: true` means the response is fail-open (a detector errored/timed out) — still HTTP 200, not an error envelope.
- `versions` reports the exact ruleset/model versions that produced the result (log this for reproducibility/audit).

### `POST /api/v1/guard/batch`

Body is a JSON **array** of the same per-request shape (max **10** requests, each ≥1 message); response is an array of `GuardResponse` in the same order. Use this instead of N sequential calls when checking multiple candidate replies/messages at once.

### `POST /api/v1/guard` — Redaction (`action: "modify"`)

When the resolved action is `Modify`, the response includes `modified_content`: the original messages joined, redacted spans replaced with `<ENTITY_TYPE>` placeholders (Presidio convention — `<SSN>`, `<CREDIT_CARD>`, `<EMAIL>`, `<PHONE>`, …), or a fixed mask if configured.
```json
// request: {"messages":[{"role":"user","content":"my ssn is 123-45-6789"}]}
{
  "request_id": "req_…", "action": "modify",
  "detections": [{"category": "pii", "confidence": 0.9, "description": "Rule: pii-ssn-001"}],
  "modified_content": "my ssn is <SSN>"
}
```
Caveats: `modified_content` is the *preprocessed* buffer (whitespace-collapsed, Unicode-normalized) — not necessarily byte-identical to your original; for multi-message requests all messages are joined with a single space (per-message granularity is a stated future revision). If `Modify` is selected but the detector that fired didn't localize a byte span (e.g. a bare ML classifier signal), the server **escalates to `Block`** rather than return unredacted text.

### Health / meta endpoints
| Endpoint | Purpose |
|---|---|
| `GET /healthz` | Liveness. `{"status":"healthy","version":"0.1.0","uptime_secs":3600}` |
| `GET /readyz` | Readiness — 200 with `{"ready":true,"components":{"rules_loaded":true,"rule_count":56,"ruleset_count":5}}`, or **503** with `{"ready":false,"reason":"Rules not loaded",...}` |
| `GET /version` | `{"name":"semanticd","version":"0.1.0","description":"..."}` |
| `GET /status` | Uptime, component health, and the active limits (`max_body_size`, `max_messages`, `request_timeout_ms`, `require_auth`) |

No auth required on any of the four (they're liveness/readiness probes).

### Management API (separate port, default 8081)
Not the "Guard" surface, but relevant for provisioning/ops — routes seen in `docs/operations.md`'s path-split table:
- `POST /manage/auth/login` — `{username,password}` → `{token}` (JWT), the only unauthenticated `/manage/*` route.
- `POST /manage/api-keys` — `Authorization: Bearer <jwt>`, `{"name":"client-foo"}` → issues `semd_live_...` (shown once).
- `GET /manage/auth/me`, `POST /manage/users/<id>/change-password` — self-service account ops.
- `/ws/events` — WebSocket, JWT-authed, real-time events (rule/policy changes push here — this is how the dashboard live-updates).
- `/dashboard*` — embedded React admin UI (`rust-embed`), default creds `admin`/`admin` on a fresh boot (**must** be overridden via `.env` in production — see Deployment).
- CRUD for rules/policies/keys/users lives under `/manage/*` too (full surface not enumerated in the docs I pulled — the dashboard exercises it; a full OpenAPI spec was not found in the fetched file list).

### Error handling (three distinct shapes — SDK/integration code must not assume one JSON schema)
1. **Application errors** (auth/rate-limit/handler validation) → `application/json`, flat: `{"code","message","request_id"?,"details"?}`. `code` ∈ `InvalidRequest | Unauthorized | Forbidden | RateLimited | PayloadTooLarge | InternalError | ServiceUnavailable`.
2. **Framework rejections** (malformed JSON, missing required field, wrong content-type) → `text/plain`, a single human-readable line, **no `code` field**.
3. **Routing rejections** (404, 405) → empty body, no `Content-Type`; 405 carries an `Allow:` header.
4. **Fail-open path**: a detector failure with `fail_mode: open` returns a normal **200** with `action:"allow", degraded:true` — NOT an error envelope. Callers must check `degraded`, not just HTTP status, to know whether a request was actually inspected.
5. **429** carries `Retry-After: <seconds>` header (not a JSON field) plus the `RateLimited` envelope.

Status codes: 200, 400, 401, 403, 413 (body > 1MB), 422, 429, 500, 503, 504.

### CORS
`Access-Control-Allow-Origin` configurable per `security.allowed_origins`; master switch is `server.cors_enabled` (must be `true` or **no** CORS headers are sent regardless of the allowlist — secure default is off).

### Limits
| Resource | Limit |
|---|---|
| Request body | 1 MB |
| Messages/request | 100 |
| Content/message | 100,000 chars |
| Batch size | 10 requests |

### Rate limits (defaults per key)
| Tier | Req/min | Burst |
|---|---|---|
| Free | 60 | 10 |
| Standard | 600 | 50 |
| Enterprise | Unlimited | 500 |

---

## 3. Detection categories & how results are reported

Categories: `prompt_injection`, `jailbreak`, `pii`, `secrets`, `harmful_content`, `data_exfiltration`, `content_policy`.

Every detector emits a `DetectionSignal` → the combiner produces the aggregate `risk_score` and an `action`. Each individual match surfaces in `detections[]` (only when `config.return_detections: true`) as:
```json
{"category":"prompt_injection","confidence":0.95,"description":"Instruction override pattern matched","rule_id":"pi-direct-001"}
```
`rule_id` is present for rule-engine/keyword/DLP-regex hits; ML-classifier signals may omit it (there's no single rule, just a model score). `versions` on the top-level response ties a result to the exact ruleset/model build for audit trails.

Sample rule counts observed in the shipped rulesets (7 YAML files under `rules/`): prompt-injection (11 rules: direct/roleplay/format/encode/context sub-families), pii-detection (financial: credit-card w/ Luhn-style regex + IBAN + ISIN, plus SSN/email/phone etc.), data-exfiltration (system-config extraction, model-info extraction, DB-structure probing via `information_schema`/`pg_catalog`/`sqlite_master` patterns), content-policy (adult/misinfo/impersonation/harassment/academic-dishonesty/spam), harmful-content (cyber/weapons/violence/illegal/CSAM/terror/crime — 17 rules).

---

## 4. Policy model — thresholds, config, hot-reload

Policies are YAML (`policies/*.yaml`), loaded at startup and re-imported (overwriting DB edits to file-sourced policies) **on every restart** — the YAML is authoritative; dashboard edits to a file-sourced policy are marked "edited" and revert unless downloaded and committed back to the repo. Policies created only in the dashboard show "db only" and persist normally.

Per-policy schema (fully documented, field-by-field, in `policies/default.yaml`):
- `id`, `name`, `description`, `is_default` (exactly one policy should be `true`)
- `fail_mode`: `open` (allow through on detector failure/timeout — default) | `closed` (block — for mission-critical)
- `global_timeout_ms`: wall-clock budget for the whole pipeline (tightens, never loosens, the engine-wide `[engine] timeout_ms` cap, default 5000)
- `series_mode`: `exhaustive` (run every stage, combine all signals, decide once — default) | `early_return` (stop at the first decisive stage)
- `stages`: ordered list of `{detectors: [...], decision: {flag, block}}` — empty list = single parallel stage of every enabled detector (legacy "run everything in parallel" behavior)
- `detectors.<id>`: per-detector override — `enabled`, `weight` (multiplier on that detector's signals), `thresholds: {flag, block}` (confidence band, default `{0.50, 0.85}`), `category_overrides`, `allowed_types` (suppress a specific DLP entity type like `PERSON` from the decision, matched case-insensitively — categories are NOT matched this way)

Detector ids you can target: `rule_engine`, `keywords_injection`, `keywords_jailbreak`, `pii_regex`, `secrets_regex`, `dlp_scanner`, `yara` (only with `--features yara`), `prompt_injection_ml`, `jailbreak_ml` (only with `--features ml`).

Three shipped example policies (each only lists fields that *diverge* from `default.yaml`):
- **`default`** — exhaustive, fail-open, all detectors parallel, standard 0.50/0.85 flag/block bands. **Live stopgap note in the file itself**: the two ML classifiers have their `flag` threshold raised to **0.75** (not 0.50) because the ONNX models over-fire on benign text (0.62 FPR on a "notinject" benchmark at 0.50); 0.75 cuts benign false positives ~25–30% at a modest recall cost. Documented as a temporary trade pending model retraining, with rule-engine detectors backstopping recall.
- **`low-latency-cascade`** — `series_mode: early_return`, two ordered stages: Stage 1 = cheap pattern detectors (`rule_engine`, `keywords_injection`, `keywords_jailbreak`, `pii_regex`, `secrets_regex`, `dlp_scanner`) with `decision:{flag:0.50, block:0.85}`; only escalates to Stage 2 (`prompt_injection_ml`, `jailbreak_ml`) when Stage 1 lands in the uncertain 0.50–0.85 band. This is the policy to pick for interactive/low-latency use (like a chat turn gate).
- **`mission-critical`** — `fail_mode: closed`, `global_timeout_ms: 200`, exhaustive (both stages always run — patterns+DLP+YARA first, ML second, purely for ordering not for skipping), ML detector weights amplified to `1.2` (empirically tuned — `1.5` was too aggressive and pushed benign 0.4–0.5 ML confidence into the modify/block band; `1.2` keeps only genuinely confident ≥0.75 ML signals decisive).

Hot-reload mechanics: rule/policy write → Postgres → Redis `rules:updated` pub/sub → background subscriber reload+recompile+atomic `ArcSwap` swap. **No restart needed** for a DB-sourced or dashboard change; a **restart is required** to re-pick-up YAML files (since the startup "conform" step re-imports and overwrites DB rows sourced from files).

Selecting a policy per-call: top-level `policy_id` field on the guard request (see API section). Omit → server default.

---

## 5. Deployment

**Docker image**: `semanticd/semanticd:latest` (public quickstart) or, for the actual live Unicity deployment, the private `ghcr.io/unicitynetwork/unicity-semanticd:latest` (GHCR, auth required). Built from a multi-stage `Dockerfile`; ONNX models are **baked into the image at build time** — production never trains/downloads at runtime.

**Ports**: `8080` Guard API, `8081` Management API + embedded dashboard, `9090` metrics (Prometheus `/metrics` — **container-network only**, never published to the host in the prod compose; scraped by a Grafana Alloy sidecar which remote-writes to a self-hosted Prometheus at `metrics.unicity.network`).

**Dependencies**: PostgreSQL (rules/policies/API-keys/users/audit-log persistence, SQLx migrations, `run_migrations=true` default — leave on) and Redis (rate-limit backend + pub/sub for hot-reload; Redis state is *not* backed up — it's recoverable transient state). `docker-compose.prod.yml` bundles Postgres+Redis+semanticd+Alloy sidecar; `docker-compose.yml` (dev) does the same minus Alloy/backups.

**Resource needs — CPU only, no GPU**. ONNX inference runs on CPU threads (`ort` crate). Sizing knobs: `models.onnx_threads` (intra-op threads per inference call, default 4), `pool_size` per model (parallel inference workers, default 1 each for `prompt_injection`/`jailbreak`), `queue_capacity` (in-flight admission queue, default 2 — full queue → immediate HTTP 503, no partial-progress rejection). Default footprint targets a **small pod (~2GB/2vCPU)**: ~1.4GB RAM (1024MB `prompt_injection` + 384MB `jailbreak` worker), ~8 ORT threads peak. Rule: keep `Σ(pool_size × onnx_threads) ≤ logical_cores − tokio_worker_threads` or ML inference starves the tokio HTTP runtime and `/healthz` p99 spikes from ~7.6ms to ~360ms (measured), which then fails k8s liveness / LB health checks. You can run **rule-only** (no `ml` feature compiled in) for a much lighter footprint if you don't need the ONNX classifiers.

**Latency claims**: README markets sub-20ms p99 / >10,000 req/s; the formal targets are p50 <10ms, p95 <15ms, p99 <25ms. Both rule-engine (Aho-Corasick, O(n) regardless of pattern count) and DLP-regex paths are the fast tier; ML inference is the tail-latency driver, which is exactly why `low-latency-cascade` exists (skip ML unless the cheap tier is uncertain).

**Config**: `config.toml` (canonical; copy from `config.example.toml`). Load order: built-in defaults → `/etc/semanticd/config.toml` → `./config.toml` → `--config <path>` → env vars (`SEMANTICD_...` / nested `SEMANTICD__SECTION__KEY`) → explicit CLI flags. **Gotcha documented in `getting-started.md`**: `cargo run` env override uses **double** underscore (`SEMANTICD__DATABASE__URL`) — single-underscore `SEMANTICD_DATABASE_URL` is silently ignored by the `config` crate. Docker Compose passes the single-underscore CLI-flag form (`SEMANTICD_DATABASE_URL`) correctly because compose wires it as a direct CLI env mapping, not the nested-config form — don't mix the two conventions.

**Live prod/staging topology** (from `docs/operations.md`, dated 2026-05-08/05-26): host `75.119.142.140`, prod `sif.unicity.network:8080/8081` behind nginx+Let's Encrypt, staging `sif.staging.unicity.network:8090/8091` as a fully parallel `docker compose -p` stack (own DB/Redis volumes, own admin creds, auto-deployed on every push to `main` via GitHub Actions). Daily Postgres backups (7 daily/4 weekly/6 monthly retention) on prod only; staging is ephemeral. Getting an API key: log into `https://sif.unicity.network/dashboard` (or `.staging.`) → API Keys → New, or via the `/manage/auth/login` + `/manage/api-keys` curl flow shown in section 2.

---

## 6. PII / DLP capabilities (for redacting secrets in agent messages)

DLP scanner = regex + Luhn validation for structured PII, backstopped by an optional ONNX NER model for unstructured PII (person names — see `pii_regex`/`dlp_scanner` detector ids; the NER model path `models/dlp_ner/model.onnx` is declared in `config.example.toml` but explicitly **unused today** — "DLP scanner uses regex/keyword rules; this model is not loaded at startup").

Shipped `rules/pii-detection.yaml` covers (financial-focused, sample of what's present): credit-card numbers (Visa/MC/Amex/Discover regex, `score: 0.95`, tagged `pci-dss`), bank account numbers (keyword-gated composite match — requires both an account-context keyword AND a numeric pattern to reduce false positives), IBAN (both compact and spaced formats, country-code-anchored + keyword-gated), ISIN/securities identifiers (keyword-gated to avoid bare 12-char-uppercase false positives) — plus (per README/threat-model, category `pii`/`secrets`) SSN, email, phone, and (category `secrets`) AWS access keys (`AKIA[0-9A-Z]{16}`), JWTs (`eyJ...`), generic API keys/passwords/tokens.

Redaction (`action: "modify"`): default replacement convention follows **Microsoft Presidio** — `<ENTITY_TYPE>` tags (`<SSN>`, `<CREDIT_CARD>`, `<EMAIL>`, `<PHONE>`, etc.). Configurable in `config.toml`:
```toml
[redaction]
mode = "tag"                    # "tag": per-span <ENTITY_TYPE>; "mask": fixed replacement everywhere
default_replacement = "<REDACTED>"
[redaction.replacements]
CREDIT_CARD = "[CC]"
SSN         = "[SSN]"
```
Caveat repeated from section 2: redaction escalates to full `Block` if the triggering signal has no byte span (bare ML classifier flag) — it will never silently pass through unredacted content it can't precisely locate. Multi-message requests get flattened to a single joined+redacted string, not per-message structure (a known, documented gap — `redactions-review.md` referenced as future work).

`policies/default.yaml` deliberately does **not** allow-list `PERSON` in `dlp_scanner.allowed_types`, because a bare person name scores 0.75 (lands in the Modify band) and the authors consider that the *desired* behavior (a name alone should get redacted) — worth knowing if you want looser behavior for names in agent-to-agent chatter.

---

## 7. Limitations / false-positive posture / what it does NOT catch

From `docs/threat-model.md` (explicit "Limitations" section) + `policies/default.yaml` comments:

1. **No guarantee of 100% detection** — novel/obfuscated attacks can bypass both rule-based and ML detection.
2. **False positives are real and currently non-trivial for the ML tier**: the shipped prompt-injection/jailbreak ONNX classifiers show a 0.62 false-positive rate on benign ("notinject") text at the naive 0.50 threshold; the shipped default policy works around this by raising the ML `flag` threshold to 0.75 as a stated stopgap, not a fix — "the real fix is retraining these models on hard benigns."
3. **Input-only** — Semantic Firewall inspects prompts/messages going *into* the LLM. **It does not monitor LLM output** by design ("output monitoring is a separate concern") — so if you need to also screen what your agent *sends back* to another agent/human, you must call `/api/v1/guard` a second time on the outbound text yourself.
4. **English-centric ML models** — non-English injections rely more heavily on the rule engine; ML coverage for other languages is weaker.
5. **Multi-turn / gradual escalation attacks** — the risk matrix rates coverage "Low" here; each `/api/v1/guard` call is stateless per-request, so cross-turn pattern detection is not built in (you'd need to feed conversation history into `messages[]` yourself, and even then the docs flag this as weak coverage).
6. **Latency/completeness trade-off is explicit and tunable** — `short_circuit` / `early_return` cascades intentionally skip the expensive ML tier when cheap detectors are already confident either way; if you want maximum recall you must use an exhaustive policy (e.g. `mission-critical`) and accept the latency cost.
7. Evasion techniques it's designed to counter (Unicode homoglyphs, base64/hex/ROT13/URL encoding, zero-width chars, markdown/HTML hiding) are addressed via a documented `transform_then_match` rule type and a preprocessing normalize/decode step — but this is pattern-based countermeasure, not a formal guarantee.
8. Risk matrix bottom line: direct injection and DAN-style jailbreaks = "High" coverage; indirect injection (malicious text embedded in retrieved documents/tool output) and novel jailbreaks = "Medium"/"Low-Medium"; secret leakage (regex-detectable, e.g. AWS keys) = "High"; PII in free-text/unstructured names = "moderate" without the (currently unwired) NER model.

**For the Unicity Nostr-bus use case specifically**: category 3 above (output-only-not-covered) and category 5 (multi-turn weak coverage) are the two most load-bearing limitations — a semanticd sidecar in front of `/check-messages` catches indirect prompt injection embedded in an inbound DM's body (its actual design target), but it will *not*, by itself, catch a slow-drip multi-message social-engineering campaign across many DMs unless you deliberately replay recent conversation history into `messages[]` on each check, and it says nothing about what the *responding* agent is about to send unless you also guard the outbound reply.

---

## 8. Integration sketches

### A. Bash hook (e.g. `on-dm.sh` in claude_unicity_setup, gating a raw inbound Nostr DM before it's written to `agent-messages.json`)

```bash
#!/usr/bin/env bash
set -euo pipefail

SIF_URL="${SIF_URL:-https://sif.staging.unicity.network}"
SIF_API_KEY="${SIF_API_KEY:?SIF_API_KEY not set}"
SENDER_NPUB="$1"
BODY="$2"   # raw message text from Nostr gift-wrap decrypt

resp=$(curl -sS -X POST "$SIF_URL/api/v1/guard" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $SIF_API_KEY" \
  -d "$(jq -nc --arg body "$BODY" \
    '{messages:[{role:"user",content:$body}], policy_id:"low-latency-cascade", config:{return_detections:true}}')")

action=$(jq -r '.action' <<<"$resp")
degraded=$(jq -r '.degraded // false' <<<"$resp")

case "$action" in
  block)
    echo "BLOCKED inbound DM from $SENDER_NPUB: $(jq -c '.detections' <<<"$resp")" >&2
    exit 1   # hook aborts — message never reaches agent-messages.json / Claude's context
    ;;
  modify)
    BODY=$(jq -r '.modified_content' <<<"$resp")
    ;;
  flag)
    echo "FLAGGED inbound DM from $SENDER_NPUB (allowed through, logged): $(jq -c '.detections' <<<"$resp")" >&2
    ;;
esac
if [ "$degraded" = "true" ]; then
  echo "WARNING: semanticd degraded (fail-open) on this message — unscanned" >&2
fi

# ... proceed to write $BODY into agent-messages.json as today
```
Use `low-latency-cascade` for interactive DM gating (fast path decides most messages without paying ML latency); reserve `mission-critical` for anything that will be auto-executed (e.g. a message that triggers an autonomous tool call) rather than just displayed.

### B. Concierge backend (zero-runtime-dependency constraint — `node:*` only, sanctioned deps lazily imported through a non-literal specifier)

Semanticd needs **no new npm dependency** — it's a plain HTTP sidecar call, so it fits the zero-dep rule natively (unlike `@unicitylabs/sphere-sdk` or `@noble/*`, it doesn't even need the "isolated module + lazy import" exception, since `fetch` is a Node built-in). Still isolate it in its own module for consistency and testability, per repo convention:

```typescript
// backend/src/semanticFirewall.ts
export interface GuardVerdict {
  action: 'allow' | 'flag' | 'modify' | 'block';
  riskScore: number;
  modifiedContent?: string;
  degraded: boolean;
  detections: Array<{ category: string; confidence: number; description: string; ruleId?: string }>;
}

const SIF_URL = process.env.SIF_URL;         // e.g. https://sif.staging.unicity.network
const SIF_API_KEY = process.env.SIF_API_KEY;
const SIF_POLICY = process.env.SIF_POLICY_ID ?? 'low-latency-cascade';

// Returns null (fail-open, logged) if SIF_URL/SIF_API_KEY are unset — mirrors the
// sphere.ts / signing.ts pattern: absent config -> 503-style soft-disable, not a crash.
export async function guardMessage(
  content: string,
  opts: { policyId?: string; returnDetections?: boolean } = {},
): Promise<GuardVerdict | null> {
  if (!SIF_URL || !SIF_API_KEY) {
    console.warn(JSON.stringify({ msg: 'semanticFirewall.disabled', reason: 'SIF_URL/SIF_API_KEY unset' }));
    return null;
  }
  const res = await fetch(`${SIF_URL}/api/v1/guard`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-API-Key': SIF_API_KEY },
    body: JSON.stringify({
      messages: [{ role: 'user', content }],
      policy_id: opts.policyId ?? SIF_POLICY,
      config: { return_detections: opts.returnDetections ?? true },
    }),
    signal: AbortSignal.timeout(3000), // hard cap; don't let a firewall hang a chat turn
  });
  if (!res.ok) {
    console.warn(JSON.stringify({ msg: 'semanticFirewall.http_error', status: res.status }));
    return null; // fail-open at the call site, matching sif's own fail_mode:open default
  }
  const body = await res.json();
  return {
    action: body.action,
    riskScore: body.risk_score,
    modifiedContent: body.modified_content,
    degraded: body.degraded ?? false,
    detections: (body.detections ?? []).map((d: any) => ({
      category: d.category, confidence: d.confidence, description: d.description, ruleId: d.rule_id,
    })),
  };
}
```
Call sites: (1) the A2A family-groups inbound handler, gating any message from another agent's Nostr identity before it enters the LLM context — same shape as the bash hook above; (2) optionally on outbound replies before they're sent to another agent, since sif explicitly does not do this for you; (3) `config.threshold`/`categories` narrowing is available if Concierge only wants `prompt_injection`+`data_exfiltration` checked on agent-to-agent traffic vs. full `pii`+`secrets` scanning on anything touching a human.

Batch variant (`/api/v1/guard/batch`, cap 10) is worth using if Concierge ever needs to pre-screen a batch of queued task follow-ups in one round trip instead of N.

### Operational notes for both integrations
- Always send a request timeout (sif's own p99 target is 25ms, but network+queueing can exceed that under load — 2–3s client timeout with fail-open-on-timeout is a safe default, matching sif's own `fail_mode: open`).
- Log `request_id` and `versions` from every response — sif's own docs call this out as the correlation key for server-side tracing/audit.
- Treat `degraded: true` as "this message was NOT actually inspected" — don't silently trust an `allow` action when `degraded` is set; that's the fail-open path firing, not a clean verdict.
- Pick policy per call-site risk: `low-latency-cascade` for interactive gating, `mission-critical` (fail-closed, 200ms budget) for anything that will be auto-executed without a human in the loop.