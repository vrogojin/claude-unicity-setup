#!/usr/bin/env node
// sphere-daemon.mjs — Background daemon that listens for Nostr messages
// and triggers hook scripts for the Claude Code agent.
//
// Usage:
//   node lib/sphere-daemon.mjs start --project <dir>
//   node lib/sphere-daemon.mjs stop  --project <dir>
//   node lib/sphere-daemon.mjs status --project <dir>
//
// Reads config from <project>/.claude/agent/daemon.json and identity.json.
// On incoming DM → pipes message JSON to on-dm.sh
// On incoming group message → pipes message JSON to on-group-message.sh
//
// Writes PID to /tmp/claude/sphere-daemon.pid for stop/status commands.

import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { execSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

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

const PID_FILE = '/tmp/claude/sphere-daemon.pid';
const STATE_DIR = '/tmp/claude';

function ensureStateDir() {
  if (!existsSync(STATE_DIR)) {
    execSync(`mkdir -p ${STATE_DIR}`);
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

// --- Commands ---

async function startDaemon(projectDir) {
  const agentDir = resolve(projectDir, '.claude/agent');
  const daemonConfig = readJson(resolve(agentDir, 'daemon.json'));
  const identity = readJson(resolve(agentDir, 'identity.json'));

  const relays = daemonConfig.relays || ['wss://relay.testnet.unicity.network'];
  const hooks = daemonConfig.hooks || {};

  log(`Starting sphere-daemon for ${projectDir}`);
  log(`Relays: ${relays.join(', ')}`);
  log(`Subscriptions: ${JSON.stringify(daemonConfig.subscriptions)}`);

  // Load sphere-sdk
  let sdk;
  try {
    sdk = await import('@unicitylabs/sphere-sdk');
  } catch {
    fail('@unicitylabs/sphere-sdk is not installed.');
  }

  // In-memory storage adapter (daemon doesn't persist wallet state)
  const memStorage = {
    _data: new Map(),
    _connected: false,
    _id: 'sphere-daemon-mem',
    get id() { return this._id; },
    isConnected() { return this._connected; },
    async connect() { this._connected = true; },
    async disconnect() { this._connected = false; },
    async get(key) { return this._data.get(key) ?? null; },
    async set(key, value) { this._data.set(key, value); },
    async delete(key) { this._data.delete(key); },
    async has(key) { return this._data.has(key); },
    async keys() { return [...this._data.keys()]; },
    async clear() { this._data.clear(); },
    async setIdentity(id) { this._id = id; },
    async saveTrackedAddresses(addrs) { this._data.set('__tracked_addresses', addrs); },
    async loadTrackedAddresses() { return this._data.get('__tracked_addresses') ?? []; },
  };

  // Initialize Sphere with the agent's mnemonic
  let sphere;
  try {
    const result = await sdk.initSphere({
      mnemonic: identity.mnemonic !== '(imported)' ? identity.mnemonic : undefined,
      storage: memStorage,
      network: relays[0].includes('mainnet') ? 'mainnet' : 'testnet',
    });
    sphere = result.sphere;
    log('Sphere initialized');
  } catch (e) {
    fail(`Failed to initialize Sphere: ${e.message}`);
  }

  // Register DM handler
  if (sphere.communications) {
    sphere.communications.onDirectMessage((msg) => {
      log(`DM from ${msg.sender || msg.pubkey || 'unknown'}`);
      if (hooks.on_dm) {
        runHook(hooks.on_dm, msg, projectDir);
      }
    });
    log('Listening for DMs');
  }

  // Register group message handler
  if (sphere.groupChat) {
    const groups = daemonConfig.subscriptions?.groups || [];
    for (const group of groups) {
      try {
        sphere.groupChat.onMessage?.(group.id, (msg) => {
          log(`Group message in ${group.name} from ${msg.sender || msg.pubkey || 'unknown'}`);
          if (hooks.on_group_message) {
            runHook(hooks.on_group_message, msg, projectDir);
          }
        });
        log(`Listening to group: ${group.name} (${group.id})`);
      } catch (e) {
        log(`Could not subscribe to group ${group.name}: ${e.message}`);
      }
    }
  }

  // Write PID file
  ensureStateDir();
  writeFileSync(PID_FILE, String(process.pid));
  log(`Daemon running (PID ${process.pid})`);

  // Handle shutdown
  const cleanup = () => {
    log('Shutting down...');
    try { unlinkSync(PID_FILE); } catch {}
    process.exit(0);
  };

  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);

  // Keep alive
  setInterval(() => {}, 60000);
}

function stopDaemon() {
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

function statusDaemon() {
  if (!existsSync(PID_FILE)) {
    console.log('Daemon is not running.');
    return;
  }

  const pid = parseInt(readFileSync(PID_FILE, 'utf-8').trim(), 10);
  try {
    process.kill(pid, 0); // Signal 0 = check if process exists
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

switch (command) {
  case 'start':
    await startDaemon(resolve(projectDir));
    break;
  case 'stop':
    stopDaemon();
    break;
  case 'status':
    statusDaemon();
    break;
  default:
    fail(`Usage: sphere-daemon.mjs <start|stop|status> --project <dir>

Commands:
  start   Start listening for messages (runs in foreground, use & for background)
  stop    Stop the running daemon
  status  Check if daemon is running`);
}
