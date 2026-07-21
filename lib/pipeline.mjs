// pipeline.mjs — In-process inbound message pipeline (design §2 "strict order").
//
//   envelope parse/dedup → authorization firewall → semantic firewall → decision
//
// This is the single chokepoint both the helper (poll/backfill) and the daemon
// (real-time push) run every inbound event through BEFORE it can surface. It owns
// the F14 durable state (dedup + per-relay last_seen + processed-msg-with-outcome)
// and persists it BEFORE returning a surfaced record, so processing is idempotent
// across daemon restarts.
//
// node:* only. All SDK/network is injected (npubForHex, fetchImpl) so the whole
// pipeline is unit-testable headless.

import { readFileSync, writeFileSync, existsSync, mkdirSync, renameSync, chmodSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import * as authz from './authz-firewall.mjs';
import * as sif from './semantic-firewall.mjs';
import { wrapPeerMessage } from './envelope.mjs';

const SEEN_CAP = 5000;
const PROCESSED_CAP = 5000;
const EXCERPT_MAX = 200;

// ---------------------------------------------------------------------------
// Durable bus state (F14)
// ---------------------------------------------------------------------------

export function emptyBusState() {
  return {
    seen: [],                 // recent eventIds (bounded FIFO)
    last_seen: {},            // per-relay high-water unix seconds
    processed: {},            // eventId -> { outcome, at }
    rate: authz.emptyRateState(),
    out_seq: {},              // per-recipient outbound seq
  };
}

export function loadBusState(path) {
  if (!existsSync(path)) return emptyBusState();
  try {
    const s = JSON.parse(readFileSync(path, 'utf-8'));
    return {
      seen: Array.isArray(s.seen) ? s.seen : [],
      last_seen: s.last_seen || {},
      processed: s.processed || {},
      rate: s.rate || authz.emptyRateState(),
      out_seq: s.out_seq || {},
    };
  } catch {
    return emptyBusState();
  }
}

function atomicWrite(path, obj, mode) {
  const dir = dirname(path);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(obj, null, 2));
  if (mode) { try { chmodSync(tmp, mode); } catch { /* best effort */ } }
  renameSync(tmp, path);
  if (mode) { try { chmodSync(path, mode); } catch { /* best effort */ } }
}

export function saveBusState(path, state) {
  // Bound the growth of the idempotency structures.
  if (state.seen.length > SEEN_CAP) state.seen = state.seen.slice(-SEEN_CAP);
  const keys = Object.keys(state.processed);
  if (keys.length > PROCESSED_CAP) {
    for (const k of keys.slice(0, keys.length - PROCESSED_CAP)) delete state.processed[k];
  }
  atomicWrite(path, state, 0o600);
}

function record(state, eventId, outcome) {
  if (eventId) {
    if (!state.seen.includes(eventId)) state.seen.push(eventId);
    state.processed[eventId] = { outcome, at: Date.now() };
  }
}

function quarantinePath(agentDir, sub, eventId) {
  return resolve(agentDir, 'quarantine', sub, `${eventId || 'unknown'}.json`);
}

function writeQuarantine(agentDir, sub, eventId, payload) {
  const p = quarantinePath(agentDir, sub, eventId);
  atomicWrite(p, payload, 0o600);
  return p;
}

// ---------------------------------------------------------------------------
// The pipeline
// ---------------------------------------------------------------------------

/**
 * Process one raw inbound message.
 *
 * @param {object} raw   { type:'dm'|'group', fromHex, body, eventId, timestampSec, kind, group? }
 * @param {object} ctx   {
 *    store, storePath,          // contacts.json (authz)
 *    state, statePath,          // bus-state.json (F14)
 *    agentDir,                  // for quarantine files
 *    ownerNpub,
 *    npubForHex(hex)->npub,     // SDK-backed, injected (BUG-1: convert ONCE here)
 *    sifCfg,                    // resolveConfig() from semantic-firewall
 *    fetchImpl,                 // injectable for tests
 *    now,                       // ms, injectable
 * }
 * @returns {Promise<object>} decision:
 *    { outcome, surface?:record, pending?:{...}, held?:{...}, blocked?:{...}, reason? }
 *
 * SECURITY NOTE: durable state is saved BEFORE this returns a surfaced record
 * (F14) so a crash-then-restart backfill cannot re-surface / re-act on it.
 */
export async function processInbound(raw, ctx) {
  const now = ctx.now ?? Date.now();
  const eventId = raw.eventId || '';
  const state = ctx.state;
  const store = ctx.store;

  // 1. Transport dedup + idempotency (F14, BUG-3).
  if (eventId && (state.seen.includes(eventId) || state.processed[eventId])) {
    return { outcome: 'duplicate' };
  }

  // Advance per-relay last_seen high-water for cold-start backfill.
  if (Number.isFinite(raw.timestampSec)) {
    const relay = raw.relay || 'default';
    state.last_seen[relay] = Math.max(state.last_seen[relay] || 0, raw.timestampSec);
  }

  // 2. Authorization firewall — classify by npub (converted ONCE; BUG-1).
  //    F5: DM and group senders classified identically by contacts.json.
  const senderNpub = ctx.npubForHex(raw.fromHex);
  const { tier, contact } = authz.classify(store, senderNpub, ctx.ownerNpub);

  if (tier === 'blocked') {
    record(state, eventId, 'blocked_sender');
    saveBusState(ctx.statePath, state);
    return { outcome: 'blocked_sender' };
  }

  // 3. Rate / DoS limits (§3.4) — before any expensive work.
  const rate = state.rate;
  const rl = authz.checkRate(rate, senderNpub, now, store.rate_limits);
  if (!rl.allowed) {
    record(state, eventId, `rate:${rl.reason}`);
    saveBusState(ctx.statePath, state);
    return { outcome: 'rate_limited', reason: rl.reason };
  }
  const hash = sif.bodyHash(raw.body);
  if (authz.isNearDuplicate(rate, hash, now, store.rate_limits)) {
    record(state, eventId, 'near_duplicate');
    saveBusState(ctx.statePath, state);
    return { outcome: 'near_duplicate' };
  }

  // 4. PENDING (unknown npub) — never surfaces; held in quarantine (§3.3, F5).
  if (tier === 'pending') {
    if (authz.pendingHoldExceeded(store, senderNpub)) {
      record(state, eventId, 'pending_hold_exceeded');
      saveBusState(ctx.statePath, state);
      return { outcome: 'pending_dropped' };
    }
    // Scan with the SIDECAR ONLY (F20) to produce a redacted excerpt for the
    // owner notification — never the metered remote key.
    let excerpt = '';
    try {
      const v = await sif.guardInbound(raw.body, ctx.sifCfg, { tier: 'pending' }, ctx.fetchImpl);
      const base = v.effective === 'modify' && v.modifiedContent ? v.modifiedContent : raw.body;
      // F6: excerpt is inert structural context only — hard-truncated, control
      // chars stripped. The notification line itself carries NO peer text.
      excerpt = String(base).replace(/\s+/g, ' ').slice(0, EXCERPT_MAX);
    } catch { excerpt = ''; }

    authz.addPending(store, senderNpub, { increment: 1 });
    const held = store.pending[senderNpub];
    writeQuarantine(ctx.agentDir, `pending/${senderNpub}`, eventId, {
      from_npub: senderNpub, from_hex: raw.fromHex, type: raw.type,
      body: raw.body, received_at: new Date(now).toISOString(),
    });
    record(state, eventId, 'quarantined_pending');
    authz.saveStore(ctx.storePath, store);
    saveBusState(ctx.statePath, state);
    return {
      outcome: 'quarantined_pending',
      pending: {
        npub: senderNpub,
        count_held: held.count_held,
        excerpt_redacted: excerpt, // structural/inert; UI renders below-the-fold, fenced (F6)
      },
    };
  }

  // 5. OWNER / TEAM — full semantic firewall, fail-closed (§4.2).
  const verdict = await sif.guardInbound(raw.body, ctx.sifCfg, { tier }, ctx.fetchImpl);

  if (verdict.effective === 'block') {
    writeQuarantine(ctx.agentDir, 'blocked', eventId, {
      from_npub: senderNpub, tier, body: raw.body, sif: verdict.label,
      request_id: verdict.requestId, received_at: new Date(now).toISOString(),
    });
    record(state, eventId, 'blocked_content');
    saveBusState(ctx.statePath, state);
    return { outcome: 'blocked_content', blocked: { npub: senderNpub, tier, sif: verdict.label } };
  }

  if (verdict.effective === 'hold') {
    // semanticd unreachable/degraded — NEVER silent-allow (F13). Owner degrades to
    // hold-and-notify; team holds. Quarantined for release once SIF is reachable.
    writeQuarantine(ctx.agentDir, 'held', eventId, {
      from_npub: senderNpub, tier, body: raw.body, reason: verdict.reason,
      received_at: new Date(now).toISOString(),
    });
    record(state, eventId, `held:${verdict.reason}`);
    saveBusState(ctx.statePath, state);
    return { outcome: 'held', held: { npub: senderNpub, tier, reason: verdict.reason } };
  }

  // effective ∈ { allow, flag, modify } → SURFACE (wrapped + quarantined-as-data).
  const effectiveBody =
    verdict.effective === 'modify' && verdict.modifiedContent != null
      ? verdict.modifiedContent
      : raw.body;

  const msgId = raw.msgId || (eventId ? `evt:${eventId.slice(0, 24)}` : `evt:${now}`);
  const nametag = contact?.nametag && authz.isValidNametag(contact.nametag) ? contact.nametag : '';
  const wrapped = wrapPeerMessage({
    fromNpub: senderNpub,
    nametag,
    tier,
    sif: verdict.label,
    msgId,
    seq: raw.seq ?? '',
    body: effectiveBody,
  }).frame;

  const surface = {
    type: raw.type,
    from_npub: senderNpub,
    from_hex: raw.fromHex,
    nametag,
    tier,
    sif: verdict.label,
    msg_id: msgId,
    seq: raw.seq ?? null,
    priority: tier === 'owner',
    timestamp: Number.isFinite(raw.timestampSec)
      ? new Date(raw.timestampSec * 1000).toISOString()
      : new Date(now).toISOString(),
    wrapped,
    read: false,
    ...(raw.group ? { group: raw.group } : {}),
  };

  // F14: persist the outcome BEFORE returning the surfaced record.
  record(state, eventId, `surface:${verdict.effective}`);
  saveBusState(ctx.statePath, state);
  return { outcome: 'surface', surface };
}
