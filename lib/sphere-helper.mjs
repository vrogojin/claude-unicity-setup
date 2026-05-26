#!/usr/bin/env node
// sphere-helper.mjs — CLI helper wrapping @unicitylabs/sphere-sdk for agent operations.
//
// Requires: @unicitylabs/sphere-sdk (which includes @unicitylabs/nostr-js-sdk)
//
// Subcommands:
//   create-identity                          Generate BIP-39 mnemonic + secp256k1 keypair
//   migrate-identity <identity.json> [--write] [--no-backup]
//                                            Re-derive NIP-19 npub/nsec for an existing
//                                            identity file (fixes legacy L1-bech32 encoding).
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

// Derive the 32-byte Nostr private key for an identity. Prefers mnemonic
// (canonical), falls back to private_key hex, then nsec. The nsec/npub fields
// in existing identity.json files were historically encoded with sphere-sdk's
// L1-style bech32 (witness version 0 prefix), so they decode to 33 bytes and
// are rejected by nostr-js-sdk. Reconstructing from mnemonic or private_key
// bypasses that legacy encoding.
async function deriveNostrPrivateKey(identity) {
  const sdk = await loadSdk();

  if (identity.mnemonic) {
    const master = sdk.identityFromMnemonicSync(identity.mnemonic);
    const derivationPath = identity.derivation_path || sdk.DEFAULT_DERIVATION_PATH;
    const child = sdk.deriveKeyAtPath(master.privateKey, master.chainCode, derivationPath);
    return child.privateKey;
  }
  if (identity.private_key) {
    return identity.private_key;
  }
  if (identity.nsec) {
    // Last resort: try standard NIP-19 nsec first; if that fails, attempt
    // legacy L1-style decode (witness version 0 + 32-byte key).
    const nostr = await loadNostrSdk();
    try {
      const bytes = nostr.decodeNsec(identity.nsec);
      return Buffer.from(bytes).toString('hex');
    } catch {
      const legacy = sdk.decodeBech32(identity.nsec);
      if (legacy && legacy.hrp === 'nsec' && legacy.data?.length === 32) {
        return Buffer.from(legacy.data).toString('hex');
      }
      fail('Could not decode legacy nsec; please regenerate the identity (migrate-identity).');
    }
  }
  fail('Identity must contain mnemonic, private_key, or nsec');
}

// Build a NostrClient from an identity.json file. Always derives a fresh
// 32-byte private key (see deriveNostrPrivateKey) before constructing the
// key manager so legacy 33-byte-encoded fields don't break startup.
async function createNostrClient(identity, relayUrls) {
  const nostr = await loadNostrSdk();
  const privateKeyHex = await deriveNostrPrivateKey(identity);
  const keyManager = nostr.NostrKeyManager.fromPrivateKeyHex(privateKeyHex);

  const client = new nostr.NostrClient(keyManager);
  await client.connect(...relayUrls);
  return { client, keyManager, nostr };
}

// Decode npub to 32-byte hex x-only pubkey. Handles three input formats:
//   1. 64-hex string (already x-only)               -> returned as-is (lowercased)
//   2. 66-hex string starting with 02/03 (compressed) -> parity prefix stripped
//   3. npub1... standard NIP-19 (32 bytes)          -> decoded via nostr-js-sdk
//   4. npub1... legacy L1-style bech32 (33 bytes,
//      witness version 0 prefix; produced by older
//      sphere-helper create-identity)               -> decoded via sphere-sdk,
//                                                      then the leading version
//                                                      byte is dropped.
function npubToHex(npubOrHex, nostrSdk, sphereSdk) {
  if (typeof npubOrHex !== 'string') {
    fail(`Invalid npub/pubkey input: expected string, got ${typeof npubOrHex}`);
  }

  // Hex form
  if (/^[0-9a-fA-F]+$/.test(npubOrHex)) {
    const lower = npubOrHex.toLowerCase();
    if (lower.length === 64) return lower;
    if (lower.length === 66 && (lower.startsWith('02') || lower.startsWith('03'))) {
      return lower.slice(2);
    }
    fail(`Invalid hex pubkey: must be 64 chars (x-only) or 66 chars with 02/03 prefix; got ${lower.length}`);
  }

  if (!npubOrHex.startsWith('npub1')) {
    fail(`Unrecognized recipient format: '${npubOrHex.slice(0, 16)}…'. Expected hex or npub1...`);
  }

  // Try standard NIP-19 first.
  try {
    const decoded = nostrSdk.decodeNpub(npubOrHex);
    return Buffer.from(decoded).toString('hex');
  } catch (e) {
    // Fall back to legacy L1-style: sphere-sdk decodeBech32 yields 32 bytes
    // because it strips a leading witness version. But the helper's
    // create-identity (prior to 2026-05) called encodeBech32('npub', 0, key32);
    // decodeBech32 returns { data: key32 } (the version is reported separately
    // as witnessVersion). So we just check hrp + length and use the bytes.
    if (!sphereSdk) {
      fail(`Failed to decode npub: ${e.message}`);
    }
    const legacy = sphereSdk.decodeBech32(npubOrHex);
    if (legacy && legacy.hrp === 'npub' && legacy.data?.length === 32) {
      return Buffer.from(legacy.data).toString('hex');
    }
    fail(`Failed to decode npub: ${e.message}`);
  }
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

    // Nostr npub/nsec are standard NIP-19 bech32 over 32-byte x-only pubkey /
    // 32-byte private key. Use nostr-js-sdk's encoders — NOT sphere-sdk's
    // encodeBech32, which inserts an L1 witness version byte and produces
    // 33-byte-decoding strings rejected by every standard Nostr consumer.
    const pubkeyBytes = Buffer.from(publicKey, 'hex').slice(1); // strip 02/03 parity prefix
    const privkeyBytes = Buffer.from(child.privateKey, 'hex');

    const npub = nostr.encodeNpub(pubkeyBytes);
    const nsec = nostr.encodeNsec(privkeyBytes);

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

// Re-derive the canonical NIP-19 npub/nsec for an existing identity file.
// The mnemonic and public_key fields are authoritative — only npub/nsec
// may have been written with the legacy L1-encoder. Backs up the original
// file to identity.json.bak before overwriting. Idempotent: if the npub/nsec
// already decode to 32 bytes, no changes are made.
async function migrateIdentity(args) {
  const identityPath = args._[0] || args.identity;
  if (!identityPath) {
    fail('Usage: migrate-identity <identity.json>  [--write] [--no-backup]');
  }
  const dryRun = !args.write;
  const writeBackup = args['no-backup'] !== true;

  const sdk = await loadSdk();
  const nostr = await loadNostrSdk();
  const identity = readJson(identityPath);

  // Verify what's there
  let currentNpubBytes = null;
  let currentNsecBytes = null;
  try { currentNpubBytes = nostr.decodeNpub(identity.npub).length; } catch {}
  try { currentNsecBytes = nostr.decodeNsec(identity.nsec).length; } catch {}

  if (currentNpubBytes === 32 && currentNsecBytes === 32) {
    output({ status: 'ok', path: identityPath, message: 'npub/nsec already standards-compliant; no migration needed.' });
    return;
  }

  // Derive canonical key material
  let privateKeyHex;
  let publicKeyHex;
  if (identity.mnemonic) {
    const master = sdk.identityFromMnemonicSync(identity.mnemonic);
    const derivationPath = identity.derivation_path || sdk.DEFAULT_DERIVATION_PATH;
    const child = sdk.deriveKeyAtPath(master.privateKey, master.chainCode, derivationPath);
    privateKeyHex = child.privateKey;
    publicKeyHex = sdk.getPublicKey(privateKeyHex);
  } else if (identity.private_key && identity.public_key) {
    privateKeyHex = identity.private_key;
    publicKeyHex = identity.public_key;
  } else {
    fail('Identity needs at least a mnemonic, or both private_key and public_key, to migrate.');
  }

  if (identity.public_key && identity.public_key !== publicKeyHex) {
    fail(`Derived public_key (${publicKeyHex}) does not match stored public_key (${identity.public_key}). Refusing to migrate.`);
  }

  const pubkeyBytes = Buffer.from(publicKeyHex, 'hex').slice(1);
  const privkeyBytes = Buffer.from(privateKeyHex, 'hex');
  const newNpub = nostr.encodeNpub(pubkeyBytes);
  const newNsec = nostr.encodeNsec(privkeyBytes);

  const changes = {
    npub: { from: identity.npub, to: newNpub, was_bytes: currentNpubBytes ?? 'undecodable' },
    nsec: { from: identity.nsec, to: newNsec, was_bytes: currentNsecBytes ?? 'undecodable' },
  };

  if (dryRun) {
    output({ status: 'dry-run', path: identityPath, changes, hint: 'Re-run with --write to apply.' });
    return;
  }

  if (writeBackup) {
    const { writeFileSync, copyFileSync } = await import('node:fs');
    copyFileSync(identityPath, identityPath + '.bak');
  }

  const updated = { ...identity, npub: newNpub, nsec: newNsec, private_key: privateKeyHex };
  const { writeFileSync } = await import('node:fs');
  writeFileSync(identityPath, JSON.stringify(updated, null, 2) + '\n', 'utf-8');
  output({ status: 'migrated', path: identityPath, changes, backup: writeBackup ? identityPath + '.bak' : null });
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

  const sphereSdk = await loadSdk();
  const { client, nostr } = await createNostrClient(identity, [relay]);

  try {
    // Decode npub to hex pubkey (handles standard NIP-19, legacy L1-style npub,
    // and bare hex — see npubToHex for full input forms).
    const recipientHex = npubToHex(recipientNpub, nostr, sphereSdk);

    // Send NIP-17 encrypted DM via NostrClient
    await client.sendPrivateMessage(recipientHex, message);
    output({ status: 'sent', to: recipientNpub, length: message.length });
  } catch (e) {
    fail(`Failed to send DM: ${e.message}`);
  } finally {
    try { client.disconnect(); } catch {}
  }
}

async function checkMessages(args) {
  const identityPath = args.identity;
  const configPath = args.config;
  if (!identityPath || !configPath) fail('Usage: check-messages --identity <path> --config <path> [--since <timestamp>]');

  const identity = readJson(identityPath);
  const config = readJson(configPath);

  // User-facing "since": when did the caller last successfully poll. Defaults
  // to last 10 minutes. We use this for group messages (which carry truthful
  // timestamps) and for the upper bound check on DMs.
  const userSince = args.since ? parseInt(args.since, 10) : Math.floor(Date.now() / 1000) - 600;

  // Relay-side "since" for NIP-17 gift wraps. NIP-17 mandates that gift wrap
  // created_at is randomized by ±2 days for privacy, so a wrap published right
  // now may be timestamped up to 2 days in the past. To avoid missing those,
  // we widen the relay filter to `userSince - 2 days` and then post-filter by
  // the rumor's truthful timestamp (rumor.created_at, which is the actual send
  // time, exposed only after decryption).
  const giftWrapSince = userSince - 2 * 24 * 60 * 60;

  const relays = config.group?.relays || ['wss://nostr-relay.testnet.unicity.network'];

  const sphereSdk = await loadSdk();
  const { client, keyManager, nostr } = await createNostrClient(identity, relays);

  try {
    const myPubkeyHex = keyManager.getPublicKeyHex();
    const ownerPubkeyHex = config.owner_npub ? npubToHex(config.owner_npub, nostr, sphereSdk) : null;

    const messages = [];
    const seenEventIds = new Set();

    // Subscribe to NIP-17 gift-wrapped DMs (kind 1059) addressed to us.
    // NostrClient.subscribe() expects a listener with shape `{ onEvent, onEndOfStoredEvents? }`,
    // NOT a bare callback function — passing a function silently no-ops because
    // handleEventMessage() calls `listener.onEvent(event)` and swallows the error.
    const dmFilter = new nostr.Filter({
      kinds: [nostr.GIFT_WRAP],
      '#p': [myPubkeyHex],
      since: giftWrapSince,
    });

    const dmListener = {
      onEvent: (event) => {
        if (seenEventIds.has(event.id)) return;
        seenEventIds.add(event.id);
        try {
          const unwrapped = client.unwrapPrivateMessage(event);
          if (!unwrapped) return;
          // Post-filter by the rumor's truthful timestamp (set by sender, not
          // randomized). Drop messages older than the user's since boundary.
          const rumorTs = unwrapped.timestamp || unwrapped.created_at || event.created_at;
          if (typeof rumorTs === 'number' && rumorTs < userSince) return;

          const senderPubkey = unwrapped.senderPubkey || unwrapped.pubkey || '';
          messages.push({
            type: 'dm',
            from: senderPubkey,
            body: unwrapped.content || unwrapped.message || '',
            timestamp: new Date(rumorTs * 1000).toISOString(),
            priority: senderPubkey === ownerPubkeyHex,
            read: false,
          });
        } catch {
          // Not for us, malformed, or signature invalid — silently drop.
        }
      },
    };
    const dmSubId = client.subscribe(dmFilter, dmListener);

    // Subscribe to NIP-29 group messages if group configured.
    let groupSubId;
    const groupId = config.group?.id;
    if (groupId) {
      const groupFilter = new nostr.Filter({
        kinds: [9],
        '#h': [groupId],
        since: userSince,
      });

      const groupListener = {
        onEvent: (event) => {
          if (event.pubkey === myPubkeyHex) return; // skip own messages
          if (seenEventIds.has(event.id)) return;
          seenEventIds.add(event.id);
          messages.push({
            type: 'group',
            from: event.pubkey || '',
            body: event.content || '',
            timestamp: new Date(event.created_at * 1000).toISOString(),
            priority: event.pubkey === ownerPubkeyHex,
            read: false,
          });
        },
      };
      groupSubId = client.subscribe(groupFilter, groupListener);
    }

    // Wait for messages to arrive (5 second collection window)
    await new Promise(resolve => setTimeout(resolve, 5000));

    // Cleanup subscriptions
    try { client.unsubscribe(dmSubId); } catch {}
    if (groupSubId) { try { client.unsubscribe(groupSubId); } catch {} }

    output({ messages, polled_at: new Date().toISOString() });
  } catch (e) {
    fail(`Failed to check messages: ${e.message}`);
  } finally {
    try { client.disconnect(); } catch {}
  }
}

// Print canonical 32-byte x-only hex pubkey for any of the input forms
// accepted by `npubToHex` (bare hex, npub1..., legacy 33-byte npub).
// Intended for shell consumers (hooks) that need to compare pubkeys
// without re-implementing bech32 decode. Empty/missing input prints
// nothing and exits 0 — caller decides if that's an error.
async function npubToHexCommand(args) {
  const input = args._[0];
  if (!input) {
    // Empty input is intentional (e.g., unset owner_npub). Print nothing.
    process.exit(0);
  }
  const nostr = await loadNostrSdk();
  const sdk = await loadSdk();
  const hex = npubToHex(input, nostr, sdk);
  // Plain stdout (no JSON wrapper) — shell consumers want a single line.
  process.stdout.write(hex + '\n');
}

// --- Main dispatch ---

const args = parseArgs(process.argv.slice(2));
const command = args._.shift();

switch (command) {
  case 'create-identity':
    await createIdentity();
    break;
  case 'migrate-identity':
    await migrateIdentity(args);
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
  case 'npub-to-hex':
    await npubToHexCommand(args);
    break;
  default:
    fail(`Unknown command: ${command || '(none)'}
Usage: sphere-helper.mjs <command> [options]

Commands:
  create-identity                          Generate BIP-39 mnemonic + keypair
  migrate-identity <path> [--write]        Re-derive standard NIP-19 npub/nsec for an identity
  resolve-nametag <nametag>                Resolve nametag to npub
  join-group <name> --identity <path>      Join/create NIP-29 group
  send-dm <npub> <msg> --identity <path>   Send encrypted DM
  check-messages --identity <p> --config <p>  Poll for new messages
  npub-to-hex <npub-or-hex>                Print 32-byte x-only hex pubkey on stdout (one line, no JSON)`);
}
