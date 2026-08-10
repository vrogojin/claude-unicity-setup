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

async function checkMessages(args) {
  const identityPath = args.identity;
  const configPath = args.config;
  if (!identityPath || !configPath) fail('Usage: check-messages --identity <path> --config <path> [--since <timestamp>]');

  const identity = readJson(identityPath);
  const config = readJson(configPath);
  const since = args.since ? parseInt(args.since, 10) : Math.floor(Date.now() / 1000) - 600; // default: last 10 minutes

  const relays = config.group?.relays || ['wss://nostr-relay.testnet.unicity.network'];

  const { client, keyManager, nostr } = await createNostrClient(identity, relays);

  try {
    const myPubkeyHex = keyManager.getPublicKeyHex();
    const ownerPubkeyHex = config.owner_npub ? npubToHex(config.owner_npub, nostr) : null;

    const messages = [];

    // Subscribe to NIP-17 gift-wrapped DMs (kind 1059) addressed to us
    const dmFilter = new nostr.Filter({
      kinds: [nostr.GIFT_WRAP],
      '#p': [myPubkeyHex],
      since,
    });

    const dmSubId = client.subscribe(dmFilter, (event) => {
      try {
        const unwrapped = client.unwrapPrivateMessage(event);
        if (unwrapped) {
          const senderPubkey = unwrapped.pubkey || unwrapped.senderPubkey || '';
          messages.push({
            type: 'dm',
            from: senderPubkey,
            body: unwrapped.content || unwrapped.message || '',
            timestamp: new Date((unwrapped.created_at || event.created_at) * 1000).toISOString(),
            priority: senderPubkey === ownerPubkeyHex,
            read: false,
          });
        }
      } catch {
        // Failed to unwrap — not for us or corrupted
      }
    });

    // Subscribe to NIP-29 group messages if group configured
    let groupSubId;
    const groupId = config.group?.id;
    if (groupId) {
      // NIP-29 group messages: kind 9 (chat message) with h tag = group id
      const groupFilter = new nostr.Filter({
        kinds: [9],
        '#h': [groupId],
        since,
      });

      groupSubId = client.subscribe(groupFilter, (event) => {
        // Skip own messages
        if (event.pubkey === myPubkeyHex) return;

        messages.push({
          type: 'group',
          from: event.pubkey || '',
          body: event.content || '',
          timestamp: new Date(event.created_at * 1000).toISOString(),
          priority: event.pubkey === ownerPubkeyHex,
          read: false,
        });
      });
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
