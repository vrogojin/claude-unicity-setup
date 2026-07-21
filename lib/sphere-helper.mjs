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

import { readFileSync, existsSync, rmSync, readdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import * as authz from './authz-firewall.mjs';
import * as sif from './semantic-firewall.mjs';
import { processInbound, loadBusState, saveBusState } from './pipeline.mjs';

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

// Create a NostrClient from an identity.json file
async function createNostrClient(identity, relayUrls) {
  const nostr = await loadNostrSdk();
  const sdk = await loadSdk();

  let keyManager;
  if (identity.nsec) {
    keyManager = nostr.NostrKeyManager.fromNsec(identity.nsec);
  } else if (identity.private_key) {
    keyManager = nostr.NostrKeyManager.fromPrivateKeyHex(identity.private_key);
  } else if (identity.mnemonic) {
    // Derive private key from mnemonic
    const master = sdk.identityFromMnemonicSync(identity.mnemonic);
    const derivationPath = identity.derivation_path || sdk.DEFAULT_DERIVATION_PATH;
    const child = sdk.deriveKeyAtPath(master.privateKey, master.chainCode, derivationPath);
    keyManager = nostr.NostrKeyManager.fromPrivateKeyHex(child.privateKey);
  } else {
    fail('Identity must contain nsec, private_key, or mnemonic');
  }

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

// Encode a 32-byte x-only hex pubkey to npub. Used to convert the transport
// sender pubkey to npub EXACTLY ONCE before classification (fixes BUG-1: the
// firewall must never compare a hex sender against a bech32 owner_npub).
function hexToNpub(hex, nostrSdk) {
  try {
    return nostrSdk.encodeNpub(Buffer.from(hex, 'hex'));
  } catch {
    return hex; // leave as-is; classify() will treat an unrecognized value as pending
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

async function resolveNametag(nametag, args = {}) {
  if (!nametag) fail('Usage: resolve-nametag <nametag> [--identity <path>] [--relay <url>]');

  const sdk = await loadSdk();

  // Validate and normalize the nametag
  const normalized = sdk.normalizeNametag(nametag);
  if (!sdk.isValidNametag(normalized)) {
    fail(`Invalid nametag: '${nametag}'. Must be 3-20 chars, lowercase alphanumeric, hyphens, underscores.`);
  }

  const hash = sdk.hashNametag(normalized);

  // De-stubbed (design §8 P0): resolve via the SDK against the relay. The SDK's
  // createNametagToPubkeyFilter() hashes internally, so we pass the normalized
  // nametag. A minimal ephemeral identity is enough to open a read subscription.
  const identityPath = args.identity;
  const relay = args.relay || 'wss://nostr-relay.testnet.unicity.network';
  let identity;
  if (identityPath && existsSync(resolve(identityPath))) {
    identity = readJson(identityPath);
  } else {
    // Read-only queries still need a keypair to construct the client.
    const mnemonic = sdk.generateMnemonic();
    identity = { mnemonic };
  }

  const { client, nostr } = await createNostrClient(identity, [relay]);
  try {
    const pubkeyHex = await client.queryPubkeyByNametag(normalized);
    const npub = pubkeyHex ? hexToNpub(pubkeyHex, nostr) : null;
    // NOTE: P1 will upgrade to nostr-js-sdk 0.6.0 queryBindingByNametag() for the
    // transport-vs-wallet pubkey distinction + squat protection (design §8 P1).
    output({ nametag: normalized, hash, pubkey_hex: pubkeyHex || null, npub });
  } catch (e) {
    fail(`Failed to resolve nametag '${normalized}': ${e.message}`);
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
    // TODO(P1, design §8): de-stub real NIP-29 join via GroupChatModule
    // (createGroupChatModule → joinGroup/onMessage). OUT OF P0 SCOPE — P0 uses the
    // low-level kind-9 `#h` subscription in check-messages for open groups, and
    // (red-team F5) classifies every group sender by contacts.json regardless of
    // membership, so a fake "configured" join grants no trust. Left inert for now.
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

  // Firewall state + config lives alongside config.json in the agent dir.
  const agentDir = dirname(resolve(configPath));
  const storePath = resolve(agentDir, 'contacts.json');
  const statePath = resolve(agentDir, 'bus-state.json');
  const daemonPath = resolve(agentDir, 'daemon.json');
  const daemonCfg = existsSync(daemonPath) ? readJson(daemonPath) : {};
  const sifCfg = sif.resolveConfig(daemonCfg.semantic_firewall || {}, process.env);

  const { client, keyManager, nostr } = await createNostrClient(identity, relays);

  try {
    const myPubkeyHex = keyManager.getPublicKeyHex();

    // --- Collect raw events (dedup within the window by eventId) ---
    // CRITICAL: the SDK dispatches via listener.onEvent(), so a bare function is
    // silently dropped (its error is swallowed). Use CallbackEventListener.
    const rawMsgs = [];
    const seenInWindow = new Set();

    const dmFilter = new nostr.Filter({ kinds: [nostr.GIFT_WRAP], '#p': [myPubkeyHex], since });
    const dmListener = new nostr.CallbackEventListener((event) => {
      try {
        const u = client.unwrapPrivateMessage(event);
        if (!u) return;
        if (u.kind === 15) return; // read receipt — not a chat message
        const eid = u.eventId || event.id || '';
        if (!eid || seenInWindow.has(eid)) return;
        seenInWindow.add(eid);
        rawMsgs.push({
          type: 'dm',
          fromHex: u.senderPubkey || u.pubkey || '',
          body: u.content || '',
          eventId: eid,
          // BUG-2: use the rumor timestamp, NOT the randomized gift-wrap created_at.
          timestampSec: u.timestamp || event.created_at,
          kind: u.kind,
        });
      } catch { /* not for us / corrupted */ }
    });
    const dmSubId = client.subscribe(dmFilter, dmListener);

    let groupSubId;
    const groupId = config.group?.id;
    if (groupId) {
      const groupFilter = new nostr.Filter({ kinds: [9], '#h': [groupId], since });
      const groupListener = new nostr.CallbackEventListener((event) => {
        if (event.pubkey === myPubkeyHex) return; // skip own
        const eid = event.id || '';
        if (!eid || seenInWindow.has(eid)) return;
        seenInWindow.add(eid);
        const gid = (event.tags || []).find((t) => t[0] === 'h')?.[1] || groupId;
        rawMsgs.push({
          type: 'group',
          fromHex: event.pubkey || '',
          body: event.content || '',
          eventId: eid,
          timestampSec: event.created_at,
          kind: event.kind,
          group: { id: gid, name: config.group?.name || 'UNICITY_DEV_AGENTS' },
        });
      });
      groupSubId = client.subscribe(groupFilter, groupListener);
    }

    // Collection window
    await new Promise((r) => setTimeout(r, 5000));
    try { client.unsubscribe(dmSubId); } catch {}
    if (groupSubId) { try { client.unsubscribe(groupSubId); } catch {} }

    // --- Run every raw event through the firewall pipeline (strict order) ---
    const store = authz.loadStore(storePath);
    const state = loadBusState(statePath);
    const ctx = {
      store, storePath, state, statePath, agentDir,
      ownerNpub: config.owner_npub || null,
      npubForHex: (h) => hexToNpub(h, nostr),
      sifCfg,
      fetchImpl: fetch,
      now: Date.now(),
    };

    const messages = [], pending = [], held = [], blocked = [];
    for (const raw of rawMsgs) {
      const d = await processInbound(raw, ctx);
      if (d.outcome === 'surface') messages.push(d.surface);
      else if (d.outcome === 'quarantined_pending') pending.push(d.pending);
      else if (d.outcome === 'held') held.push(d.held);
      else if (d.outcome === 'blocked_content') blocked.push(d.blocked);
      // duplicate / blocked_sender / rate_limited / near_duplicate / pending_dropped
      // are intentionally silent (audit-only, already persisted).
    }
    // Persist once more in case no message advanced state (e.g. all duplicates).
    saveBusState(statePath, state);

    output({ messages, pending, held, blocked, polled_at: new Date().toISOString() });
  } catch (e) {
    fail(`Failed to check messages: ${e.message}`);
  } finally {
    try { client.disconnect(); } catch {}
  }
}

// --- Contact store management (backing the /approve-contact, /deny-contact skills) ---

function agentDirFrom(args) {
  if (args['agent-dir']) return resolve(args['agent-dir']);
  if (args.config) return dirname(resolve(args.config));
  fail('Provide --agent-dir <path> or --config <path> to locate contacts.json');
}

async function approveContactCmd(args) {
  const npub = args._[0];
  if (!npub) fail('Usage: approve-contact <npub> [--tier team|owner] [--nametag <tag>] [--label <text>] --agent-dir <path>');
  const agentDir = agentDirFrom(args);
  const storePath = resolve(agentDir, 'contacts.json');
  const store = authz.loadStore(storePath);
  const tier = args.tier === 'owner' ? 'owner' : 'team';
  try {
    authz.approveContact(store, npub, {
      tier,
      nametag: typeof args.nametag === 'string' ? args.nametag : undefined,
      label: typeof args.label === 'string' ? args.label : '',
    });
  } catch (e) {
    fail(e.message);
  }
  authz.saveStore(storePath, store);

  // F7: approval trusts IDENTITY, not the held backlog. Drop-and-require-resend —
  // never auto-replay quarantined text as trusted. Report how many were dropped.
  const qdir = resolve(agentDir, 'quarantine', 'pending', npub);
  let dropped = 0;
  if (existsSync(qdir)) {
    try {
      dropped = readdirSync(qdir).filter((f) => f.endsWith('.json')).length;
      rmSync(qdir, { recursive: true, force: true });
    } catch { /* best effort */ }
  }
  output({ status: 'approved', npub, tier, held_dropped: dropped, note: 'Backlog dropped (F7) — ask the sender to resend.' });
}

function denyContactCmd(args) {
  const npub = args._[0];
  if (!npub) fail('Usage: deny-contact <npub> --agent-dir <path>');
  const agentDir = agentDirFrom(args);
  const storePath = resolve(agentDir, 'contacts.json');
  const store = authz.loadStore(storePath);
  try {
    authz.denyContact(store, npub);
  } catch (e) {
    fail(e.message);
  }
  authz.saveStore(storePath, store);
  // Purge any quarantined backlog from this npub.
  const qdir = resolve(agentDir, 'quarantine', 'pending', npub);
  if (existsSync(qdir)) {
    try {
      rmSync(qdir, { recursive: true, force: true });
    } catch { /* best effort */ }
  }
  output({ status: 'blocked', npub });
}

function listContactsCmd(args) {
  const agentDir = agentDirFrom(args);
  const store = authz.loadStore(resolve(agentDir, 'contacts.json'));
  const contacts = Object.entries(store.contacts || {}).map(([npub, c]) => ({
    npub, tier: c.tier, nametag: c.nametag || '', label: c.label || '',
  }));
  const pending = Object.entries(store.pending || {}).map(([npub, p]) => ({
    npub, count_held: p.count_held || 0, nametag: p.nametag || '',
  }));
  output({ contacts, pending, blocked: store.blocked || [] });
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
  case 'join-group':
    await joinGroup(args);
    break;
  case 'send-dm':
    await sendDm(args);
    break;
  case 'check-messages':
    await checkMessages(args);
    break;
  case 'approve-contact':
    await approveContactCmd(args);
    break;
  case 'deny-contact':
    denyContactCmd(args);
    break;
  case 'list-contacts':
    listContactsCmd(args);
    break;
  default:
    fail(`Unknown command: ${command || '(none)'}
Usage: sphere-helper.mjs <command> [options]

Commands:
  create-identity                          Generate BIP-39 mnemonic + keypair
  resolve-nametag <nametag>                Resolve nametag to npub
  join-group <name> --identity <path>      Join/create NIP-29 group
  send-dm <npub> <msg> --identity <path>   Send encrypted DM
  check-messages --identity <p> --config <p>  Poll for new messages (firewalled)
  approve-contact <npub> [--tier team|owner] [--nametag <t>] [--label <s>] --agent-dir <p>
  deny-contact <npub> --agent-dir <p>
  list-contacts --agent-dir <p>`);
}
