# provision-ingress — capability-gated public-ingress provider (A2A verb)

The reference implementation of a **pluggable ingress provider** for Mission Control / AMC.
An authorized peer asks THIS instance for a public hostname for a service it spawned; THIS
side does the provisioning **under its own infra + its owner's consent**. No secret is ever
transmitted.

Two pluggable modes, selected by `INGRESS_MODE` (or the project's `.ingress.mode`):

| mode | how it exposes the service | credential |
|---|---|---|
| **`haproxy`** (default, primary) | registers the hostname with a **shared haproxy** domain-multiplexer's Registration API; public reach comes from a **wildcard DNS** record (`*.staging.<zone>` → the host IP) → haproxy → the target **container** on `haproxy-net` | **none** — no Cloudflare, no tunnel, no secret |
| **`tunnel`** (fallback) | for projects with **no shared haproxy**: a Cloudflare **named tunnel** + DNS CNAME + `0600` connector token | this side's own Cloudflare token (never emitted; only its 0600 path) |

Most projects with a shared reverse proxy never need the tunnel path. The Cloudflare scope
gap (below) applies **only** to the fallback mode.

- Backend script: [`provision-ingress.sh`](provision-ingress.sh) (zero-dep: `bash` + `jq`;
  `curl` for both APIs; `cloudflared` only for the tunnel fallback).
- Capability wiring: `provision-ingress` in `agent-registry.sh` `AGENT_CAPABILITIES` +
  `AGENT_CAPS_DESTRUCTIVE`.
- Dispatch: a work-item in `/process-agent-requests` — **propose → owner disposes** (same
  class as `rebuild-reload-service`).
- Test: [`../../test/provision-ingress.test.sh`](../../test/provision-ingress.test.sh) (50 checks).

## Authorization model — INERT until BOTH gates pass

`provision-ingress` is **destructive/outward**: owner-**granted** in the registry AND
owner-**confirmed per op**. It provisions nothing unless BOTH hold:

1. **Capability grant** — the peer must hold `provision-ingress` in this instance's registry
   (default-deny; the processor re-checks at dispatch). Without it the request never reaches
   the verb.
2. **Owner per-op confirm** — the capability-scoped processor runs only the read-only
   `--plan` and STOPS. `--apply` is **technically gated**: it refuses with
   `status:"blocked_confirm"` unless the owner sets **`INGRESS_APPLY_CONFIRM=1`**. Copying the
   plan command verbatim therefore never mutates. The processor is told never to set it.

Two hard input controls, enforced before any mutation:

- **Zone pin** — `hostname` must be a subdomain of `INGRESS_ZONE` (haproxy default
  `staging.concierge-dev.app`; tunnel default `concierge-dev.app`). No zone-escape.
- **Target pin** (mode-specific):
  - haproxy → the target must be a **real container that is actually attached to
    `haproxy-net`**. This is an **existence-based allowlist** (verified via `docker` before
    accepting), which is the PRIMARY control — it rejects every off-network target *by
    construction*, so no IP-literal spelling (dotted-quad, decimal, octal, hex, v4-in-v6,
    trailing-dot, the docker gateway, or a cloud metadata endpoint) can be reached. An
    IP-literal reject runs as belt-and-suspenders. `INGRESS_VERIFY_CONTAINER` is
    **fail-closed by default**: `require` (default — enforce; if docker is unavailable →
    `blocked_config`, never a silent downgrade); `auto` (explicit opt-in — enforce when
    docker is present, else fall back to the IP reject **and mark the result reason
    `UNVERIFIED (…)`** so the downgrade is visible in the plan); `off`. Loopback is rejected.
  - tunnel → `target` must be `127.0.0.1:<port>` (or `localhost`). No open proxy.

## Request / response contract

**Request** (JSON on stdin / `--in FILE` / `--json '<obj>'`):

```jsonc
// haproxy mode
{ "hostname": "track-42.staging.concierge-dev.app", "target": "track42-web:8080",
  "https_port": 443, "purpose": "spawned track UI", "ttl_hint": "6h" }
// tunnel mode
{ "hostname": "track-42.concierge-dev.app", "target": "127.0.0.1:8931", "purpose": "…" }
```

`https_port` (haproxy) is optional — request > `.ingress.haproxy_https_port` > `443`; `null`/`0`
means HTTP-only (haproxy serves the domain on :80). In staging the shared haproxy is
SNI/TCP-passthrough on :443, so the container serves its **own** TLS with the
`*.staging.concierge-dev.app` wildcard cert (`.secrets/staging-certs`).

**Response** (one JSON object). Always present: `hostname`, `status`, `mode`, `op`, `phase`.
Mode-specific: haproxy → `backend`; tunnel → `connector_token_path`, `tunnel_name`. Plus
non-secret `reason`, `remediation[]`. **No token/secret value is ever a field.**

```jsonc
// haproxy
{ "hostname": "track-42.staging.concierge-dev.app", "status": "ok", "mode": "haproxy",
  "op": "provision", "phase": "apply", "backend": "track42-web:8080", "reason": "…" }
// tunnel
{ "hostname": "track-42.concierge-dev.app", "status": "ok", "mode": "tunnel",
  "connector_token_path": "…/.secrets/ingress/ingress-track-42.env",
  "tunnel_name": "ingress-track-42", "reason": "…" }
```

`status`: `planned` (plan preview) · `ok` · `exists` (idempotent no-op) · `conflict`
(haproxy: the hostname is already registered to a DIFFERENT target — **refused, not
repointed**) · `not_found` · `blocked_config` (haproxy: `HAPROXY_HOST` unresolved, or
`verify_container=require` with no docker) · `blocked_scope` (tunnel: no usable Cloudflare
credential — never faked) · `blocked_confirm` (`--apply` without `INGRESS_APPLY_CONFIRM=1`) ·
`partial` · `invalid` · `error` (rolled back).

**Idempotent** — re-provisioning an existing hostname to the SAME target returns `exists`,
never a duplicate. To a DIFFERENT target it returns `conflict` and **refuses** (no POST) —
a live public route is never silently retargeted; deprovision it first. `deprovision` is
idempotent too (`not_found` when already gone). All API calls are timeout-bounded so a down
dependency can never hang the unattended `--plan`.

## haproxy mode — what `--apply` does (no secret)

`POST http://<HAPROXY_HOST>:8404/v1/backends` with
`{ domain:<hostname>, container:<name>, http_port:<port>, https_port:<443|null> }` — exactly
the shape the backend's own `haproxy.ts` self-registration uses. `deprovision` →
`DELETE .../v1/backends/<hostname>`. `HAPROXY_HOST` resolves ENV `INGRESS_HAPROXY_HOST` >
`HAPROXY_HOST` > `.ingress.haproxy_host` > the project's `.env`; unresolved →
`blocked_config` naming it. **No Cloudflare credential is read or needed in this mode.**

## tunnel mode (fallback) — what `--apply` does

Create tunnel → persist `0600` token (write checked) → **configure the ingress rule** (API
`PUT …/configurations`, or a CLI `config.yml`) so the edge routes `<host> → http://<target>`
→ DNS CNAME (`<uuid>.cfargotunnel.com`) → `systemd --user` unit. Two lifecycle backends,
auto-selected: cloudflared/`cert.pem`, or the Cloudflare API with an account-scoped token.
Any failure after create **rolls back** (no orphans) and returns `error`.

### KNOWN SCOPE GAP — one-time owner fix (tunnel mode only)

The persisted token (`.secrets/staging-tls/cloudflare.ini` `dns_cloudflare_api_token`) is
DNS-only and there's no `~/.cloudflared/cert.pem`, so tunnel-create fails →
`status:"blocked_scope"` with both fixes:

- **Option A (zero-touch after the dashboard edit)** — add `Account › Cloudflare Tunnel ›
  Edit` to that same token in the Cloudflare dashboard. **The script auto-reads the token
  from `cloudflare.ini`** (no `export` needed), so provisioning just works afterward. An
  explicit `CLOUDFLARED_API_TOKEN` env overrides it if set.
- **Option B** — `cloudflared tunnel login` once → `~/.cloudflared/cert.pem`.

Then `INGRESS_APPLY_CONFIRM=1 provision-ingress.sh provision --apply`.

## Generic by design: per-project config

Every project-specific bit resolves **ENV › the project's `.claude/agent/config.json`
`.ingress` block › default**, so AMC's *other* projects configure their own ingress without
editing the script:

```jsonc
{ "ingress": {
    "mode": "haproxy",                      // or "tunnel"
    "zone": "apps.example.net",             // allowed provisioning zone
    "haproxy_host": "haproxy", "haproxy_api_port": 8404, "haproxy_https_port": 443,
    // tunnel-mode only:
    "cloudflare_ini": "/path/cloudflare.ini", "token_dir": "/path/.secrets/ingress",
    "tunnel_prefix": "ingress-", "cf_api": "https://api.cloudflare.com/client/v4"
} }
```

Only paths/names live in config — secrets stay env/secret-file only.

## Configuration knobs (ENV › project config › default)

| ENV | project config key | default | purpose |
|---|---|---|---|
| `INGRESS_MODE` | `.ingress.mode` | `haproxy` | `haproxy` \| `tunnel` |
| `INGRESS_ZONE` | `.ingress.zone` | mode-dependent | the only zone a peer may provision within |
| `INGRESS_HAPROXY_HOST` (or `HAPROXY_HOST`) | `.ingress.haproxy_host` | (project `.env`) | shared haproxy Registration API host |
| `INGRESS_HAPROXY_API_PORT` | `.ingress.haproxy_api_port` | `8404` | Registration API port |
| `INGRESS_HAPROXY_HTTPS_PORT` | `.ingress.haproxy_https_port` | `443` | https_port advertised (null = HTTP-only) |
| `INGRESS_HAPROXY_NET` | `.ingress.haproxy_net` | `haproxy-net` | the shared proxy network the target container must be on |
| `INGRESS_VERIFY_CONTAINER` | `.ingress.verify_container` | `require` | container allowlist (fail-closed default): `require` \| `auto` (marks UNVERIFIED on fallback) \| `off` |
| `DOCKER_BIN` | — | `docker` | docker CLI used for the container-membership check |
| `INGRESS_APPLY_CONFIRM` | — (env only) | — | must be `1` for `--apply` (owner-confirm gate) |
| `INGRESS_CF_INI` | `.ingress.cloudflare_ini` | `<project>/.secrets/staging-tls/cloudflare.ini` | tunnel: token file (auto-read) |
| `INGRESS_TOKEN_DIR` | `.ingress.token_dir` | `<project>/.secrets/ingress` | tunnel: 0600 token store |
| `INGRESS_TUNNEL_PREFIX` | `.ingress.tunnel_prefix` | `ingress-` | tunnel: name prefix |
| `CLOUDFLARED_API_TOKEN` | — (env only, never config) | — | tunnel: overrides the auto-read ini token |
| `INGRESS_TUNNEL_MODE` / `INGRESS_DNS_MODE` / `INGRESS_SUPERVISOR` | — | `auto`/`api`/`systemd` | tunnel backend selectors |

## Security invariants

- **INERT until both gates**: capability grant AND `INGRESS_APPLY_CONFIRM=1`. Merging this to
  main provisions nothing on its own.
- **No secret is emitted or logged.** haproxy mode uses no secret at all; tunnel mode returns
  only the connector token's `0600` path.
- Zone pin blocks zone-escape. The haproxy **target pin is an existence-based allowlist**
  (container must be on `haproxy-net`) — the primary SSRF/open-proxy control, not an IP
  blacklist; tunnel mode pins to loopback. Enforced before any mutation.
- A failed tunnel `--apply` **rolls back** — no orphaned tunnels, tokens, or config.
- `blocked_scope` / `blocked_config` are returned honestly — success is never faked.
