#!/usr/bin/env node
// sphere-helper.mjs — CLI helper wrapping @unicitylabs/sphere-sdk for agent operations.
//
// Requires: @unicitylabs/sphere-sdk
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

// --- Subcommands ---

async function createIdentity() {
  const sdk = await loadSdk();

  try {
    const mnemonic = sdk.generateMnemonic();
    const master = sdk.identityFromMnemonicSync(mnemonic);
    const derivationPath = sdk.DEFAULT_DERIVATION_PATH;
    const child = sdk.deriveKeyAtPath(master.privateKey, master.chainCode, derivationPath);
    const publicKey = sdk.getPublicKey(child.privateKey);

    // Nostr npub uses 32-byte x-only pubkey (strip 02/03 prefix from compressed key)
    const pubkeyBytes = Buffer.from(publicKey, 'hex').slice(1);
    const privkeyBytes = Buffer.from(child.privateKey, 'hex');

    const npub = sdk.encodeBech32('npub', 0, pubkeyBytes);
    const nsec = sdk.encodeBech32('nsec', 0, privkeyBytes);

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
  const relay = args.relay || 'wss://relay.testnet.unicity.network';

  const { Sphere } = await loadSdk();

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
  const { Sphere } = await loadSdk();

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

  const { Sphere } = await loadSdk();

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
