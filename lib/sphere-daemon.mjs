#!/usr/bin/env node
// sphere-daemon.mjs — Background daemon that polls for Nostr messages
// and triggers hook scripts for the Claude Code agent.
//
// Usage:
//   node lib/sphere-daemon.mjs start --project <dir> [--interval <secs>]
//   node lib/sphere-daemon.mjs stop
//   node lib/sphere-daemon.mjs status
//
// Reads config from <project>/.claude/agent/daemon.json and identity.json.
// Polls for messages using sphere-helper.mjs check-messages, then pipes
// new messages to on-dm.sh / on-group-message.sh hooks.
//
// Default poll interval: 60 seconds.
// Writes PID to /tmp/claude/<key>/sphere-daemon.pid (key = sha1(repo root)[:12])
// for stop/status commands; namespaced per repo to match hooks/state-dir.sh.

import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { execSync, spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { processInbound, loadBusState } from './pipeline.mjs';
import * as authz from './authz-firewall.mjs';
import * as sif from './semantic-firewall.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// --- Utilities ---

function fail(msg) {
  console.error(`[sphere-daemon] ${msg}`);
  process.exit(1);
}

function log(msg) {
  const ts = new Date().toISOString();
  console.log(`[${ts}] ${msg}`);
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

// Per-repo state dir: namespace coordination files under /tmp/claude/<key> so two
// daemons (one per repo) don't collide on a shared PID file / message store. The
// key is sha1(repo root)[:12] — identical scheme to hooks/state-dir.sh, so the
// daemon and the on-dm.sh / on-group-message.sh hooks resolve the same directory.
function stateDirFor(projectDir) {
  const root = resolve(projectDir);
  const key = createHash('sha1').update(root).digest('hex').slice(0, 12);
  return `/tmp/claude/${key}`;
}

function pidFileFor(projectDir) {
  return `${stateDirFor(projectDir)}/sphere-daemon.pid`;
}

function ensureStateDir(projectDir) {
  const dir = stateDirFor(projectDir);
  if (!existsSync(dir)) {
    execSync(`mkdir -p ${dir}`);
  }
}

// --- Hook execution ---

function runHook(hookPath, messageJson, projectDir) {
  const fullPath = resolve(projectDir, hookPath);
  if (!existsSync(fullPath)) {
    log(`Hook not found: ${fullPath}`);
    return;
  }

  try {
    const child = spawn('bash', [fullPath], {
      env: { ...process.env, CLAUDE_PROJECT_DIR: projectDir },
      stdio: ['pipe', 'ignore', 'ignore'],
    });

    child.stdin.write(JSON.stringify(messageJson));
    child.stdin.end();

    child.on('error', (err) => {
      log(`Hook error (${hookPath}): ${err.message}`);
    });
  } catch (e) {
    log(`Failed to run hook ${hookPath}: ${e.message}`);
  }
}

// --- Dispatch (shared by poll + realtime paths) ---

// Route a firewalled result set to the hooks. Surfaced (owner/team) messages go
// to on_dm / on_group_message; pending contact requests + held (SIF-unreachable)
// notices go to on_notice — which carries ONLY structural facts (F6), never peer
// text. Anything dropped by the firewall (blocked/rate/dup) never reaches here.
function dispatchResult(result, hooks, projectDir) {
  for (const msg of result.messages || []) {
    if (msg.type === 'group' && hooks.on_group_message) runHook(hooks.on_group_message, msg, projectDir);
    else if (hooks.on_dm) runHook(hooks.on_dm, msg, projectDir);
  }
  const noticeHook = hooks.on_notice || '.claude/hooks/on-notice.sh';
  for (const p of result.pending || []) {
    runHook(noticeHook, { kind: 'pending_contact', from_npub: p.npub, count_held: p.count_held }, projectDir);
  }
  for (const h of result.held || []) {
    runHook(noticeHook, { kind: 'held', from_npub: h.npub, tier: h.tier, reason: h.reason }, projectDir);
  }
}

// Cold-start backfill window: prefer the persisted per-relay high-water mark
// (bus-state.json last_seen) so a restart doesn't silently skip or re-flood.
function coldStartSince(agentDir, fallbackMs) {
  try {
    const st = loadBusState(resolve(agentDir, 'bus-state.json'));
    const marks = Object.values(st.last_seen || {}).filter((n) => Number.isFinite(n));
    if (marks.length) return Math.max(...marks) + 1;
  } catch { /* ignore */ }
  return Math.floor(fallbackMs / 1000);
}

// --- Polling ---

function pollMessages(helperPath, identityFile, configFile, sinceSec) {
  const since = sinceSec;
  try {
    const result = execFileSync('node', [
      helperPath, 'check-messages',
      '--identity', identityFile,
      '--config', configFile,
      '--since', String(since),
    ], {
      env: { ...process.env, NODE_PATH: resolve(__dirname, '..', 'node_modules') + ':' + (process.env.NODE_PATH || '') },
      timeout: 15000,
      encoding: 'utf-8',
    });
    return JSON.parse(result);
  } catch (e) {
    log(`Poll failed: ${e.message}`);
    return { messages: [] };
  }
}

// --- Real-time push loop (design §8 P0 item 5; INERT unless --realtime) ---
//
// Holds ONE long-lived NostrClient with permanent subscriptions and runs each
// event through the SAME firewall pipeline in-process (sub-second). This is the
// SDK's native real-time path; the 60s poll survives only as cold-start backfill.
async function startRealtime({ agentDir, identityFile, configFile, hooks, projectDir }) {
  const nostr = await import('@unicitylabs/nostr-js-sdk');
  const sdk = await import('@unicitylabs/sphere-sdk');
  const identity = JSON.parse(readFileSync(identityFile, 'utf-8'));
  const config = JSON.parse(readFileSync(configFile, 'utf-8'));
  const daemonCfg = existsSync(resolve(agentDir, 'daemon.json'))
    ? JSON.parse(readFileSync(resolve(agentDir, 'daemon.json'), 'utf-8')) : {};
  const relays = config.group?.relays || ['wss://nostr-relay.testnet.unicity.network'];

  // Build key manager (mirrors sphere-helper.createNostrClient).
  let keyManager;
  if (identity.nsec) keyManager = nostr.NostrKeyManager.fromNsec(identity.nsec);
  else if (identity.private_key) keyManager = nostr.NostrKeyManager.fromPrivateKeyHex(identity.private_key);
  else {
    const master = sdk.identityFromMnemonicSync(identity.mnemonic);
    const path = identity.derivation_path || sdk.DEFAULT_DERIVATION_PATH;
    const child = sdk.deriveKeyAtPath(master.privateKey, master.chainCode, path);
    keyManager = nostr.NostrKeyManager.fromPrivateKeyHex(child.privateKey);
  }
  const client = new nostr.NostrClient(keyManager, { autoReconnect: true });
  await client.connect(...relays);
  const myPubkeyHex = keyManager.getPublicKeyHex();
  const hexToNpub = (hex) => { try { return nostr.encodeNpub(Buffer.from(hex, 'hex')); } catch { return hex; } };

  const storePath = resolve(agentDir, 'contacts.json');
  const statePath = resolve(agentDir, 'bus-state.json');
  const sifCfg = sif.resolveConfig(daemonCfg.semantic_firewall || {}, process.env);
  const since = coldStartSince(agentDir, Date.now() - 60_000);

  // Serialize pipeline runs so concurrent events can't race the durable state.
  let chain = Promise.resolve();
  const runPipeline = (raw) => {
    chain = chain.then(async () => {
      const ctx = {
        store: authz.loadStore(storePath), storePath,
        state: loadBusState(statePath), statePath, agentDir,
        ownerNpub: config.owner_npub || null,
        npubForHex: hexToNpub, sifCfg, fetchImpl: fetch, now: Date.now(),
      };
      const d = await processInbound(raw, ctx);
      const result = { messages: [], pending: [], held: [] };
      if (d.outcome === 'surface') result.messages.push(d.surface);
      else if (d.outcome === 'quarantined_pending') result.pending.push(d.pending);
      else if (d.outcome === 'held') result.held.push(d.held);
      dispatchResult(result, hooks, projectDir);
    }).catch((e) => log(`pipeline error: ${e.message}`));
    return chain;
  };

  client.subscribe(
    new nostr.Filter({ kinds: [nostr.GIFT_WRAP], '#p': [myPubkeyHex], since }),
    new nostr.CallbackEventListener((event) => {
      try {
        const u = client.unwrapPrivateMessage(event);
        if (!u || u.kind === 15) return;
        runPipeline({ type: 'dm', fromHex: u.senderPubkey, body: u.content,
          eventId: u.eventId || event.id, timestampSec: u.timestamp || event.created_at, kind: u.kind });
      } catch { /* not for us */ }
    }),
  );

  const groupId = config.group?.id;
  if (groupId) {
    client.subscribe(
      new nostr.Filter({ kinds: [9], '#h': [groupId], since }),
      new nostr.CallbackEventListener((event) => {
        if (event.pubkey === myPubkeyHex) return;
        const gid = (event.tags || []).find((t) => t[0] === 'h')?.[1] || groupId;
        runPipeline({ type: 'group', fromHex: event.pubkey, body: event.content,
          eventId: event.id, timestampSec: event.created_at, kind: event.kind,
          group: { id: gid, name: config.group?.name || 'UNICITY_DEV_AGENTS' } });
      }),
    );
  }
  log('Real-time subscriptions live. Waiting for events...');
  // Keep the process alive; events drive dispatch via the listeners above.
  await new Promise(() => {});
}

// --- Commands ---

async function startDaemon(projectDir, intervalSecs) {
  const agentDir = resolve(projectDir, '.claude/agent');
  const daemonConfig = readJson(resolve(agentDir, 'daemon.json'));
  const identityFile = resolve(agentDir, 'identity.json');
  const configFile = resolve(agentDir, 'config.json');
  const helperPath = resolve(__dirname, 'sphere-helper.mjs');

  if (!existsSync(identityFile)) fail(`Identity file not found: ${identityFile}`);
  if (!existsSync(configFile)) fail(`Config file not found: ${configFile}`);
  if (!existsSync(helperPath)) fail(`sphere-helper.mjs not found: ${helperPath}`);

  const hooks = daemonConfig.hooks || {};

  log(`Starting sphere-daemon for ${projectDir}`);
  log(`Poll interval: ${intervalSecs}s`);
  log(`Relays: ${(daemonConfig.relays || []).join(', ')}`);

  ensureStateDir(projectDir);
  const PID_FILE = pidFileFor(projectDir);

  // Check for existing daemon
  if (existsSync(PID_FILE)) {
    const existingPid = parseInt(readFileSync(PID_FILE, 'utf-8').trim(), 10);
    try {
      process.kill(existingPid, 0);
      fail(`Daemon already running (PID ${existingPid}). Run 'stop' first.`);
    } catch {
      // Stale PID file
      try { unlinkSync(PID_FILE); } catch {}
    }
  }

  // Write PID file
  writeFileSync(PID_FILE, String(process.pid));
  log(`Daemon running (PID ${process.pid})`);

  // NOTE (design §8 P0): the real-time NostrClient.subscribe() push loop is
  // IMPLEMENTED (startRealtime, below) but INERT BY DEFAULT — P0 ships inbox +
  // firewalls only. Enable it explicitly with `--realtime` or daemon.json
  // "realtime": true after human review. The default remains the poll loop,
  // now firewalled through the same pipeline and cold-start-backfilled.
  const realtime = args.realtime === true || daemonConfig.realtime === true;

  // Poll loop (default). First poll backfills from the persisted last_seen.
  let firstPoll = true;
  let lastPollTime = Date.now() - (intervalSecs * 1000);

  const poll = () => {
    const now = Date.now();
    const sinceSec = firstPoll
      ? coldStartSince(agentDir, lastPollTime)
      : Math.floor(lastPollTime / 1000);
    firstPoll = false;
    log('Polling for messages...');

    const result = pollMessages(helperPath, identityFile, configFile, sinceSec);
    lastPollTime = now;

    const counts = (result.messages || []).length;
    const notices = (result.pending || []).length + (result.held || []).length;
    if (counts === 0 && notices === 0) { log('No new messages'); return; }
    log(`${counts} surfaced, ${notices} notice(s)`);
    dispatchResult(result, hooks, projectDir);
  };

  if (realtime) {
    log('Real-time push loop ENABLED (experimental).');
    await startRealtime({ agentDir, identityFile, configFile, hooks, projectDir })
      .catch((e) => { log(`Realtime loop failed, falling back to poll: ${e.message}`); poll(); setInterval(poll, intervalSecs * 1000); });
  } else {
    poll();                                   // first (backfill) poll
    setInterval(poll, intervalSecs * 1000);   // recurring
  }

  // Handle shutdown
  const cleanup = () => {
    log('Shutting down...');
    try { unlinkSync(PID_FILE); } catch {}
    process.exit(0);
  };

  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);
}

function stopDaemon(projectDir) {
  const PID_FILE = pidFileFor(projectDir);
  if (!existsSync(PID_FILE)) {
    console.log('Daemon is not running (no PID file).');
    return;
  }

  const pid = parseInt(readFileSync(PID_FILE, 'utf-8').trim(), 10);
  try {
    process.kill(pid, 'SIGTERM');
    console.log(`Stopped daemon (PID ${pid})`);
  } catch (e) {
    if (e.code === 'ESRCH') {
      console.log(`Daemon process ${pid} not found (stale PID file). Cleaning up.`);
    } else {
      console.error(`Failed to stop daemon: ${e.message}`);
    }
  }

  try { unlinkSync(PID_FILE); } catch {}
}

function statusDaemon(projectDir) {
  const PID_FILE = pidFileFor(projectDir);
  if (!existsSync(PID_FILE)) {
    console.log('Daemon is not running.');
    return;
  }

  const pid = parseInt(readFileSync(PID_FILE, 'utf-8').trim(), 10);
  try {
    process.kill(pid, 0);
    console.log(`Daemon is running (PID ${pid})`);
  } catch {
    console.log(`Daemon is not running (stale PID file for ${pid}). Cleaning up.`);
    try { unlinkSync(PID_FILE); } catch {}
  }
}

// --- Main ---

const args = parseArgs(process.argv.slice(2));
const command = args._.shift();
const projectDir = args.project || process.env.CLAUDE_PROJECT_DIR || process.cwd();
const intervalSecs = parseInt(args.interval || '60', 10);

switch (command) {
  case 'start':
    await startDaemon(resolve(projectDir), intervalSecs);
    break;
  case 'stop':
    stopDaemon(resolve(projectDir));
    break;
  case 'status':
    statusDaemon(resolve(projectDir));
    break;
  default:
    fail(`Usage: sphere-daemon.mjs <start|stop|status> --project <dir> [--interval <secs>]

Commands:
  start    Start polling for messages (runs in foreground, use & for background)
  stop     Stop the running daemon
  status   Check if daemon is running

Options:
  --project <dir>     Target project directory (default: cwd)
  --interval <secs>   Poll interval in seconds (default: 60)`);
}
