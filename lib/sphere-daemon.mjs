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
// Writes PID to /tmp/claude/sphere-daemon.pid for stop/status commands.

import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { execSync, spawn, execFileSync } from 'node:child_process';
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
const STATE_FILE = `${STATE_DIR}/agent-messages.json`;

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

// --- Polling ---

function pollMessages(helperPath, identityFile, configFile, lastPollTime) {
  const since = Math.floor(lastPollTime / 1000);
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

  ensureStateDir();

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

  // Poll loop
  let lastPollTime = Date.now() - (intervalSecs * 1000); // poll immediately on first run

  const poll = () => {
    const now = Date.now();
    log('Polling for messages...');

    const result = pollMessages(helperPath, identityFile, configFile, lastPollTime);
    lastPollTime = now;

    const newMessages = result.messages || [];
    if (newMessages.length === 0) {
      log('No new messages');
      return;
    }

    log(`${newMessages.length} new message(s)`);

    for (const msg of newMessages) {
      if (msg.type === 'dm' && hooks.on_dm) {
        runHook(hooks.on_dm, msg, projectDir);
      } else if (msg.type === 'group' && hooks.on_group_message) {
        runHook(hooks.on_group_message, msg, projectDir);
      }
    }
  };

  // First poll
  poll();

  // Schedule recurring polls
  setInterval(poll, intervalSecs * 1000);

  // Handle shutdown
  const cleanup = () => {
    log('Shutting down...');
    try { unlinkSync(PID_FILE); } catch {}
    process.exit(0);
  };

  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);
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
    stopDaemon();
    break;
  case 'status':
    statusDaemon();
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
