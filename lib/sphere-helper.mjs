#!/usr/bin/env node
// sphere-helper.mjs — CLI helper wrapping @unicitylabs/sphere-sdk for agent operations.
//
// Requires: @unicitylabs/sphere-sdk (which includes @unicitylabs/nostr-js-sdk)
//
// Subcommands:
//   create-identity                          Generate BIP-39 mnemonic + secp256k1 keypair
//   resolve-nametag <nametag>                Resolve nametag → npub via Nostr relays
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

async function resolveNametag(nametag) {
  if (!nametag) fail('Usage: resolve-nametag <nametag>');

  const sdk = await loadSdk();

  // Validate and normalize the nametag
  const normalized = sdk.normalizeNametag(nametag);
  if (!sdk.isValidNametag(normalized)) {
    fail(`Invalid nametag: '${nametag}'. Must be 3-20 chars, lowercase alphanumeric, hyphens, underscores.`);
  }

  // Hash for lookup
  const hash = sdk.hashNametag(normalized);

  output({ nametag: normalized, hash, npub: null });
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

// --- Main dispatch ---

const args = parseArgs(process.argv.slice(2));
const command = args._.shift();

switch (command) {
  case 'create-identity':
    await createIdentity();
    break;
  case 'resolve-nametag':
    await resolveNametag(args._[0]);
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
  default:
    fail(`Unknown command: ${command || '(none)'}
Usage: sphere-helper.mjs <command> [options]

Commands:
  create-identity                          Generate BIP-39 mnemonic + keypair
  resolve-nametag <nametag>                Resolve nametag to npub
  join-group <name> --identity <path>      Join/create NIP-29 group
  send-dm <npub> <msg> --identity <path>   Send encrypted DM
  check-messages --identity <p> --config <p>  Poll for new messages`);
}
