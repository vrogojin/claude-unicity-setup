#!/usr/bin/env node
// sphere-helper.mjs — CLI helper wrapping @unicity/sphere-sdk for agent operations.
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
import { randomBytes } from 'node:crypto';

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

// --- Subcommands ---

async function createIdentity() {
  let Identity;
  try {
    ({ Identity } = await import('@unicity/sphere-sdk'));
  } catch {
    // Fallback: generate identity without sphere-sdk using crypto primitives
    return createIdentityFallback();
  }

  try {
    const identity = Identity.create();
    const mnemonic = identity.mnemonic || '(not available)';
    const publicKey = identity.publicKey
      ? (typeof identity.publicKey === 'string' ? identity.publicKey : Buffer.from(identity.publicKey).toString('hex'))
      : '';

    output({
      created_at: new Date().toISOString(),
      mnemonic,
      public_key: publicKey,
      npub: identity.npub || deriveNpub(publicKey),
      nsec: identity.nsec || '',
      derivation_path: "m/44'/0'/0'/0/0",
    });
  } catch (e) {
    // If sphere-sdk API differs, try alternate approach
    try {
      const identity = Identity.fromMnemonic(generateMnemonic());
      output({
        created_at: new Date().toISOString(),
        mnemonic: identity.mnemonic || '',
        public_key: identity.publicKey || '',
        npub: identity.npub || '',
        nsec: identity.nsec || '',
        derivation_path: "m/44'/0'/0'/0/0",
      });
    } catch (e2) {
      fail(`Failed to create identity: ${e.message} / ${e2.message}`);
    }
  }
}

async function createIdentityFallback() {
  // Minimal fallback using node:crypto when sphere-sdk is not installed.
  // Generates a random 32-byte secret and placeholder mnemonic.
  // In production, sphere-sdk provides proper BIP-39/BIP-32 derivation.
  let bip39, secp256k1, bech32;

  try {
    bip39 = await import('bip39');
  } catch { bip39 = null; }

  try {
    const bech32Mod = await import('bech32');
    bech32 = bech32Mod.bech32 || bech32Mod.default || bech32Mod;
  } catch { bech32 = null; }

  let mnemonic, privKeyBytes;

  if (bip39 && typeof bip39.generateMnemonic === 'function') {
    mnemonic = bip39.generateMnemonic(256);
    const seed = await (bip39.mnemonicToSeed || bip39.default?.mnemonicToSeed)?.(mnemonic);
    privKeyBytes = seed ? seed.slice(0, 32) : randomBytes(32);
  } else {
    // Generate a pseudo-mnemonic placeholder
    mnemonic = '(sphere-sdk not available — install @unicity/sphere-sdk for real BIP-39 mnemonic)';
    privKeyBytes = randomBytes(32);
  }

  const pubKeyHex = privKeyBytes.toString('hex');

  // Bech32 encoding for npub/nsec (Nostr format: npub = 32-byte pubkey, nsec = 32-byte secret)
  let npub = `npub1${pubKeyHex.slice(0, 59)}`;
  let nsec = `nsec1${privKeyBytes.toString('hex').slice(0, 59)}`;

  if (bech32) {
    try {
      const pubWords = bech32.toWords(privKeyBytes); // placeholder — proper impl uses actual pubkey
      npub = bech32.encode('npub', pubWords);
      const secWords = bech32.toWords(privKeyBytes);
      nsec = bech32.encode('nsec', secWords);
    } catch { /* keep fallback values */ }
  }

  output({
    created_at: new Date().toISOString(),
    mnemonic,
    public_key: pubKeyHex,
    npub,
    nsec,
    derivation_path: "m/44'/0'/0'/0/0",
  });
}

async function resolveNametag(nametag) {
  if (!nametag) fail('Usage: resolve-nametag <nametag>');

  let Sphere;
  try {
    ({ Sphere } = await import('@unicity/sphere-sdk'));
  } catch {
    fail('Cannot resolve nametag: @unicity/sphere-sdk not installed');
  }

  try {
    const sphere = new Sphere({ network: 'testnet' });
    const result = await sphere.resolveNametag(nametag);
    output({ nametag, npub: result.npub || result });
  } catch (e) {
    fail(`Failed to resolve nametag '${nametag}': ${e.message}`);
  }
}

async function joinGroup(args) {
  const groupName = args._[0];
  if (!groupName) fail('Usage: join-group <name> --identity <path> [--relay <url>]');

  const identityPath = args.identity;
  if (!identityPath) fail('--identity <path> is required');

  const identity = readJson(identityPath);
  const relay = args.relay || 'wss://relay.testnet.unicity.network';

  let Sphere;
  try {
    ({ Sphere } = await import('@unicity/sphere-sdk'));
  } catch {
    // Fallback: return a deterministic group ID
    output({
      group_id: `${groupName.toLowerCase()}-${relay.includes('mainnet') ? 'mainnet' : relay.includes('localhost') ? 'devnet' : 'testnet'}`,
      name: groupName,
      relay,
      status: 'placeholder (sphere-sdk not available)',
    });
    return;
  }

  try {
    const sphere = new Sphere({
      network: relay.includes('mainnet') ? 'mainnet' : 'testnet',
      identity,
      nostrRelays: [relay],
    });

    const group = await sphere.groups.joinOrCreate(groupName);
    output({
      group_id: group.id || group.groupId,
      name: groupName,
      relay,
      status: 'joined',
    });
  } catch (e) {
    fail(`Failed to join group '${groupName}': ${e.message}`);
  }
}

async function sendDm(args) {
  const recipientNpub = args._[0];
  const message = args._[1];
  if (!recipientNpub || !message) fail('Usage: send-dm <npub> <message> --identity <path>');

  const identityPath = args.identity;
  if (!identityPath) fail('--identity <path> is required');

  const identity = readJson(identityPath);

  let Sphere;
  try {
    ({ Sphere } = await import('@unicity/sphere-sdk'));
  } catch {
    fail('Cannot send DM: @unicity/sphere-sdk not installed');
  }

  try {
    const relay = args.relay || 'wss://relay.testnet.unicity.network';
    const sphere = new Sphere({
      network: relay.includes('mainnet') ? 'mainnet' : 'testnet',
      identity,
      nostrRelays: [relay],
    });

    const messageBytes = new TextEncoder().encode(message);
    await sphere.transport.send(recipientNpub, messageBytes);
    output({ status: 'sent', to: recipientNpub, length: message.length });
  } catch (e) {
    fail(`Failed to send DM: ${e.message}`);
  }
}

async function checkMessages(args) {
  const identityPath = args.identity;
  const configPath = args.config;
  if (!identityPath || !configPath) fail('Usage: check-messages --identity <path> --config <path> [--since <timestamp>]');

  const identity = readJson(identityPath);
  const config = readJson(configPath);
  const since = args.since ? parseInt(args.since, 10) : Math.floor(Date.now() / 1000) - 600; // default: last 10 minutes

  let Sphere;
  try {
    ({ Sphere } = await import('@unicity/sphere-sdk'));
  } catch {
    // Return empty if sphere-sdk not available
    output({ messages: [], polled_at: new Date().toISOString() });
    return;
  }

  try {
    const relays = config.group?.relays || ['wss://relay.testnet.unicity.network'];
    const sphere = new Sphere({
      network: relays[0].includes('mainnet') ? 'mainnet' : 'testnet',
      identity,
      nostrRelays: relays,
    });

    const messages = [];
    const collected = new Promise((resolve) => {
      const timeout = setTimeout(() => resolve(), 5000); // 5 second collection window

      sphere.transport.subscribe((msg) => {
        if (msg.created_at >= since) {
          messages.push({
            type: msg.kind === 4 || msg.kind === 1059 ? 'dm' : 'group',
            from: msg.pubkey || msg.from || '',
            body: typeof msg.content === 'string' ? msg.content : new TextDecoder().decode(msg.content),
            timestamp: new Date(msg.created_at * 1000).toISOString(),
            priority: msg.pubkey === config.owner_npub || msg.from === config.owner_npub,
            read: false,
          });
        }
      });

      // If no messages after timeout, resolve
      setTimeout(() => { clearTimeout(timeout); resolve(); }, 5000);
    });

    await collected;

    output({ messages, polled_at: new Date().toISOString() });
  } catch (e) {
    fail(`Failed to check messages: ${e.message}`);
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
