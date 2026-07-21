// semantic-firewall.mjs — semanticd (SIF) guard for inbound + outbound (design §4).
//
// node:* only — `fetch` is native, no npm dep. semanticd is a commodity-attack
// speed bump + DLP layer, NEVER the trust boundary (the boundary is the envelope
// quarantine + tool filter). This module:
//   - calls POST {url}/api/v1/guard  (contract = research 03),
//   - FAILS CLOSED on error/timeout/degraded:true (never silent-allow),
//   - F13: LOCAL SIDECAR is the primary hot path; the remote sif.* is failover,
//     and "unreachable" (hold+notify) is distinguished from "block",
//   - outbound DLP with a HARD, non-ML refusal if the body leaks the agent's own
//     nsec / mnemonic (classifiers can miss; this is a grep, not a model),
//   - F20: pending/unknown content is scanned with the sidecar ONLY, never the
//     metered remote key.
//
// All network is injectable (`fetchImpl`) so fail-closed behavior is unit-testable
// headless without a live SIF.

import { createHash } from 'node:crypto';

export const POLICY = {
  inbound: 'low-latency-cascade',
  responder: 'mission-critical',
  outbound: 'low-latency-cascade',
};

/**
 * Resolve SIF config from a daemon.json `semantic_firewall` block + env.
 * F13: `url` is the LOCAL sidecar (primary); `failover_url` is the remote sif.*.
 */
export function resolveConfig(block = {}, env = process.env) {
  return {
    sidecarUrl: block.url || env.SIF_SIDECAR_URL || '',
    failoverUrl: block.failover_url || env.SIF_URL || '',
    apiKey: env[block.api_key_env || 'SIF_API_KEY'] || env.SIF_API_KEY || '',
    timeoutMs: block.timeout_ms || 3000,
    policyInbound: block.policy_inbound || POLICY.inbound,
    policyResponder: block.policy_responder || POLICY.responder,
    policyOutbound: block.policy_outbound || POLICY.outbound,
    failMode: block.fail_mode || 'closed',
  };
}

async function callGuard(url, apiKey, body, timeoutMs, fetchImpl) {
  const res = await fetchImpl(`${url.replace(/\/$/, '')}/api/v1/guard`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(apiKey ? { 'X-API-Key': apiKey } : {}),
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!res.ok) {
    const e = new Error(`sif_http_${res.status}`);
    e.status = res.status;
    throw e;
  }
  return res.json();
}

/**
 * Raw SIF call with F13 sidecar-primary / remote-failover. Returns the parsed
 * GuardResponse, or throws (caller treats a throw as "unreachable").
 * @param {object} cfg  resolveConfig() output
 * @param {object} opts { policyId, allowRemote }  allowRemote=false ⇒ sidecar only (F20)
 */
async function guardRaw(text, cfg, opts, fetchImpl) {
  const reqBody = {
    messages: [{ role: 'user', content: String(text ?? '') }],
    policy_id: opts.policyId,
    config: { return_detections: true },
  };
  const urls = [];
  if (cfg.sidecarUrl) urls.push(cfg.sidecarUrl);
  if (opts.allowRemote !== false && cfg.failoverUrl) urls.push(cfg.failoverUrl);
  if (urls.length === 0) {
    const e = new Error('sif_unconfigured');
    e.unconfigured = true;
    throw e;
  }
  let lastErr;
  for (const url of urls) {
    try {
      return await callGuard(url, cfg.apiKey, reqBody, cfg.timeoutMs, fetchImpl);
    } catch (err) {
      lastErr = err;
      // try next url (failover)
    }
  }
  throw lastErr || new Error('sif_unreachable');
}

function sifLabel(resp) {
  if (!resp) return 'unreachable';
  if (resp.degraded) return 'degraded';
  const cats = (resp.detections || []).map((d) => d.category).filter(Boolean);
  if (resp.action === 'flag') return cats.length ? `flagged:${cats.join(',')}` : 'flagged';
  if (resp.action === 'modify') return 'modified';
  return resp.action || 'unknown';
}

/**
 * Map a SIF response (or unreachable/degraded) to a FAIL-CLOSED effective action
 * for a given trust tier and path (design §4.2 enforcement table).
 *
 * `hold` = quarantine + notify owner; NEVER a silent allow. Owner tier also holds
 * when not inspected (a phone can be compromised) but the notification says so.
 */
function enforceInbound(resp, { tier, unreachable }) {
  const notInspected = unreachable || !resp || resp.degraded === true;
  if (notInspected) {
    return {
      effective: 'hold',
      reason: unreachable ? 'semanticd_unreachable' : 'semanticd_degraded',
    };
  }
  switch (resp.action) {
    case 'allow': return { effective: 'allow' };
    case 'flag': return { effective: 'flag' };
    case 'modify': return { effective: 'modify' };
    case 'block': return { effective: 'block' };
    default: return { effective: 'hold', reason: 'unknown_action' };
  }
}

/**
 * Guard an inbound message body.
 * @param {string} text
 * @param {object} cfg   resolveConfig()
 * @param {object} opts  { tier, responderPath?:bool, allowRemote?:bool }
 * @returns {Promise<object>} verdict
 */
export async function guardInbound(text, cfg, opts = {}, fetchImpl = fetch) {
  const policyId = opts.responderPath ? cfg.policyResponder : cfg.policyInbound;
  // F20: pending/unknown senders are scanned with the sidecar only.
  const allowRemote = opts.tier === 'pending' ? false : opts.allowRemote !== false;
  let resp = null;
  let unreachable = false;
  try {
    resp = await guardRaw(text, cfg, { policyId, allowRemote }, fetchImpl);
  } catch (err) {
    unreachable = true;
    resp = null;
  }
  const enforced = enforceInbound(resp, { tier: opts.tier, unreachable });
  return {
    action: resp?.action ?? null,
    effective: enforced.effective,
    reason: enforced.reason ?? null,
    unreachable,
    degraded: resp?.degraded ?? false,
    riskScore: resp?.risk_score ?? null,
    modifiedContent: resp?.modified_content ?? null,
    detections: resp?.detections ?? [],
    requestId: resp?.request_id ?? null,
    versions: resp?.versions ?? null,
    label: sifLabel(resp),
    policyId,
  };
}

// ---------------------------------------------------------------------------
// Outbound DLP — semanticd's strongest role + a HARD non-ML self-secret guard.
// ---------------------------------------------------------------------------

const NSEC_RE = /nsec1[02-9ac-hj-np-z]{20,}/i;

/** Does `body` contain a run of >= `min` consecutive words of `mnemonic`? */
function containsMnemonicRun(body, mnemonic, min = 8) {
  if (!mnemonic) return false;
  const mWords = String(mnemonic).toLowerCase().split(/\s+/).filter(Boolean);
  if (mWords.length < min) return false;
  const bWords = String(body).toLowerCase().split(/\s+/).filter(Boolean);
  const bSet = bWords.join(' ');
  for (let i = 0; i + min <= mWords.length; i++) {
    const run = mWords.slice(i, i + min).join(' ');
    if (bSet.includes(run)) return true;
  }
  return false;
}

/**
 * Hard, non-ML refusal check: refuse to send ANY nsec, and specifically the
 * agent's own nsec/mnemonic (design §4.3). Runs BEFORE any SIF call so we never
 * ship the secret to SIF either.
 * @returns {string|null} reason if it must be refused, else null
 */
export function selfSecretLeak(body, { selfNsec, selfMnemonic } = {}) {
  const s = String(body ?? '');
  if (NSEC_RE.test(s)) return 'nsec_in_body';
  if (selfNsec && s.includes(selfNsec)) return 'self_nsec_in_body';
  if (containsMnemonicRun(s, selfMnemonic)) return 'self_mnemonic_in_body';
  return null;
}

/**
 * Guard an outbound message before send. Fail-closed: unreachable ⇒ refuse.
 * @param {object} opts { selfNsec, selfMnemonic, retried?:bool }
 * @returns {Promise<object>} verdict { effective:'send'|'refuse'|'modify', outboundBody, ... }
 */
export async function guardOutbound(text, cfg, opts = {}, fetchImpl = fetch) {
  const leak = selfSecretLeak(text, opts);
  if (leak) {
    return { effective: 'refuse', reason: leak, hardGuard: true, outboundBody: null };
  }
  let resp = null;
  let unreachable = false;
  try {
    resp = await guardRaw(text, cfg, { policyId: cfg.policyOutbound, allowRemote: true }, fetchImpl);
  } catch {
    unreachable = true;
  }
  if (unreachable || !resp || resp.degraded === true) {
    // Fail-closed on outbound: one retry, then refuse.
    if (!opts.retried) {
      return guardOutbound(text, cfg, { ...opts, retried: true }, fetchImpl);
    }
    return {
      effective: 'refuse',
      reason: unreachable ? 'semanticd_unreachable' : 'semanticd_degraded',
      outboundBody: null,
    };
  }
  switch (resp.action) {
    case 'allow':
    case 'flag':
      return { effective: 'send', reason: null, outboundBody: String(text), label: sifLabel(resp), requestId: resp.request_id };
    case 'modify':
      return { effective: 'modify', reason: 'dlp_redacted', outboundBody: resp.modified_content ?? '', label: 'modified', requestId: resp.request_id };
    case 'block':
    default:
      return { effective: 'refuse', reason: 'sif_block', detections: resp.detections ?? [], outboundBody: null, requestId: resp.request_id };
  }
}

/** Stable hash of a normalized body — used for near-dup suppression + audit. */
export function bodyHash(text) {
  const norm = String(text ?? '').toLowerCase().replace(/\s+/g, ' ').trim();
  return createHash('sha256').update(norm).digest('hex');
}
