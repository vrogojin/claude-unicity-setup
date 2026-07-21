// authz-firewall.mjs — Trust-tier authorization firewall (design §3).
//
// Pure node:* (fs for the store only). Default-deny, fail-closed. Sender identity
// is cryptographic (the NIP-17 seal is signed by the sender key), so we classify
// on npub — NEVER on a claimed name and (F5) NEVER on relay group presence.
//
// Store: <agentDir>/contacts.json  (schema = design §3.2), chmod 600, gitignored.

import { readFileSync, writeFileSync, existsSync, mkdirSync, renameSync, chmodSync } from 'node:fs';
import { dirname } from 'node:path';

export const TIERS = new Set(['owner', 'team', 'pending', 'blocked']);

export const DEFAULT_RATE_LIMITS = {
  per_contact_per_min: 10,
  pending_hold_max: 20,
  global_per_min: 60,
  near_dup_window_ms: 10 * 60 * 1000,
};

// ---------------------------------------------------------------------------
// F4 — metadata constrained by charset + length + enum, NEVER by scanning.
// ---------------------------------------------------------------------------

export function isValidNpub(s) {
  return typeof s === 'string' && /^npub1[0-9ac-hj-np-z]{20,90}$/.test(s);
}

/** nametag ∈ [a-z0-9-]{1,32} (F4). Rejects anything else outright. */
export function isValidNametag(s) {
  return typeof s === 'string' && /^[a-z0-9-]{1,32}$/.test(s);
}

export function isValidTier(t) {
  return TIERS.has(t);
}

/**
 * label is OWNER-AUTHORED ONLY (F4) — never taken from a peer's card. This
 * clamps/strips it defensively; callers must only pass owner-supplied text.
 */
export function sanitizeLabel(s) {
  if (s == null) return '';
  return String(s).replace(/[\u0000-\u001F\u007F\u2028\u2029]/g, ' ').slice(0, 120).trim();
}

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

export function emptyStore() {
  return {
    version: 1,
    contacts: {},
    pending: {},
    blocked: [],
    rate_limits: { ...DEFAULT_RATE_LIMITS },
  };
}

export function loadStore(path) {
  if (!existsSync(path)) return emptyStore();
  try {
    const s = JSON.parse(readFileSync(path, 'utf-8'));
    return {
      version: s.version ?? 1,
      contacts: s.contacts ?? {},
      pending: s.pending ?? {},
      blocked: Array.isArray(s.blocked) ? s.blocked : [],
      rate_limits: { ...DEFAULT_RATE_LIMITS, ...(s.rate_limits ?? {}) },
    };
  } catch {
    // A corrupt store must FAIL CLOSED — treat everyone as unknown, not trusted.
    return emptyStore();
  }
}

export function saveStore(path, store) {
  const dir = dirname(path);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(store, null, 2));
  try { chmodSync(tmp, 0o600); } catch { /* best effort */ }
  renameSync(tmp, path);
  try { chmodSync(path, 0o600); } catch { /* best effort */ }
}

// ---------------------------------------------------------------------------
// Classification — the firewall's core decision.
// ---------------------------------------------------------------------------

/**
 * Classify a sender by npub. The caller MUST convert the transport hex pubkey to
 * npub exactly once and pass npub here (fixes BUG-1: never compare hex-vs-bech32).
 *
 * F5: this function does not know or care whether the message arrived via DM or
 * a group — an unknown npub is `pending` regardless of any `#h` group tag.
 *
 * @returns {{ tier:'owner'|'team'|'pending'|'blocked', contact:object|null }}
 */
export function classify(store, senderNpub, ownerNpub) {
  if (!senderNpub) return { tier: 'blocked', contact: null };
  if (Array.isArray(store.blocked) && store.blocked.includes(senderNpub)) {
    return { tier: 'blocked', contact: null };
  }
  const contact = store.contacts?.[senderNpub] || null;
  if (contact && contact.tier === 'owner') return { tier: 'owner', contact };
  if (ownerNpub && senderNpub === ownerNpub) {
    return { tier: 'owner', contact: contact || { tier: 'owner' } };
  }
  if (contact && contact.tier === 'team') return { tier: 'team', contact };
  if (contact && isValidTier(contact.tier)) return { tier: contact.tier, contact };
  return { tier: 'pending', contact: null };
}

// ---------------------------------------------------------------------------
// Store mutations (used by /approve-contact, /deny-contact, quarantine).
// ---------------------------------------------------------------------------

/** Record an unknown-npub first contact in quarantine bookkeeping (§3.3). */
export function addPending(store, npub, meta = {}) {
  const existing = store.pending[npub] || {
    first_contact_at: new Date().toISOString(),
    count_held: 0,
  };
  existing.count_held = (existing.count_held || 0) + (meta.increment ?? 0);
  if (meta.nametag && isValidNametag(meta.nametag)) existing.nametag = meta.nametag;
  store.pending[npub] = existing;
  return store;
}

/** True once a pending npub has hit its hold cap — caller then silent-drops (§3.4). */
export function pendingHoldExceeded(store, npub) {
  const p = store.pending?.[npub];
  const cap = store.rate_limits?.pending_hold_max ?? DEFAULT_RATE_LIMITS.pending_hold_max;
  return !!p && (p.count_held || 0) >= cap;
}

/**
 * Approve a contact: trust the IDENTITY at `tier` (default team). F7 is enforced
 * by the CALLER (drop held backlog / require resend) — approval never auto-replays
 * quarantined text as trusted. label/nametag here are OWNER-supplied (F4/F6).
 */
export function approveContact(store, npub, opts = {}) {
  if (!isValidNpub(npub)) throw new Error(`invalid npub: ${npub}`);
  const tier = opts.tier || 'team';
  if (tier !== 'team' && tier !== 'owner') throw new Error(`approve tier must be team|owner, got ${tier}`);
  const nametag = opts.nametag && isValidNametag(opts.nametag) ? opts.nametag : undefined;
  store.blocked = (store.blocked || []).filter((b) => b !== npub);
  delete store.pending[npub];
  store.contacts[npub] = {
    tier,
    ...(nametag ? { nametag } : {}),
    label: sanitizeLabel(opts.label || ''),
    added_by: 'owner',
    added_at: new Date().toISOString(),
    last_seen_seq: store.contacts[npub]?.last_seen_seq ?? 0,
    notes: sanitizeLabel(opts.notes || ''),
  };
  return store;
}

/** Deny a contact → blocked; quarantine purge is the caller's job. */
export function denyContact(store, npub) {
  if (!isValidNpub(npub)) throw new Error(`invalid npub: ${npub}`);
  delete store.contacts[npub];
  delete store.pending[npub];
  if (!store.blocked.includes(npub)) store.blocked.push(npub);
  return store;
}

/** Auto-demotion (§3.4): drop one tier + block after repeated abuse. */
export function demoteContact(store, npub) {
  const c = store.contacts?.[npub];
  if (!c) { denyContact(store, npub); return store; }
  if (c.tier === 'team') { denyContact(store, npub); }
  return store;
}

// ---------------------------------------------------------------------------
// Rate / DoS limiting (§3.4) — pure functions over a mutable `rate` state object
// which the caller PERSISTS (F14). Sliding 60s windows + near-dup suppression.
// ---------------------------------------------------------------------------

export function emptyRateState() {
  return { contacts: {}, global: [], nearDup: {} };
}

function prune(list, cutoff) {
  let i = 0;
  while (i < list.length && list[i] < cutoff) i++;
  return i > 0 ? list.slice(i) : list;
}

/**
 * Consume one unit against the per-contact + global 60s buckets.
 * @returns {{ allowed:boolean, reason:string|null }}
 */
export function checkRate(rate, contactKey, now, limits = DEFAULT_RATE_LIMITS) {
  const windowStart = now - 60_000;
  rate.global = prune(rate.global || [], windowStart);
  rate.contacts[contactKey] = prune(rate.contacts[contactKey] || [], windowStart);

  if (rate.contacts[contactKey].length >= (limits.per_contact_per_min ?? DEFAULT_RATE_LIMITS.per_contact_per_min)) {
    return { allowed: false, reason: 'per_contact_rate_exceeded' };
  }
  if (rate.global.length >= (limits.global_per_min ?? DEFAULT_RATE_LIMITS.global_per_min)) {
    return { allowed: false, reason: 'global_rate_exceeded' };
  }
  rate.contacts[contactKey].push(now);
  rate.global.push(now);
  return { allowed: true, reason: null };
}

/** Near-duplicate suppression — worm/loop damper (§3.4). Mutates rate.nearDup. */
export function isNearDuplicate(rate, bodyHash, now, limits = DEFAULT_RATE_LIMITS) {
  const win = limits.near_dup_window_ms ?? DEFAULT_RATE_LIMITS.near_dup_window_ms;
  // prune
  for (const [h, ts] of Object.entries(rate.nearDup)) {
    if (ts < now - win) delete rate.nearDup[h];
  }
  const seen = rate.nearDup[bodyHash] != null;
  rate.nearDup[bodyHash] = now;
  return seen;
}
