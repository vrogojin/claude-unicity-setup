# provision-ingress — capability-gated public-ingress provider (A2A verb)

The reference implementation of a **pluggable DNS/ingress provider** for Mission Control /
AMC. An authorized peer asks THIS Concierge instance for a public hostname for a service it
spawned; Concierge does the Cloudflare provisioning **under its own credential and its
owner's consent**. The credential never leaves this side and is never transmitted — the
response carries only the **0600 path** to the connector token, never the token value.

- Backend script: [`provision-ingress.sh`](provision-ingress.sh) (zero-dep: `bash` + `jq` +
  `cloudflared`; `curl` for the DNS API path).
- Capability wiring: `provision-ingress` in `agent-registry.sh` `AGENT_CAPABILITIES` +
  `AGENT_CAPS_DESTRUCTIVE`.
- Dispatch: handled as a work-item in the `/process-agent-requests` capability-scoped
  processor — **propose → owner disposes** (same class as `rebuild-reload-service`).
- Test: [`../../test/provision-ingress.test.sh`](../../test/provision-ingress.test.sh).

## Authorization model (why exposing this over A2A is safe)

`provision-ingress` is a **destructive/outward** capability: owner-**granted** in the
registry AND owner-**confirmed per provision**. The processor is capability-scoped and may
NOT execute it — it runs the script's read-only `--plan` mode, returns the plan, and
**STOPS**. Only the owner runs `--apply`. The verb MUST NOT auto-execute an unconfirmed
provision.

Two hard input controls, enforced by the script before any mutation:

- **Zone pin** — `hostname` must be a subdomain of the allowed zone (`INGRESS_ZONE`,
  default `concierge-dev.app`). A peer can never provision a name in another zone.
- **Loopback pin** — `target` must be `127.0.0.1:<port>` (or `localhost:<port>`). A peer can
  never point a public hostname at an arbitrary host (no open proxy).

## Request / response contract

**Request** (JSON on stdin / `--in FILE` / `--json '<obj>'`):

```json
{ "hostname": "track-42.concierge-dev.app", "target": "127.0.0.1:8931",
  "purpose": "spawned track UI", "ttl_hint": "6h" }
```

**Response** (one JSON object on stdout). The **canonical keys are always present** —
`hostname`, `connector_token_path`, `tunnel_name`, `status` — plus additive, **non-secret**
diagnostics `op`, `mode`, `reason`, `remediation[]`. The connector **token value is never a
field** (only its 0600 path):

```json
{ "hostname": "track-42.concierge-dev.app",
  "connector_token_path": "/home/vrogojin/concierge/.secrets/ingress/ingress-track-42.env",
  "tunnel_name": "ingress-track-42", "status": "ok", "op": "provision", "mode": "apply",
  "reason": "...", "remediation": [] }
```

`status` vocabulary:

| status | meaning |
|---|---|
| `planned` | `--plan` only: this is what would happen; nothing changed. |
| `ok` | `--apply`: provisioned (or deprovisioned) successfully. |
| `exists` | idempotent hit — the tunnel + token already exist; no change. |
| `not_found` | deprovision target does not exist; nothing to do (idempotent). |
| `blocked_scope` | the credential can't create/delete tunnels — see the one-time fix. **Never faked.** |
| `partial` | deprovision removed some resources with a non-fatal warning. |
| `invalid` | request failed validation (bad zone, non-loopback target, bad port, non-JSON). |
| `error` | an unexpected operational failure (details in `reason`, secrets redacted). |

**Idempotency** — the `tunnel_name` is derived deterministically from the hostname's leading
label (`track-42.…` → `ingress-track-42`), so re-requesting the same hostname returns the
existing tunnel (`status:"exists"`) and never creates a duplicate.

## What `--apply` does under the hood (mirrors the gptbridge convention)

1. `cloudflared tunnel create <tunnel_name>` — **the scope gap lives here** (see below).
2. Persist the connector token to `.secrets/ingress/<tunnel_name>.env`, mode `0600` (value
   never printed).
3. Create the DNS CNAME `<hostname> → <tunnel-uuid>.cfargotunnel.com` via the Cloudflare API
   using the **DNS-only** token at `.secrets/staging-tls/cloudflare.ini`
   (`dns_cloudflare_api_token`). This path works with the current token.
4. Start a `systemd --user` connector unit `ingress-<name>.service`
   (`ExecStart=cloudflared tunnel --no-autoupdate run`, `EnvironmentFile=<token file>`,
   `Restart=always`) — identical shape to `gptbridge-tunnel.service`.

`deprovision --apply` reverses it: delete the CNAME, stop + delete the tunnel, remove the
token file and the unit.

## KNOWN SCOPE GAP — tunnel-create needs a one-time owner fix

The persisted token (`dns_cloudflare_api_token`) is **DNS-only** (Zone›DNS:Edit + Zone:Read
on `concierge-dev.app`), and there is no `~/.cloudflared/cert.pem`. So **step 1
(`cloudflared tunnel create`) fails** until the owner does ONE of the following **once**.
Until then the verb returns `status:"blocked_scope"` with these exact remediations — it
never pretends to have succeeded, and the DNS-record path (step 3) is fully functional.

**Option A — extend the API token (no interactive login):**
In the Cloudflare dashboard, add the permission **`Account › Cloudflare Tunnel › Edit`** to
the token stored at `.secrets/staging-tls/cloudflare.ini` (`dns_cloudflare_api_token`).
Then export it for cloudflared and re-run apply:

```bash
export CLOUDFLARED_API_TOKEN="$(sed -n 's/^[[:space:]]*dns_cloudflare_api_token[[:space:]]*[:=][[:space:]]*//p' \
  /home/vrogojin/concierge/.secrets/staging-tls/cloudflare.ini)"
# then the owner-confirmed apply:
printf '%s' '<request-json>' | .claude/hooks/provision-ingress.sh provision --apply
```

**Option B — interactive login (persists a cert):**
Run once, as the service user, to write `~/.cloudflared/cert.pem`:

```bash
cloudflared tunnel login          # opens a browser; authorizes the concierge-dev.app zone
printf '%s' '<request-json>' | .claude/hooks/provision-ingress.sh provision --apply
```

Either fix is one-time and persistent. After it, `--apply` provisions end-to-end.

## Configuration knobs (env; all defaulted for the concierge dev runtime)

| var | default | purpose |
|---|---|---|
| `INGRESS_PROJECT_DIR` | `$CLAUDE_PROJECT_DIR` or `/home/vrogojin/concierge` | project root (secrets live here) |
| `INGRESS_ZONE` | `concierge-dev.app` | the only zone a peer may provision within |
| `INGRESS_CF_INI` | `<project>/.secrets/staging-tls/cloudflare.ini` | DNS-only API token file |
| `INGRESS_TOKEN_DIR` | `<project>/.secrets/ingress` | 0600 connector-token store |
| `CLOUDFLARED_BIN` | `cloudflared` | binary (override for a pinned path) |
| `CLOUDFLARED_API_TOKEN` | — | set to the extended token for Option A |
| `INGRESS_DNS_MODE` | `api` | `api` (Cloudflare API) · `cli` (`cloudflared route dns`) · `skip` |
| `INGRESS_SUPERVISOR` | `systemd` | `systemd --user` unit · `none` (skip start) |

## Security invariants

- The connector **token value is never emitted** and never logged — only its 0600 path.
- Tokens live only under gitignored `.secrets/`; nothing here is committed.
- The processor may only **plan**; the owner **applies**. No unconfirmed provision runs.
- Zone + loopback pins block zone-escape and open-proxy abuse before any mutation.
- `blocked_scope` is returned honestly — success is never faked when the credential is short.
