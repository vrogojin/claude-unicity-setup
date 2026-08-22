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
//   send-dm <npub> --body-file <path>|<stdin> --identity <path>  Send NIP-17 encrypted DM (body via file/stdin, never argv)
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

// Read a value that may carry a SECRET (a ticket, an envelope with a ticket secret,
// a DM body) WITHOUT ever exposing it on argv — where any local user could read it via
// `ps` / /proc/<pid>/cmdline. Order: an explicit `--<fileFlag> <path>` (0600 file), else
// stdin (fd 0). Callers pipe the value in; nothing secret is passed as a CLI argument.
function readSecretInput(args, fileFlag) {
  if (args[fileFlag]) {
    try { return readFileSync(resolve(args[fileFlag]), 'utf-8'); }
    catch (e) { fail(`Cannot read --${fileFlag} ${args[fileFlag]}: ${e.message}`); }
  }
  try { return readFileSync(0, 'utf-8'); }
  catch (e) { fail(`No input on stdin and no --${fileFlag} given: ${e.message}`); }
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

  // (2) Raw NIP-01 REQ backstop for the kind-30078 binding event. When an --identity is given
  // we sign NIP-42 AUTH with it, so nametag resolution keeps working against an auth-enforcing
  // relay (the anonymous read above uses an ephemeral key an allow-list would reject).
  if (!hex) {
    try {
      let authSigner = null;
      if (args && args.identity) {
        try {
          const km = await keyManagerFromIdentity(readJson(args.identity), nostr, sdk);
          authSigner = makeAuthSigner(nostr, km);
        } catch { authSigner = null; }
      }
      const events = await fetchEventsRaw(relay, [{ kinds: [30078], '#t': [hash] }], 6000, authSigner);
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

  const { client, keyManager, nostr } = await createNostrClient(identity, [relay]);
  const selfHex = keyManager.getPublicKeyHex().toLowerCase();
  const selfNpub = keyManager.getNpub();
  // NIP-42 signer for the raw ownership-precheck REQs (the SDK publish path auths itself).
  const authSigner = makeAuthSigner(nostr, keyManager);

  try {
    // Reliable ownership pre-check via raw REQ (subscribe-based queries can miss here).
    const existing = pickBindingAuthor(await fetchEventsRaw(relay, [{ kinds: [30078], '#t': [hash] }], 6000, authSigner));
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
        const owner = pickBindingAuthor(await fetchEventsRaw(relay, [{ kinds: [30078], '#t': [hash] }], 6000, authSigner));
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
  if (!recipientNpub) fail('Usage: send-dm <npub> --body-file <path>|<stdin> --identity <path>');

  // The message body may carry a ticket secret (ticket.redeem) — take it from --body-file
  // or stdin, NEVER argv. Read it BEFORE any network work so a leak-test can inspect a
  // still-blocked process and so we fail fast on a missing body. A positional 2nd arg is
  // accepted only as an explicit non-secret fallback for manual use.
  let message = args._[1];
  if (message === undefined) message = readSecretInput(args, 'body-file');
  if (!message) fail('send-dm: empty message body (provide via --body-file or stdin)');

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

// --- NIP-42 relay authentication (client side) ------------------------------------------
// Our critical relay reads/writes go over RAW WebSockets (fetchEventsRaw / watch / relayPublish)
// because the SDK's subscribe() never delivers EVENTs against the Unicity relay (see the note on
// fetchEventsRaw). The SDK's own NostrClient answers NIP-42 AUTH challenges — but these raw paths
// did NOT, so the moment the relay enforces AUTH (`auth-required`) to shut coordination-traffic
// harvesters out, every raw read/write would break. These helpers make the raw paths authenticate
// REACTIVELY: a transparent no-op against a relay that never challenges, and a signed kind-22242
// (NIP-42) response the instant one does — which is what lets the owner turn on relay-side AUTH +
// pubkey allow-list (the coord-harvest fix) without stranding our own daemon.

const NIP42_AUTH_KIND = 22242;

// `reason` (CLOSED/OK message) is an auth-required signal. Accept the three on-the-wire shapes
// the SDK also tolerates: `auth-required`, `auth-required:<detail>`, `auth-required <detail>`.
function isAuthRequired(reason) {
  const r = String(reason || '');
  return r === 'auth-required' || r.startsWith('auth-required:') || r.startsWith('auth-required ');
}

// Build a signer bound to a keyManager. `signer(relayUrl, challenge)` → a signed kind-22242
// event JSON (with `.id`) proving control of our pubkey for THIS relay + challenge. Returns null
// when we have no identity to sign with (anonymous read against a non-auth relay).
function makeAuthSigner(nostr, keyManager) {
  if (!keyManager) return null;
  return (relayUrl, challenge) => nostr.Event.create(keyManager, {
    kind: NIP42_AUTH_KIND,
    created_at: Math.floor(Date.now() / 1000),
    tags: [['relay', relayUrl], ['challenge', String(challenge)]],
    content: '',
  }).toJSON();
}

// Per-socket NIP-42 state machine. Feed it every parsed relay frame; it answers an AUTH
// challenge with a signed kind-22242 event and, once the relay ACKs it (`OK <authId> true`),
// invokes onAuthed() so the caller can (re-)send its REQ/EVENT — a relay ignores or CLOSEs
// pre-auth requests with `auth-required`. `handle(frame)` returns true when it consumed the
// frame (an AUTH challenge or the OK for our own AUTH event), so callers `return` early on it.
function nip42Machine(getWs, relayUrl, signer, onAuthed) {
  let authId = null;
  let authed = false;
  return {
    handle(a) {
      if (!Array.isArray(a)) return false;
      if (a[0] === 'AUTH' && typeof a[1] === 'string') {
        if (authed || !signer) return true; // consumed either way — never double-AUTH
        try {
          const ev = signer(relayUrl, a[1]);
          authId = ev && ev.id;
          getWs().send(JSON.stringify(['AUTH', ev]));
        } catch {}
        return true;
      }
      if (a[0] === 'OK' && authId && a[1] === authId) { // the relay's verdict on OUR auth event
        if (a[2] === true && !authed) { authed = true; try { onAuthed(); } catch {} }
        return true;
      }
      return false;
    },
    isAuthed() { return authed; },
    canAuth() { return !!signer; },
  };
}

// Fetch stored events from a relay via a raw NIP-01 REQ.
//
// WHY RAW: nostr-js-sdk 0.6's `client.subscribe()` sends a structurally valid
// REQ but never delivers the relay's EVENT replies to the callback against the
// Unicity testnet relay (proven: raw REQ returns the events, SDK subscribe
// returns none). The relay itself is a standard NIP-01 store, so we read the
// wire directly and use the SDK only to unwrap gift wraps. One REQ per filter;
// resolve when every sub has sent EOSE, or on a timeout backstop.
//
// `signer` (optional) enables NIP-42: on an AUTH challenge we sign+send a kind-22242 event and,
// once the relay ACKs it, re-issue every REQ (a relay CLOSEs pre-auth REQs with `auth-required`).
function fetchEventsRaw(relayUrl, filters, timeoutMs = 6000, signer = null) {
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
    const sendReqs = () => {
      filters.forEach((f, i) => {
        try { ws.send(JSON.stringify(['REQ', `q${i}`, f])); } catch {}
      });
    };
    // After a successful AUTH, re-arm every sub — the relay dropped/CLOSED the pre-auth REQs.
    const nip42 = nip42Machine(() => ws, relayUrl, signer, () => {
      open.clear();
      filters.forEach((_, i) => open.add(`q${i}`));
      sendReqs();
    });
    ws.onopen = () => { sendReqs(); };
    ws.onmessage = (e) => {
      let a;
      try { a = JSON.parse(typeof e.data === 'string' ? e.data : e.data.toString()); } catch { return; }
      if (nip42.handle(a)) return;
      if (a[0] === 'EVENT' && a[2] && a[2].id) {
        byId.set(a[2].id, a[2]);
      } else if (a[0] === 'EOSE') {
        open.delete(a[1]);
        if (open.size === 0) finish();
      } else if (a[0] === 'CLOSED') {
        // NIP-42: a pre-auth REQ is CLOSED with `auth-required`; the AUTH answer + resub
        // (onAuthed) re-opens it, so keep the sub pending. Any NON-auth CLOSED is terminal.
        if (!(isAuthRequired(a[2]) && nip42.canAuth() && !nip42.isAuthed())) {
          open.delete(a[1]);
          if (open.size === 0) finish();
        }
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

  // NIP-42: sign AUTH challenges with our REAL identity key (the daemon's inbox poll is the
  // hot path an auth-enforcing relay must keep serving to us and only us).
  const authSigner = makeAuthSigner(nostr, keyManager);

  try {
    // Query every configured relay; merge raw events by id.
    const rawById = new Map();
    for (const relay of relays) {
      const evs = await fetchEventsRaw(relay, filters, 6000, authSigner);
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
  // NIP-42: the live subscription authenticates with our real key so it survives an
  // auth-enforcing relay (this is the sub-second delivery path the daemon depends on).
  const authSigner = makeAuthSigner(nostr, keyManager);

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
      const sendReqs = () => {
        filters.forEach((f, i) => { try { ws.send(JSON.stringify(['REQ', `w${i}`, f])); } catch {} });
      };
      // NIP-42: on a successful AUTH the relay expects us to re-issue the (pre-auth-dropped) subs.
      const nip42 = nip42Machine(() => ws, relayUrl, authSigner, () => sendReqs());
      ws.onopen = () => {
        backoff = 1000; // reset backoff on a good connection
        sendReqs();
        console.error(`[sphere-helper] watch: subscribed on ${relayUrl}`);
      };
      ws.onmessage = (e) => {
        let a;
        try { a = JSON.parse(typeof e.data === 'string' ? e.data : e.data.toString()); } catch { return; }
        if (nip42.handle(a)) return;
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
  // The payload embeds the ticket SECRET — read it from --in-file or stdin, never argv.
  const payloadJson = readSecretInput(args, "in-file");
  if (!payloadJson) fail("Usage: ticket-sign --identity <path> (payload JSON via --in-file or stdin)");
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
  // The event content is base64url(payload) and the payload embeds the ticket SECRET —
  // read the event from --in-file or stdin, never argv.
  const eventJson = readSecretInput(args, "in-file");
  if (!eventJson) fail("Usage: ticket-verify (event JSON via --in-file or stdin)");
  const nostr = await loadNostrSdk();
  let ev;
  try {
    const obj = typeof eventJson === "string" ? JSON.parse(eventJson) : eventJson;
    ev = nostr.Event.fromJSON(obj);
  } catch (e) { output({ valid: false, reason: "bad-json" }); process.exit(1); }
  // Defense-in-depth: only a kind-30777 event is a ticket; reject anything else before we
  // treat its .content as a ticket payload.
  if (Number(ev.kind) !== 30777) { output({ valid: false, reason: "wrong-kind", kind: ev.kind }); process.exit(1); }
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

// --- Short v2 tickets (ut2_<secret>) — relay-published kind-30777 authorization ---
//
// v2 splits the v1 self-contained string into (a) a short bearer SECRET the humans paste
// (`ut2_` + 43 alnum chars ≈ 256-bit entropy, 47 chars total) and (b) an issuer-signed
// kind-30777 event PUBLISHED to the relay, addressed by `d` = SHA-256(secret). The event
// content is AES-256-GCM-encrypted under a key HKDF-derived FROM THE SECRET, so the public
// relay learns only the issuer pubkey + the hash — never caps/label/bind (metadata parity
// with v1, where the payload only ever travelled out-of-band / NIP-17-encrypted).
//
// Commitment chain the redeemer verifies: d-tag == SHA-256(secret) (signed under NIP-01),
// GCM auth (only the right secret decrypts; AAD binds kind+d), payload.sh == d, and
// payload.iss == event.pubkey (a copied ciphertext re-signed by another key fails here).
// All secret-bearing input arrives on STDIN (readSecretInput), never argv.

import { createHash, hkdfSync, randomBytes, createCipheriv, createDecipheriv } from 'node:crypto';

const TICKET2_KIND = 30777;
const ticket2Hash = (secret) => createHash('sha256').update(secret, 'utf8').digest('hex');
const ticket2Key = (secret) =>
  Buffer.from(hkdfSync('sha256', Buffer.from(secret, 'utf8'), Buffer.from('unicity-ticket-v2', 'utf8'), Buffer.from('content-enc', 'utf8'), 32));
const ticket2Aad = (d) => Buffer.from(`ut2|${TICKET2_KIND}|${d}`, 'utf8');

function ticket2Encrypt(secret, d, payloadJson) {
  const nonce = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', ticket2Key(secret), nonce);
  c.setAAD(ticket2Aad(d));
  const ct = Buffer.concat([c.update(payloadJson, 'utf8'), c.final()]);
  return Buffer.concat([nonce, ct, c.getAuthTag()]).toString('base64url');
}

function ticket2Decrypt(secret, d, contentB64) {
  const buf = Buffer.from(contentB64, 'base64url');
  if (buf.length < 12 + 16) throw new Error('content too short');
  const nonce = buf.subarray(0, 12);
  const tag = buf.subarray(buf.length - 16);
  const ct = buf.subarray(12, buf.length - 16);
  const dec = createDecipheriv('aes-256-gcm', ticket2Key(secret), nonce);
  dec.setAAD(ticket2Aad(d));
  dec.setAuthTag(tag);
  return Buffer.concat([dec.update(ct), dec.final()]).toString('utf8');
}

// ticket2-sign --identity <path>   (stdin: {secret, payload})
// The helper — not the caller — derives d/tid/sh from the secret, so the commitment can
// never drift from what gets signed. Prints the signed event; the SECRET is never echoed.
async function ticket2Sign(args) {
  const identityPath = args.identity;
  if (!identityPath) fail('--identity <path> is required');
  const inJson = readSecretInput(args, 'in-file');
  let secret, payload;
  try { ({ secret, payload } = JSON.parse(inJson)); } catch (e) { fail(`Invalid input JSON: ${e.message}`); }
  if (typeof secret !== 'string' || secret.length < 32) fail('ticket2-sign: missing/short secret');
  if (!payload || typeof payload !== 'object') fail('ticket2-sign: missing payload');
  const d = ticket2Hash(secret);
  payload = { ...payload, v: 2, sh: d, tid: `t${d.slice(0, 12)}` };
  delete payload.secret; // belt-and-braces: the published event must NEVER embed the secret
  const identity = readJson(identityPath);
  const nostr = await loadNostrSdk();
  const sdk = await loadSdk();
  const keyManager = await keyManagerFromIdentity(identity, nostr, sdk);
  const ev = nostr.Event.create(keyManager, {
    kind: TICKET2_KIND,
    created_at: Math.floor(Date.now() / 1000),
    tags: [['d', d], ['expiration', String(payload.exp || 0)]],
    content: ticket2Encrypt(secret, d, JSON.stringify(payload)),
  });
  process.stdout.write(JSON.stringify(ev.toJSON()) + '\n');
}

// ticket2-verify   (stdin: {secret, events:[…]})
// Filters relay candidates down to the ONE event that passes the full chain; any hostile
// clutter under the same d (copied ciphertext re-signed, wrong kind, garbage) is rejected
// with a specific reason. Exit 1 + {valid:false} when nothing passes (fail closed).
async function ticket2Verify(args) {
  const inJson = readSecretInput(args, 'in-file');
  let secret, events;
  try { ({ secret, events } = JSON.parse(inJson)); } catch (e) { output({ valid: false, reason: 'bad-json' }); process.exit(1); }
  if (typeof secret !== 'string' || !Array.isArray(events)) { output({ valid: false, reason: 'bad-input' }); process.exit(1); }
  const d = ticket2Hash(secret);
  const nostr = await loadNostrSdk();
  let reason = events.length === 0 ? 'no-event' : 'no-valid-event';
  for (const obj of events) {
    let ev;
    try { ev = nostr.Event.fromJSON(obj); } catch { reason = 'bad-event-json'; continue; }
    if (Number(ev.kind) !== TICKET2_KIND) { reason = 'wrong-kind'; continue; }
    const tags = Array.isArray(obj.tags) ? obj.tags : [];
    const dt = tags.find((t) => Array.isArray(t) && t[0] === 'd');
    if (!dt || dt[1] !== d) { reason = 'd-mismatch'; continue; }
    let ok = false;
    try { ok = ev.verify(); } catch { ok = false; }
    if (!ok) { reason = 'bad-signature'; continue; }
    let payload;
    try { payload = JSON.parse(ticket2Decrypt(secret, d, ev.content)); } catch { reason = 'decrypt-failed'; continue; }
    if (Number(payload.v) !== 2) { reason = 'bad-version'; continue; }
    if (payload.sh !== d || payload.tid !== `t${d.slice(0, 12)}`) { reason = 'hash-commitment-mismatch'; continue; }
    let issHex;
    try { issHex = npubToHex(String(payload.iss || ''), nostr).toLowerCase(); } catch { reason = 'bad-iss'; continue; }
    if (!/^[0-9a-f]{64}$/.test(issHex) || ev.pubkey.toLowerCase() !== issHex) { reason = 'iss-mismatch'; continue; }
    output({ valid: true, pubkey: ev.pubkey.toLowerCase(), npub: payload.iss, eventId: obj.id || null, payload });
    return;
  }
  output({ valid: false, reason });
  process.exit(1);
}

// --- npub rotation attestation (chain-of-trust) -----------------------------------------
// A leaked/harvested npub is a durable target: it is where our coordination traffic is
// addressed and what an allow-list keys on. Rotation replaces it — but a rotation announcement
// is only trustworthy if it is authorized by the key being retired, otherwise anyone could
// "rotate" our identity to a key they control. So the OLD key SIGNS an attestation binding
// old_npub → new_npub; only the holder of the old key (not someone who merely harvested the
// public npub) can produce it. Peers/owner verify that chain and re-point to the new npub.
//
// The attestation is a NIP-01 parameterized-replaceable event: kind 30078, d="npub-rotation"
// (one latest-wins slot per identity), L="unicity:npub-rotation", p=<new pubkey hex>. content is
// PLAINTEXT JSON {v,type,old_npub,new_npub,ts,reason} — nothing here is secret (both npubs are
// public identifiers); the security is the signature, not confidentiality.

const ROTATION_KIND = 30078;
const ROTATION_D = 'npub-rotation';
const ROTATION_L = 'unicity:npub-rotation';

// rotate-sign --identity <oldIdentity> --new-npub <npub> [--reason <r>] [--exp <unixSecs>]
// Signs with the OLD identity; embeds the derived old_npub so verifiers need only the event.
async function rotateSign(args) {
  const identityPath = args.identity;
  if (!identityPath) fail('--identity <path> (the OLD identity) is required');
  const newNpub = args['new-npub'];
  if (!newNpub || !String(newNpub).startsWith('npub1')) fail('--new-npub <npub> is required (bech32 npub of the NEW identity)');
  const nostr = await loadNostrSdk();
  const sdk = await loadSdk();
  const keyManager = await keyManagerFromIdentity(readJson(identityPath), nostr, sdk);
  const oldHex = keyManager.getPublicKeyHex().toLowerCase();
  const oldNpub = keyManager.getNpub();
  let newHex;
  try { newHex = npubToHex(String(newNpub), nostr).toLowerCase(); } catch (e) { fail(`--new-npub is not a decodable npub: ${e.message}`); }
  if (!/^[0-9a-f]{64}$/.test(newHex)) fail('--new-npub did not decode to a valid pubkey');
  if (newHex === oldHex) fail('refusing to rotate: --new-npub equals the current identity');
  const exp = parseInt(args.exp || '0', 10) || 0;
  const payload = {
    v: 1, type: 'npub-rotation',
    old_npub: oldNpub, new_npub: String(newNpub), ts: Math.floor(Date.now() / 1000),
    reason: typeof args.reason === 'string' ? args.reason : '',
  };
  const ev = nostr.Event.create(keyManager, {
    kind: ROTATION_KIND,
    created_at: Math.floor(Date.now() / 1000),
    tags: [['d', ROTATION_D], ['L', ROTATION_L], ['p', newHex], ['expiration', String(exp)]],
    content: JSON.stringify(payload),
  });
  process.stdout.write(JSON.stringify(ev.toJSON()) + '\n');
}

// rotate-verify   (stdin: attestation event JSON) → {valid, old_npub, old_hex, new_npub, new_hex, ts, reason}
// The verifier gate that makes rotation safe: the event's SIGNING key (ev.pubkey) MUST equal the
// old_npub the payload claims to retire, so a rotation can only be authorized by the key it
// replaces — never by a bystander who merely knows the public old npub. Fails closed.
async function rotateVerify(args) {
  const evJson = readSecretInput(args, 'in-file');
  if (!evJson) fail('Usage: rotate-verify (attestation event JSON via --in-file or stdin)');
  const nostr = await loadNostrSdk();
  let ev, obj;
  try { obj = typeof evJson === 'string' ? JSON.parse(evJson) : evJson; ev = nostr.Event.fromJSON(obj); }
  catch { output({ valid: false, reason: 'bad-json' }); process.exit(1); }
  if (Number(ev.kind) !== ROTATION_KIND) { output({ valid: false, reason: 'wrong-kind' }); process.exit(1); }
  const tags = Array.isArray(obj.tags) ? obj.tags : [];
  const dt = tags.find((t) => Array.isArray(t) && t[0] === 'd');
  const lt = tags.find((t) => Array.isArray(t) && t[0] === 'L');
  if (!dt || dt[1] !== ROTATION_D) { output({ valid: false, reason: 'not-a-rotation' }); process.exit(1); }
  if (!lt || lt[1] !== ROTATION_L) { output({ valid: false, reason: 'missing-rotation-marker' }); process.exit(1); }
  let ok = false;
  try { ok = ev.verify(); } catch { ok = false; }
  if (!ok) { output({ valid: false, reason: 'bad-signature' }); process.exit(1); }
  let payload;
  try { payload = JSON.parse(ev.content); } catch { output({ valid: false, reason: 'bad-content' }); process.exit(1); }
  if (payload.type !== 'npub-rotation' || Number(payload.v) !== 1) { output({ valid: false, reason: 'bad-payload' }); process.exit(1); }
  let oldHex, newHex;
  try { oldHex = npubToHex(String(payload.old_npub || ''), nostr).toLowerCase(); } catch { output({ valid: false, reason: 'bad-old-npub' }); process.exit(1); }
  try { newHex = npubToHex(String(payload.new_npub || ''), nostr).toLowerCase(); } catch { output({ valid: false, reason: 'bad-new-npub' }); process.exit(1); }
  // The core anti-forgery check: the retiring key signed this.
  if (!/^[0-9a-f]{64}$/.test(oldHex) || ev.pubkey.toLowerCase() !== oldHex) { output({ valid: false, reason: 'old-npub-mismatch' }); process.exit(1); }
  if (!/^[0-9a-f]{64}$/.test(newHex) || newHex === oldHex) { output({ valid: false, reason: 'bad-new-hex' }); process.exit(1); }
  // The p-tag must corroborate the payload's new key (defense-in-depth, so a mismatched tag can't confuse a consumer that reads the tag).
  const pt = tags.find((t) => Array.isArray(t) && t[0] === 'p');
  if (!pt || String(pt[1]).toLowerCase() !== newHex) { output({ valid: false, reason: 'p-tag-mismatch' }); process.exit(1); }
  output({ valid: true, old_npub: payload.old_npub, old_hex: oldHex, new_npub: payload.new_npub, new_hex: newHex, ts: payload.ts || 0, reason: payload.reason || '' });
}

// relay-publish --relay <url>   (stdin: event JSON) → {published:true,id}
// Waits for the relay's ["OK", id, true] — a ticket whose event never landed must fail the
// ISSUE loudly, not surface as a mystery at redeem time. TICKET_RELAY_STUB=<dir> replaces
// the socket with a file drop for hermetic tests (same JSON in/out contract).
async function relayPublish(args) {
  const evJson = readSecretInput(args, 'in-file');
  let ev;
  try { ev = JSON.parse(evJson); } catch (e) { fail(`relay-publish: invalid event JSON: ${e.message}`); }
  if (!ev || !ev.id) fail('relay-publish: event has no id');
  const stub = process.env.TICKET_RELAY_STUB;
  if (stub) {
    const { writeFileSync, mkdirSync } = await import('node:fs');
    mkdirSync(stub, { recursive: true });
    writeFileSync(`${stub}/${ev.id}.json`, JSON.stringify(ev));
    output({ published: true, id: ev.id, stub: true });
    return;
  }
  const relay = args.relay || 'wss://nostr-relay.testnet.unicity.network';
  const timeoutMs = parseInt(args.timeout || '8000', 10);
  // NIP-42: publish is an EVENT the relay may reject with `auth-required` until we AUTH. When an
  // --identity is given we sign the challenge with it, then re-send the EVENT once AUTH is ACKed.
  let authSigner = null;
  if (args.identity) {
    try {
      const nostr = await loadNostrSdk();
      const sdk = await loadSdk();
      const km = await keyManagerFromIdentity(readJson(args.identity), nostr, sdk);
      authSigner = makeAuthSigner(nostr, km);
    } catch { authSigner = null; }
  }
  const result = await new Promise((resolvePromise) => {
    let ws;
    let settled = false;
    const done = (r) => { if (settled) return; settled = true; try { ws && ws.close(); } catch {} resolvePromise(r); };
    const timer = setTimeout(() => done({ ok: false, reason: `timeout (no OK from ${relay} in ${timeoutMs}ms)` }), timeoutMs);
    try { ws = new WebSocket(relay); } catch (e) { clearTimeout(timer); done({ ok: false, reason: e.message }); return; }
    const sendEvent = () => { try { ws.send(JSON.stringify(['EVENT', ev])); } catch (e) { clearTimeout(timer); done({ ok: false, reason: e.message }); } };
    const nip42 = nip42Machine(() => ws, relay, authSigner, () => sendEvent()); // re-publish after AUTH
    ws.onopen = () => { sendEvent(); };
    ws.onmessage = (e) => {
      let a;
      try { a = JSON.parse(typeof e.data === 'string' ? e.data : e.data.toString()); } catch { return; }
      if (nip42.handle(a)) return;
      if (a[0] === 'OK' && a[1] === ev.id) {
        if (a[2] === true) { clearTimeout(timer); done({ ok: true, reason: a[3] || '' }); return; }
        // A pre-auth reject: wait for the AUTH challenge + re-publish (nip42 onAuthed) instead of
        // failing. Any other rejection is terminal.
        if (isAuthRequired(a[3]) && nip42.canAuth() && !nip42.isAuthed()) return;
        clearTimeout(timer); done({ ok: false, reason: a[3] || '' });
      }
    };
    ws.onerror = () => done({ ok: false, reason: `websocket error (${relay})` });
    ws.onclose = () => done({ ok: false, reason: `connection closed before OK (${relay})` });
  });
  if (!result.ok) fail(`relay-publish REJECTED/FAILED: ${result.reason || 'relay refused the event'}`);
  output({ published: true, id: ev.id, relay });
}

// relay-fetch --relay <url> --dtag <hex>  → {events:[…]}
// The dtag is SHA-256(secret) — public by construction once the event is on the relay, so
// argv is fine here. Reuses fetchEventsRaw (raw NIP-01 REQ; see its note on SDK subscribe).
async function relayFetch(args) {
  const dtag = args.dtag;
  if (!dtag || !/^[0-9a-f]{64}$/i.test(dtag)) fail('relay-fetch: --dtag <64-hex> required');
  const stub = process.env.TICKET_RELAY_STUB;
  if (stub) {
    const { readdirSync } = await import('node:fs');
    const events = [];
    let names = [];
    try { names = readdirSync(stub); } catch {}
    for (const n of names) {
      if (!n.endsWith('.json')) continue;
      try {
        const ev = JSON.parse(readFileSync(`${stub}/${n}`, 'utf-8'));
        const tags = Array.isArray(ev.tags) ? ev.tags : [];
        if (Number(ev.kind) === TICKET2_KIND && tags.some((t) => Array.isArray(t) && t[0] === 'd' && t[1] === dtag.toLowerCase())) events.push(ev);
      } catch {}
    }
    output({ events, stub: true });
    return;
  }
  const relay = args.relay || 'wss://nostr-relay.testnet.unicity.network';
  // NIP-42: sign AUTH with --identity when given, so ticket fetch survives an auth-enforcing relay.
  let authSigner = null;
  if (args.identity) {
    try {
      const nostr = await loadNostrSdk();
      const sdk = await loadSdk();
      const km = await keyManagerFromIdentity(readJson(args.identity), nostr, sdk);
      authSigner = makeAuthSigner(nostr, km);
    } catch { authSigner = null; }
  }
  const events = await fetchEventsRaw(relay, [{ kinds: [TICKET2_KIND], '#d': [dtag.toLowerCase()] }], 6000, authSigner);
  output({ events, relay });
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
  case 'ticket2-sign':
    await ticket2Sign(args);
    break;
  case 'ticket2-verify':
    await ticket2Verify(args);
    break;
  case 'rotate-sign':
    await rotateSign(args);
    break;
  case 'rotate-verify':
    await rotateVerify(args);
    break;
  case 'relay-publish':
    await relayPublish(args);
    break;
  case 'relay-fetch':
    await relayFetch(args);
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
  send-dm <npub> --body-file <p>|stdin --identity <path>  Send encrypted DM (body via file/stdin)
  ticket-sign --identity <p> --in-file <p>|stdin          Sign a kind-30777 ticket (payload via file/stdin)
  ticket-verify --in-file <p>|stdin                       Verify a ticket event (via file/stdin)
  ticket2-sign --identity <p>  (stdin: {secret,payload})  Sign a v2 short-ticket event (encrypted content)
  ticket2-verify               (stdin: {secret,events})   Verify v2 relay candidates → payload
  rotate-sign --identity <old> --new-npub <npub> [--reason <r>]  Old key signs an npub-rotation attestation → new npub
  rotate-verify --in-file <p>|stdin                       Verify a rotation attestation (old key authorized new npub)
  relay-publish --relay <url> [--identity <p>]  (stdin: event JSON)  Publish an event, wait for relay OK (--identity ⇒ NIP-42 AUTH)
  relay-fetch --relay <url> --dtag <hex> [--identity <p>]  Fetch kind-30777 events by #d (--identity ⇒ NIP-42 AUTH)
  check-messages --identity <p> --config <p>  Poll for new messages (one-shot)
  watch --identity <p> --config <p>        Stream new messages as NDJSON (live, reconnecting)
  npub-to-hex <npub>                       Decode an npub to its 32-byte pubkey hex`);
}
