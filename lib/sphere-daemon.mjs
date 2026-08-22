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
// Default poll interval: 5 seconds (tight fallback; --live adds sub-second push on top).
// Writes PID to /tmp/claude/<key>/sphere-daemon.pid (key = sha1(repo root)[:12])
// for stop/status commands; namespaced per repo to match hooks/state-dir.sh.

import { readFileSync, writeFileSync, unlinkSync, existsSync, mkdirSync, realpathSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

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
// Windows `path.resolve` preserves drive-letter CASE, so `c:\repo` and `C:\repo` resolve
// to different strings and hash to two different state dirs — each with its OWN
// seen-events.json. That splits the seen-set, which both duplicates and drops messages.
// Collapse the drive letter to lower-case on win32 so both map to one dir. Strict NO-OP on
// POSIX (guarded on platform + a POSIX path never matches `^[A-Za-z]:`), so the Linux/macOS
// state key — and the daemon's live state — is byte-identical to before this change.
export function driveLetterNormalize(resolvedPath, platform = process.platform) {
  if (platform === 'win32') return resolvedPath.replace(/^[A-Za-z]:/, (m) => m.toLowerCase());
  return resolvedPath;
}

export function stateDirFor(projectDir) {
  const root = driveLetterNormalize(resolve(projectDir), process.platform);
  const key = createHash('sha1').update(root).digest('hex').slice(0, 12);
  return `/tmp/claude/${key}`;
}

function pidFileFor(projectDir) {
  return `${stateDirFor(projectDir)}/sphere-daemon.pid`;
}

// Persistent, bounded set of already-dispatched OUTER gift-wrap event ids. The gift-wrap
// DM query window is intentionally wide (rolling `now - LOOKBACK`, ~3 days, because NIP-59
// randomizes the outer created_at backward up to ~2 days), so the same DM re-matches on
// every poll for days — we dedup by outer event id so each message hits the hook chain
// exactly once. Persisted so a daemon restart doesn't re-dispatch the whole backlog.
//
// Entries are pruned by TIME (id older than the re-query window can never be re-offered by
// the relay, so forgetting it can't cause a re-delivery) AND by a hard count cap. The TTL is
// kept >= the helper's gift-wrap LOOKBACK so an id is never forgotten while still in-window.
const SEEN_MAX = 5000;
const SEEN_TTL_SECONDS = (() => {
  const v = parseInt(process.env.GIFTWRAP_LOOKBACK_SECONDS || process.env.GIFTWRAP_SKEW_SECONDS || '', 10);
  return Number.isFinite(v) && v > 0 ? v : 3 * 24 * 60 * 60;
})();

function seenFileFor(projectDir) {
  return `${stateDirFor(projectDir)}/seen-events.json`;
}

// In-memory entry: { id, t } where t is the unix-seconds the id was first seen.
// On disk: array of [id, t] pairs. A legacy file is a plain array of id strings
// (pre-TTL); those are read and stamped as "just seen" so the upgrade drops nothing.
export function loadSeen(projectDir) {
  try {
    const raw = JSON.parse(readFileSync(seenFileFor(projectDir), 'utf-8'));
    if (!Array.isArray(raw)) return [];
    const nowSec = Math.floor(Date.now() / 1000);
    const out = [];
    for (const e of raw) {
      if (typeof e === 'string') out.push({ id: e, t: nowSec });                              // legacy string[]
      else if (Array.isArray(e) && typeof e[0] === 'string') out.push({ id: e[0], t: Number(e[1]) || nowSec });
      else if (e && typeof e.id === 'string') out.push({ id: e.id, t: Number(e.t) || nowSec });
    }
    return out;
  } catch {}
  return [];
}

// Drop ids older than the re-query window, then hard-cap to the newest SEEN_MAX.
export function pruneSeen(entries, nowSec = Math.floor(Date.now() / 1000)) {
  const floor = nowSec - SEEN_TTL_SECONDS;
  let out = entries.filter((e) => e && typeof e.id === 'string' && e.t >= floor);
  if (out.length > SEEN_MAX) out = out.slice(out.length - SEEN_MAX);
  return out;
}

export function persistSeen(projectDir, entries) {
  try {
    writeFileSync(seenFileFor(projectDir), JSON.stringify(entries.map((e) => [e.id, e.t])));
  } catch (e) {
    log(`Failed to persist seen-events: ${e.message}`);
  }
}

function ensureStateDir(projectDir) {
  const dir = stateDirFor(projectDir);
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true });
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

async function startDaemon(projectDir, intervalSecs, liveMode = false) {
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

  // Dedup state (persisted): insertion-ordered id list + fast lookup set. A SINGLE
  // dispatch path is shared by the interval poll and the live watcher, so a message can
  // never be double-delivered regardless of which source sees it first.
  const seenEntries = loadSeen(projectDir);
  const seenSet = new Set(seenEntries.map((e) => e.id));
  log(`Loaded ${seenEntries.length} previously-seen event id(s)`);

  // dispatch(msg) → true if newly delivered, false if already seen (or unhookable).
  const dispatch = (msg) => {
    if (msg.id && seenSet.has(msg.id)) return false;
    if (msg.id) {
      seenSet.add(msg.id);
      seenEntries.push({ id: msg.id, t: Math.floor(Date.now() / 1000) });
      // Prune by time (re-query window) + hard cap, keeping the lookup set in sync.
      const pruned = pruneSeen(seenEntries);
      if (pruned.length !== seenEntries.length) {
        const keep = new Set(pruned.map((e) => e.id));
        for (const e of seenEntries) if (!keep.has(e.id)) seenSet.delete(e.id);
        seenEntries.length = 0;
        for (const e of pruned) seenEntries.push(e);
      }
      persistSeen(projectDir, seenEntries);
    }
    if (msg.type === 'dm' && hooks.on_dm) {
      runHook(hooks.on_dm, msg, projectDir);
    } else if (msg.type === 'group' && hooks.on_group_message) {
      runHook(hooks.on_group_message, msg, projectDir);
    }
    return true;
  };

  let lastPollTime = Date.now() - (intervalSecs * 1000); // poll immediately on first run
  const poll = () => {
    const now = Date.now();
    log('Polling for messages...');
    const result = pollMessages(helperPath, identityFile, configFile, lastPollTime);
    lastPollTime = now;
    const allMessages = result.messages || [];
    let dispatched = 0;
    for (const msg of allMessages) { if (dispatch(msg)) dispatched++; }
    if (dispatched === 0) {
      log(allMessages.length ? `No new messages (${allMessages.length} already seen)` : 'No new messages');
    } else {
      log(`${dispatched} new message(s)`);
    }
  };

  // Interval poll — the default source, and the fallback if the live watcher dies.
  let intervalStarted = false;
  const startInterval = (reason) => {
    if (intervalStarted) return;
    intervalStarted = true;
    if (reason) log(`Interval poll active (${reason})`);
    setInterval(poll, intervalSecs * 1000);
  };

  // Live mode: a persistent `sphere-helper watch` subscription gives sub-second delivery;
  // its stdout is NDJSON, one message per line, fed through the same dispatch()+dedup. If
  // the watcher process exits (after a few respawns), we FALL BACK to interval poll so
  // delivery always continues. Default (no --live) is interval poll only.
  let currentWatcher = null;
  if (liveMode) {
    let retries = 0;
    const MAX_RETRIES = 3;
    const startWatcher = () => {
      log('Starting live relay watcher (sphere-helper watch)...');
      let child;
      try {
        child = spawn('node', [helperPath, 'watch', '--identity', identityFile, '--config', configFile], {
          env: { ...process.env, NODE_PATH: resolve(__dirname, '..', 'node_modules') + ':' + (process.env.NODE_PATH || '') },
          stdio: ['ignore', 'pipe', 'pipe'],
        });
      } catch (e) {
        log(`Watcher spawn failed: ${e.message}`);
        startInterval('watcher spawn failed');
        return;
      }
      currentWatcher = child;
      let buf = '';
      child.stdout.on('data', (d) => {
        buf += d.toString();
        let idx;
        while ((idx = buf.indexOf('\n')) >= 0) {
          const line = buf.slice(0, idx).trim();
          buf = buf.slice(idx + 1);
          if (!line) continue;
          let msg;
          try { msg = JSON.parse(line); } catch { continue; }
          retries = 0; // a healthy stream resets the respawn budget
          if (dispatch(msg)) log(`live: ${msg.type} ${(msg.id || '').slice(0, 10)} from ${(msg.from || '').slice(0, 10)}`);
        }
      });
      child.stderr.on('data', (d) => { const s = d.toString().trim(); if (s) log(`watch: ${s}`); });
      child.on('error', (e) => log(`Watcher error: ${e.message}`));
      child.on('exit', (code) => {
        currentWatcher = null;
        if (intervalStarted) return;
        if (retries < MAX_RETRIES) {
          retries++;
          const wait = 2000 * retries;
          log(`Watcher exited (code ${code}); respawn ${retries}/${MAX_RETRIES} in ${wait}ms`);
          setTimeout(startWatcher, wait);
        } else {
          startInterval(`watcher exited ${MAX_RETRIES}x`);
        }
      });
    };
    // Catch-up poll once so nothing sent during startup is missed, then go live.
    poll();
    startWatcher();
  } else {
    poll();
    startInterval();
  }

  // Handle shutdown
  const cleanup = () => {
    log('Shutting down...');
    try { if (currentWatcher) currentWatcher.kill('SIGTERM'); } catch {}
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

// Only run the CLI when executed directly, not when a test imports this module for its
// pure helpers (stateDirFor / loadSeen / pruneSeen / …). realpath both sides so a
// symlinked invocation still matches.
function isMainModule() {
  try {
    return realpathSync(process.argv[1] || '') === realpathSync(fileURLToPath(import.meta.url));
  } catch { return false; }
}

if (isMainModule()) {
const args = parseArgs(process.argv.slice(2));
const command = args._.shift();
const projectDir = args.project || process.env.CLAUDE_PROJECT_DIR || process.cwd();
const intervalSecs = parseInt(args.interval || '5', 10);
const liveMode = !!args.live; // persistent relay subscription (sub-second) + poll fallback

switch (command) {
  case 'start':
    await startDaemon(resolve(projectDir), intervalSecs, liveMode);
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
  --interval <secs>   Poll interval in seconds (default: 5)
  --live              Persistent relay subscription (sub-second) + interval-poll fallback`);
}
}
