#!/usr/bin/env node
// sphere-helper.mjs — CLI helper wrapping @unicitylabs/sphere-sdk for agent operations.
//
// Requires: @unicitylabs/sphere-sdk (which includes @unicitylabs/nostr-js-sdk)
//
// Subcommands:
//   create-identity                          Generate BIP-39 mnemonic + secp256k1 keypair
//   resolve-nametag <nametag> [--relay <url>]  Resolve nametag → npub via Sphere binding events
//   register-nametag <nametag> --identity <path> [--relay <url>]  Claim a nametag for an identity
//   join-group <name> --identity <path> [--relay <url>]  Create/join NIP-29 group
//   send-dm <npub> <message> --identity <path>           Send NIP-17 encrypted DM
//   check-messages --identity <path> --config <path> [--since <ts>]  Poll for messages
//
// All output goes to stdout as JSON. Errors go to stderr. Exit 0 on success, 1 on error.

import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

// --- Utilities ---

function fail(msg) {
  console.error(`[sphere-helper] ${msg}`);
  process.exit(1);
}

function output(obj) {
  console.log(JSON.stringify(obj, null, 2));
}

function parseArgs(args) {
  const parsed = { _: [] };
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      const key = args[i].slice(2);
      const next = args[i + 1];
      if (next && !next.startsWith('--')) {
        parsed[key] = next;
        i++;
      } else {
        parsed[key] = true;
      }
    } else {
      parsed._.push(args[i]);
    }
  }
  return parsed;
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(resolve(path), 'utf-8'));
  } catch (e) {
    fail(`Cannot read ${path}: ${e.message}`);
  }
}

async function loadSdk() {
  try {
    return await import('@unicitylabs/sphere-sdk');
  } catch {
    fail('@unicitylabs/sphere-sdk is not installed.\nInstall it with: npm install @unicitylabs/sphere-sdk');
  }
}

async function loadNostrSdk() {
  try {
    return await import('@unicitylabs/nostr-js-sdk');
  } catch {
    fail('@unicitylabs/nostr-js-sdk is not available.\nIt should be installed as a dependency of @unicitylabs/sphere-sdk.');
  }
}

// Build a NostrKeyManager from an identity.json, tolerating multiple key sources
// and legacy encodings. We prefer the mnemonic (deterministic + always standard
// under the current SDK), then a raw private-key hex, then an nsec. Identities
// created with sphere-sdk <0.5 stored npub/nsec with a spurious segwit version
// byte (33-byte payload) that the current nostr-js-sdk rejects — deriving from
// the mnemonic sidesteps that, and each branch is guarded so a bad source falls
// through to the next instead of hard-failing the whole daemon.
async function keyManagerFromIdentity(identity, nostr, sdk) {
  const attempts = [];

  if (identity.mnemonic) {
    attempts.push(() => {
      const master = sdk.identityFromMnemonicSync(identity.mnemonic);
      const derivationPath = identity.derivation_path || sdk.DEFAULT_DERIVATION_PATH;
      const child = sdk.deriveKeyAtPath(master.privateKey, master.chainCode, derivationPath);
      return nostr.NostrKeyManager.fromPrivateKeyHex(child.privateKey);
    });
  }
  if (identity.private_key) {
    attempts.push(() => nostr.NostrKeyManager.fromPrivateKeyHex(identity.private_key));
  }
  if (identity.nsec) {
    attempts.push(() => nostr.NostrKeyManager.fromNsec(identity.nsec));
  }

  if (attempts.length === 0) fail('Identity must contain mnemonic, private_key, or nsec');

  let lastErr;
  for (const attempt of attempts) {
    try {
      return attempt();
    } catch (e) {
      lastErr = e;
    }
  }
  fail(`Could not load identity key material: ${lastErr ? lastErr.message : 'unknown error'}`);
}

// Create a NostrClient from an identity.json file
async function createNostrClient(identity, relayUrls) {
  const nostr = await loadNostrSdk();
  const sdk = await loadSdk();

  const keyManager = await keyManagerFromIdentity(identity, nostr, sdk);

  const client = new nostr.NostrClient(keyManager);
  await client.connect(...relayUrls);
  return { client, keyManager, nostr };
}

// Decode npub to hex pubkey using nostr-js-sdk's decodeNpub
function npubToHex(npubOrHex, nostrSdk) {
  if (npubOrHex.startsWith('npub1')) {
    const decoded = nostrSdk.decodeNpub(npubOrHex);
    return Buffer.from(decoded).toString('hex');
  }
  return npubOrHex;
}

// --- Subcommands ---

async function createIdentity() {
  const sdk = await loadSdk();
  const nostr = await loadNostrSdk();

  try {
    const mnemonic = sdk.generateMnemonic();
    const master = sdk.identityFromMnemonicSync(mnemonic);
    const derivationPath = sdk.DEFAULT_DERIVATION_PATH;
    const child = sdk.deriveKeyAtPath(master.privateKey, master.chainCode, derivationPath);
    const publicKey = sdk.getPublicKey(child.privateKey);

    // npub/nsec bech32 encoding moved out of sphere-sdk (>=0.5) into nostr-js-sdk.
    // Derive them from the same secp256k1 child key via NostrKeyManager, which
    // handles the 32-byte x-only pubkey encoding internally (same npub as before).
    const keyManager = nostr.NostrKeyManager.fromPrivateKeyHex(child.privateKey);
    const npub = keyManager.getNpub();
    const nsec = keyManager.getNsec();

    output({
      created_at: new Date().toISOString(),
      mnemonic,
      public_key: publicKey,
      npub,
      nsec,
      derivation_path: derivationPath,
    });
  } catch (e) {
    fail(`Failed to create identity: ${e.message}`);
  }
}

// Decode an npub (bech32) → 32-byte x-only pubkey hex. Used by the registry to
// PRE-AUTHORIZE a peer by npub before we have ever received a message from it
// (there is no registry entry to resolve yet). Invalid npub → exit 1 with an error,
// so callers never write a bogus key.
async function npubToHexCmd(args) {
  const input = args._[0];
  if (!input) fail('Usage: npub-to-hex <npub>');
  const nostr = await loadNostrSdk();
  try {
    const hex = npubToHex(input, nostr).toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(hex)) fail(`Not a valid npub/pubkey: '${input}'`);
    output({ npub: input.startsWith('npub1') ? input : null, hex });
  } catch (e) {
    fail(`Invalid npub '${input}': ${e.message}`);
  }
}

// From raw kind-30078 nametag-binding events (all carrying the same hashed-nametag
// `t` tag), pick the UNIP-01 owner: prefer events carrying the ownership marker
// ["L","unicity:nametag"], and among those the earliest created_at (relay first-seen
// ≈ first-owner, per UNIP-01 single-owner semantics). Returns the author pubkey hex
// (32-byte x-only, lowercase) or null. Keeps resolution correct even when several
// candidates exist (e.g. a stale pre-marker binding alongside the owning one).
function pickBindingAuthor(events) {
  if (!Array.isArray(events) || events.length === 0) return null;
  const marked = events.filter((e) => Array.isArray(e.tags)
    && e.tags.some((t) => Array.isArray(t) && t[0] === 'L' && t[1] === 'unicity:nametag'));
  const pool = marked.length ? marked : events;
  pool.sort((a, b) => (Number(a.created_at) || 0) - (Number(b.created_at) || 0));
  const winner = pool.find((e) => typeof e.pubkey === 'string' && /^[0-9a-f]{64}$/i.test(e.pubkey));
  return winner ? winner.pubkey.toLowerCase() : null;
}

// Resolve a nametag → npub by looking up its binding event on Nostr. Two paths, in
// order: (1) the SDK NostrClient resolver (queryPubkeyByNametag, falling back to
// queryBindingByNametag) — the authenticated, first-seen-wins lookup the sphere-sdk
// itself uses; (2) a raw NIP-01 REQ for the kind-30078 binding tagged with the hashed
// nametag. The raw path is the reliable backstop because the SDK's subscribe()-based
// query does not always deliver EVENTs against the Unicity testnet relay (same reason
// fetchEventsRaw exists). Prints {nametag, hash, npub, hex}; npub:null + exit 2 when
// the name has no binding (so callers can distinguish "unresolved" from a hard error).
async function resolveNametag(nametag, args) {
  if (!nametag) fail('Usage: resolve-nametag <nametag> [--relay <url>]');

  const sdk = await loadSdk();
  const nostr = await loadNostrSdk();

  // Validate and normalize the nametag
  const normalized = sdk.normalizeNametag(nametag);
  if (!sdk.isValidNametag(normalized)) {
    fail(`Invalid nametag: '${nametag}'. Must be 3-20 chars, lowercase alphanumeric, hyphens, underscores.`);
  }

  // Hash for lookup (matches the relay-side `t`-tag on binding events).
  const hash = sdk.hashNametag(normalized);
  const relay = (args && args.relay) || 'wss://nostr-relay.testnet.unicity.network';

  let hex = null;

  // (1) SDK resolver — read-only, so an ephemeral key is enough to query the relay.
  try {
    const keyManager = nostr.NostrKeyManager.generate();
    const client = new nostr.NostrClient(keyManager);
    if (typeof client.setQueryTimeout === 'function') client.setQueryTimeout(6000);
    await client.connect(relay);
    try {
      hex = await client.resolveNametag?.(normalized)
        ?? await client.queryPubkeyByNametag(normalized);
      if (!hex) {
        const info = (await client.resolveNametagInfo?.(normalized))
          || (await client.queryBindingByNametag(normalized));
        if (info && (info.transportPubkey || info.hex)) hex = info.transportPubkey || info.hex;
      }
    } finally {
      try { client.disconnect(); } catch {}
    }
  } catch {
    // Fall through to the raw-REQ backstop below.
  }

  // (2) Raw NIP-01 REQ backstop for the kind-30078 binding event.
  if (!hex) {
    try {
      const events = await fetchEventsRaw(relay, [{ kinds: [30078], '#t': [hash] }]);
      hex = pickBindingAuthor(events);
    } catch {
      hex = null;
    }
  }

  if (!hex || !/^[0-9a-f]{64}$/i.test(hex)) {
    output({ nametag: normalized, hash, npub: null, hex: null });
    process.exit(2);
  }

  hex = hex.toLowerCase();
  const npub = nostr.encodeNpub(Buffer.from(hex, 'hex'));
  output({ nametag: normalized, hash, npub, hex });
}

// Register (claim) a nametag for an identity by publishing its Nostr binding event.
// This is a REAL network action bound to the given identity — it claims the name for
// that identity's key. Idempotent-friendly: if the name is already bound to THIS
// identity we report success; if it is bound to a DIFFERENT key we fail clearly
// (UNIP-01 single-owner). Ownership is pre-checked via a raw REQ (reliable on this
// relay) and the publish goes through the SDK's publishNametagBinding.
async function registerNametag(args) {
  const nametag = args._[0];
  if (!nametag) fail('Usage: register-nametag <nametag> --identity <path> [--relay <url>]');

  const identityPath = args.identity;
  if (!identityPath) fail('--identity <path> is required');

  const identity = readJson(identityPath);
  const relay = args.relay || 'wss://nostr-relay.testnet.unicity.network';

  const sdk = await loadSdk();
  const normalized = sdk.normalizeNametag(nametag);
  if (!sdk.isValidNametag(normalized)) {
    fail(`Invalid nametag: '${nametag}'. Must be 3-20 chars, lowercase alphanumeric, hyphens, underscores.`);
  }
  const hash = sdk.hashNametag(normalized);

  const { client, keyManager } = await createNostrClient(identity, [relay]);
  const selfHex = keyManager.getPublicKeyHex().toLowerCase();
  const selfNpub = keyManager.getNpub();

  try {
    // Reliable ownership pre-check via raw REQ (subscribe-based queries can miss here).
    const existing = pickBindingAuthor(await fetchEventsRaw(relay, [{ kinds: [30078], '#t': [hash] }]));
    if (existing && existing === selfHex) {
      output({ status: 'already-registered', nametag: normalized, hash, npub: selfNpub, hex: selfHex, relay });
      return;
    }
    if (existing && existing !== selfHex) {
      fail(`Nametag '${normalized}' is already registered to a different identity (pubkey ${existing.slice(0, 12)}…).`);
    }

    // Extended identity: carry the chain pubkey when the identity file has one (mirrors
    // sphere-sdk's publishIdentityBinding(nametag) — unicityAddress = our Nostr pubkey).
    const idParams = {};
    if (typeof identity.public_key === 'string' && /^[0-9a-f]{2,}$/i.test(identity.public_key)) {
      idParams.publicKey = identity.public_key;
    }

    let ok = false;
    try {
      ok = await client.publishNametagBinding(normalized, selfHex, idParams);
    } catch (e) {
      if (/already claimed|owned by another/i.test(e.message || '')) {
        // Lost a race or a stale-cache false negative — re-check via raw REQ.
        const owner = pickBindingAuthor(await fetchEventsRaw(relay, [{ kinds: [30078], '#t': [hash] }]));
        if (owner && owner === selfHex) {
          output({ status: 'already-registered', nametag: normalized, hash, npub: selfNpub, hex: selfHex, relay });
          return;
        }
        fail(`Nametag '${normalized}' is already claimed by another identity.`);
      }
      throw e;
    }

    if (!ok) fail(`Failed to register nametag '${normalized}' (relay did not accept the binding).`);
    output({ status: 'registered', nametag: normalized, hash, npub: selfNpub, hex: selfHex, relay });
  } catch (e) {
    fail(`Failed to register nametag '${normalized}': ${e.message}`);
  } finally {
    try { client.disconnect(); } catch {}
  }
}

async function joinGroup(args) {
  const groupName = args._[0];
  if (!groupName) fail('Usage: join-group <name> --identity <path> [--relay <url>]');

  const identityPath = args.identity;
  if (!identityPath) fail('--identity <path> is required');

  const identity = readJson(identityPath);
  const relay = args.relay || 'wss://nostr-relay.testnet.unicity.network';

  // Use NostrClient directly (same approach as sphere-sdk's GroupChatModule)
  const { client, keyManager, nostr } = await createNostrClient(identity, [relay]);

  try {
    // NIP-29: Join request is kind 9021 with group tag
    // For now, output the group config without actual relay interaction
    // (NIP-29 group join requires relay-side support)
    const pubkeyHex = keyManager.getPublicKeyHex();

    output({
      group_id: groupName,
      name: groupName,
      relay,
      member_pubkey: pubkeyHex,
      status: 'configured',
    });
  } catch (e) {
    fail(`Failed to join group '${groupName}': ${e.message}`);
  } finally {
    try { client.disconnect(); } catch {}
  }
}

async function sendDm(args) {
  const recipientNpub = args._[0];
  const message = args._[1];
  if (!recipientNpub || !message) fail('Usage: send-dm <npub> <message> --identity <path>');

  const identityPath = args.identity;
  if (!identityPath) fail('--identity <path> is required');

  const identity = readJson(identityPath);
  const relay = args.relay || 'wss://nostr-relay.testnet.unicity.network';

  const { client, nostr } = await createNostrClient(identity, [relay]);

  try {
    // Decode npub to hex pubkey
    const recipientHex = npubToHex(recipientNpub, nostr);

    // Send NIP-17 encrypted DM via NostrClient
    await client.sendPrivateMessage(recipientHex, message);
    output({ status: 'sent', to: recipientNpub, length: message.length });
  } catch (e) {
    fail(`Failed to send DM: ${e.message}`);
  } finally {
    try { client.disconnect(); } catch {}
  }
}

// Fetch stored events from a relay via a raw NIP-01 REQ.
//
// WHY RAW: nostr-js-sdk 0.6's `client.subscribe()` sends a structurally valid
// REQ but never delivers the relay's EVENT replies to the callback against the
// Unicity testnet relay (proven: raw REQ returns the events, SDK subscribe
// returns none). The relay itself is a standard NIP-01 store, so we read the
// wire directly and use the SDK only to unwrap gift wraps. One REQ per filter;
// resolve when every sub has sent EOSE, or on a timeout backstop.
function fetchEventsRaw(relayUrl, filters, timeoutMs = 6000) {
  return new Promise((resolvePromise) => {
    const byId = new Map();
    const open = new Set(filters.map((_, i) => `q${i}`));
    let ws;
    let settled = false;
    let timer;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { ws.close(); } catch {}
      resolvePromise([...byId.values()]);
    };
    try {
      ws = new WebSocket(relayUrl);
    } catch {
      resolvePromise([]);
      return;
    }
    timer = setTimeout(finish, timeoutMs);
    ws.onopen = () => {
      filters.forEach((f, i) => {
        try { ws.send(JSON.stringify(['REQ', `q${i}`, f])); } catch {}
      });
    };
    ws.onmessage = (e) => {
      let a;
      try { a = JSON.parse(typeof e.data === 'string' ? e.data : e.data.toString()); } catch { return; }
      if (a[0] === 'EVENT' && a[2] && a[2].id) {
        byId.set(a[2].id, a[2]);
      } else if (a[0] === 'EOSE') {
        open.delete(a[1]);
        if (open.size === 0) finish();
      }
    };
    ws.onerror = () => finish();
    ws.onclose = () => finish();
  });
}

async function checkMessages(args) {
  const identityPath = args.identity;
  const configPath = args.config;
  if (!identityPath || !configPath) fail('Usage: check-messages --identity <path> --config <path> [--since <timestamp>]');

  const identity = readJson(identityPath);
  const config = readJson(configPath);
  const since = args.since ? parseInt(args.since, 10) : Math.floor(Date.now() / 1000) - 600; // default: last 10 minutes

  // NIP-17 randomizes the OUTER gift-wrap (kind 1059) created_at BACKWARD by up to
  // ~2 days to resist timing analysis, so a DM's outer timestamp can fall well
  // before `since` and be silently skipped. Widen the gift-wrap query window by
  // this skew; the daemon dedups by event id so the wider window can't re-deliver.
  const giftwrapSkew = parseInt(process.env.GIFTWRAP_SKEW_SECONDS || '172800', 10);
  const dmSince = Math.max(0, since - giftwrapSkew);

  const relays = config.group?.relays || ['wss://nostr-relay.testnet.unicity.network'];
  const groupId = config.group?.id;

  const nostr = await loadNostrSdk();
  const sdk = await loadSdk();
  const keyManager = await keyManagerFromIdentity(identity, nostr, sdk);
  // NostrClient is used ONLY to unwrap gift wraps — no network subscription.
  const client = new nostr.NostrClient(keyManager);
  const myPubkeyHex = keyManager.getPublicKeyHex();
  const ownerPubkeyHex = config.owner_npub ? npubToHex(config.owner_npub, nostr) : null;

  // NIP-17 gift-wrapped DMs addressed to us (+ optional NIP-29 group messages).
  const filters = [{ kinds: [nostr.GIFT_WRAP], '#p': [myPubkeyHex], since: dmSince }];
  if (groupId) filters.push({ kinds: [9], '#h': [groupId], since });

  try {
    // Query every configured relay; merge raw events by id.
    const rawById = new Map();
    for (const relay of relays) {
      const evs = await fetchEventsRaw(relay, filters);
      for (const ev of evs) if (ev && ev.id) rawById.set(ev.id, ev);
    }

    const messages = [];
    for (const event of rawById.values()) {
      if (event.kind === nostr.GIFT_WRAP) {
        try {
          const unwrapped = client.unwrapPrivateMessage(event);
          if (!unwrapped) continue;
          const senderPubkey = unwrapped.pubkey || unwrapped.senderPubkey || '';
          messages.push({
            // `id` is the outer gift-wrap event id — stable per stored relay
            // event and used by the daemon to dedup across overlapping polls.
            id: event.id,
            type: 'dm',
            from: senderPubkey,
            body: unwrapped.content || unwrapped.message || '',
            timestamp: new Date((unwrapped.created_at || event.created_at) * 1000).toISOString(),
            priority: senderPubkey === ownerPubkeyHex,
            read: false,
          });
        } catch {
          // Failed to unwrap — not for us or corrupted
        }
      } else if (event.kind === 9) {
        if (event.pubkey === myPubkeyHex) continue; // skip own messages
        messages.push({
          id: event.id,
          type: 'group',
          from: event.pubkey || '',
          body: event.content || '',
          timestamp: new Date(event.created_at * 1000).toISOString(),
          priority: event.pubkey === ownerPubkeyHex,
          read: false,
        });
      }
    }

    // Oldest first, so hooks process in chronological order.
    messages.sort((a, b) => new Date(a.timestamp) - new Date(b.timestamp));
    output({ messages, polled_at: new Date().toISOString() });
  } catch (e) {
    fail(`Failed to check messages: ${e.message}`);
  } finally {
    try { client.disconnect(); } catch {}
  }
}

// Live inbound stream: keep a relay socket OPEN past EOSE and emit each NEW unwrapped
// DM (and optional group message) as one NDJSON line on stdout, for sub-second delivery
// instead of the daemon's interval poll. Reuses the SAME raw-REQ + gift-wrap-unwrap path
// as fetchEventsRaw/checkMessages (the SDK's subscribe() never delivers EVENTs against the
// Unicity relay — see fetchEventsRaw note), but never closes on EOSE. Auto-reconnects with
// exponential backoff per relay; a fresh `since = now − giftwrapSkew` on each (re)connect
// plus a per-process seen-set means a reconnect can never re-deliver or drop a message.
async function watchMessages(args) {
  const identityPath = args.identity;
  const configPath = args.config;
  if (!identityPath || !configPath) fail('Usage: watch --identity <path> --config <path>');

  const identity = readJson(identityPath);
  const config = readJson(configPath);

  const giftwrapSkew = parseInt(process.env.GIFTWRAP_SKEW_SECONDS || '172800', 10);
  const relays = config.group?.relays || ['wss://nostr-relay.testnet.unicity.network'];
  const groupId = config.group?.id;

  const nostr = await loadNostrSdk();
  const sdk = await loadSdk();
  const keyManager = await keyManagerFromIdentity(identity, nostr, sdk);
  const client = new nostr.NostrClient(keyManager); // unwrap only — no SDK subscription
  const myPubkeyHex = keyManager.getPublicKeyHex();
  const ownerPubkeyHex = config.owner_npub ? npubToHex(config.owner_npub, nostr) : null;

  // Bounded per-process dedup (the daemon dedups again by id, so this is just to avoid
  // re-emitting the same stored gift-wrap the relay replays on every fresh REQ).
  const SEEN_CAP = 5000;
  const seen = new Set();
  const remember = (id) => {
    seen.add(id);
    if (seen.size > SEEN_CAP) {
      let drop = seen.size - SEEN_CAP;
      for (const k of seen) { seen.delete(k); if (--drop <= 0) break; }
    }
  };

  const emit = (msg) => { try { process.stdout.write(JSON.stringify(msg) + '\n'); } catch {} };

  const handleEvent = (ev) => {
    if (!ev || !ev.id || seen.has(ev.id)) return;
    if (ev.kind === nostr.GIFT_WRAP) {
      let unwrapped;
      try { unwrapped = client.unwrapPrivateMessage(ev); } catch { return; }
      if (!unwrapped) return;
      remember(ev.id);
      const senderPubkey = unwrapped.pubkey || unwrapped.senderPubkey || '';
      emit({
        id: ev.id, type: 'dm', from: senderPubkey,
        body: unwrapped.content || unwrapped.message || '',
        timestamp: new Date((unwrapped.created_at || ev.created_at) * 1000).toISOString(),
        priority: senderPubkey === ownerPubkeyHex, read: false,
      });
    } else if (ev.kind === 9) {
      if (ev.pubkey === myPubkeyHex) return; // skip our own group messages
      remember(ev.id);
      emit({
        id: ev.id, type: 'group', from: ev.pubkey || '',
        body: ev.content || '',
        timestamp: new Date(ev.created_at * 1000).toISOString(),
        priority: ev.pubkey === ownerPubkeyHex, read: false,
      });
    }
  };

  const connect = (relayUrl) => {
    let backoff = 1000;
    const open = () => {
      let ws;
      let settled = false;
      const nowSec = Math.floor(Date.now() / 1000);
      const filters = [{ kinds: [nostr.GIFT_WRAP], '#p': [myPubkeyHex], since: Math.max(0, nowSec - giftwrapSkew) }];
      if (groupId) filters.push({ kinds: [9], '#h': [groupId], since: Math.max(0, nowSec - 60) });
      const reconnect = () => {
        if (settled) return; settled = true;
        try { ws && ws.close(); } catch {}
        const wait = backoff; backoff = Math.min(backoff * 2, 30000);
        console.error(`[sphere-helper] watch: ${relayUrl} disconnected — reconnecting in ${wait}ms`);
        setTimeout(open, wait);
      };
      try { ws = new WebSocket(relayUrl); } catch { reconnect(); return; }
      ws.onopen = () => {
        backoff = 1000; // reset backoff on a good connection
        filters.forEach((f, i) => { try { ws.send(JSON.stringify(['REQ', `w${i}`, f])); } catch {} });
        console.error(`[sphere-helper] watch: subscribed on ${relayUrl}`);
      };
      ws.onmessage = (e) => {
        let a;
        try { a = JSON.parse(typeof e.data === 'string' ? e.data : e.data.toString()); } catch { return; }
        if (a[0] === 'EVENT' && a[2]) handleEvent(a[2]);
        // EOSE is intentionally IGNORED — the socket stays open for live events.
      };
      ws.onerror = () => reconnect();
      ws.onclose = () => reconnect();
    };
    open();
  };

  console.error(`[sphere-helper] watch: streaming ${relays.length} relay(s) for ${myPubkeyHex.slice(0, 12)}…`);
  relays.forEach(connect);
  await new Promise(() => {}); // run until the process is killed
}

// --- One-time invite tickets (kind-30777 signed events) ---
// ticket-sign builds + schnorr-signs the ticket event over the canonical payload;
// ticket-verify recomputes the NIP-01 id, verifies the sig, and REQUIRES that the
// signing pubkey equals the decoded payload.iss (a signature by any other key is
// invalid). No relay interaction — pure local crypto via the same SDK send-dm uses.
async function ticketSign(args) {
  const identityPath = args.identity;
  if (!identityPath) fail("--identity <path> is required");
  const payloadJson = args._[0];
  if (!payloadJson) fail("Usage: ticket-sign --identity <path> '<payload-json>'");
  let payload;
  try { payload = JSON.parse(payloadJson); } catch (e) { fail(`Invalid payload JSON: ${e.message}`); }
  const identity = readJson(identityPath);
  const nostr = await loadNostrSdk();
  const sdk = await loadSdk();
  const keyManager = await keyManagerFromIdentity(identity, nostr, sdk);
  const contentB64 = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const created_at = Math.floor(Date.now() / 1000);
  const ev = nostr.Event.create(keyManager, {
    kind: 30777,
    created_at,
    tags: [["d", String(payload.tid || "")], ["expiration", String(payload.exp || 0)]],
    content: contentB64,
  });
  process.stdout.write(JSON.stringify(ev.toJSON()) + "\n");
}

async function ticketVerify(args) {
  const eventJson = args._[0];
  if (!eventJson) fail("Usage: ticket-verify '<event-json>'");
  const nostr = await loadNostrSdk();
  let ev;
  try {
    const obj = typeof eventJson === "string" ? JSON.parse(eventJson) : eventJson;
    ev = nostr.Event.fromJSON(obj);
  } catch (e) { output({ valid: false, reason: "bad-json" }); process.exit(1); }
  let ok = false;
  try { ok = ev.verify(); } catch { ok = false; }
  if (!ok) { output({ valid: false, reason: "bad-signature" }); process.exit(1); }
  let payload;
  try { payload = JSON.parse(Buffer.from(ev.content, "base64url").toString("utf8")); }
  catch { output({ valid: false, reason: "bad-content" }); process.exit(1); }
  let issHex;
  try { issHex = npubToHex(String(payload.iss || ""), nostr).toLowerCase(); }
  catch { output({ valid: false, reason: "bad-iss" }); process.exit(1); }
  if (!/^[0-9a-f]{64}$/.test(issHex) || ev.pubkey.toLowerCase() !== issHex) {
    output({ valid: false, reason: "iss-mismatch", pubkey: ev.pubkey, issHex }); process.exit(1);
  }
  output({ valid: true, pubkey: ev.pubkey.toLowerCase(), npub: payload.iss, payload });
}

// --- Main dispatch ---

const args = parseArgs(process.argv.slice(2));
const command = args._.shift();

switch (command) {
  case 'create-identity':
    await createIdentity();
    break;
  case 'resolve-nametag':
    await resolveNametag(args._[0], args);
    break;
  case 'register-nametag':
    await registerNametag(args);
    break;
  case 'npub-to-hex':
    await npubToHexCmd(args);
    break;
  case 'ticket-sign':
    await ticketSign(args);
    break;
  case 'ticket-verify':
    await ticketVerify(args);
    break;
  case 'join-group':
    await joinGroup(args);
    break;
  case 'send-dm':
    await sendDm(args);
    break;
  case 'check-messages':
    await checkMessages(args);
    break;
  case 'watch':
    await watchMessages(args);
    break;
  default:
    fail(`Unknown command: ${command || '(none)'}
Usage: sphere-helper.mjs <command> [options]

Commands:
  create-identity                          Generate BIP-39 mnemonic + keypair
  resolve-nametag <nametag> [--relay <url>]   Resolve nametag → npub (via Sphere binding events)
  register-nametag <nametag> --identity <path> [--relay <url>]  Claim a nametag for an identity
  join-group <name> --identity <path>      Join/create NIP-29 group
  send-dm <npub> <msg> --identity <path>   Send encrypted DM
  check-messages --identity <p> --config <p>  Poll for new messages (one-shot)
  watch --identity <p> --config <p>        Stream new messages as NDJSON (live, reconnecting)
  npub-to-hex <npub>                       Decode an npub to its 32-byte pubkey hex`);
}
