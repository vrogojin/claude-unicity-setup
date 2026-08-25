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

// Rolling gift-wrap re-query window (mirrors sphere-helper's GIFTWRAP_LOOKBACK_SECONDS) and
// NIP-59's ±2-day created_at randomization bounds. A DM is re-offered by the relay on every
// poll for as long as its OUTER created_at stays >= the query floor, so we dedup by outer
// event id, and we prune an id ONLY once it can no longer be returned by any future query.
const LOOKBACK_SECONDS = (() => {
  const v = parseInt(process.env.GIFTWRAP_LOOKBACK_SECONDS || process.env.GIFTWRAP_SKEW_SECONDS || '', 10);
  return Number.isFinite(v) && v > 0 ? v : 3 * 24 * 60 * 60;
})();
const MAX_WRAP_BACKDATE_SECONDS = 2 * 24 * 60 * 60;  // NIP-59 randomizes created_at BACKWARD up to 2d
const MAX_FUTURE_SKEW_SECONDS = 2 * 24 * 60 * 60;    // …and FORWARD up to 2d

// --- Liveness heartbeat (L2.3) ---
// The daemon touches this file on every poll tick and every live dispatch, so its freshness
// is a proof-of-life that PID-liveness alone can't give: a daemon whose watcher has silently
// died (half-open socket, ignored CLOSED) keeps its PID but stops touching the heartbeat.
// `status --probe` reads it to report DEGRADED. The in-live poll BELT (see startDaemon)
// guarantees the heartbeat keeps advancing even when no messages arrive.
function heartbeatFileFor(projectDir) {
  return `${stateDirFor(projectDir)}/daemon-heartbeat.json`;
}
export function readHeartbeat(projectDir) {
  try { return JSON.parse(readFileSync(heartbeatFileFor(projectDir), 'utf-8')); } catch { return null; }
}
// Pure: a heartbeat is stale if missing, unparseable, or older than 3× its own effective
// poll interval (default 60s when the field is absent). Testable without a running daemon.
export function heartbeatStale(hb, nowSec) {
  if (!hb || !Number.isFinite(Number(hb.ts))) return true;
  const eff = Number.isFinite(Number(hb.effectiveIntervalSecs)) && Number(hb.effectiveIntervalSecs) > 0
    ? Number(hb.effectiveIntervalSecs) : 60;
  return (nowSec - Number(hb.ts)) > eff * 3;
}

function seenFileFor(projectDir) {
  return `${stateDirFor(projectDir)}/seen-events.json`;
}

// In-memory entry: { id, t } where t is the OUTER wrap's created_at (unix sec), i.e. the
// value the relay filters `since` on — NOT receipt time. Keying the prune on created_at is
// what makes a FUTURE-skewed wrap (relay-eligible until ~created_at + window) safe. On disk:
// array of [id, t] pairs. A legacy file is a plain array of id strings (pre-created_at);
// those are read and stamped "now" so the upgrade drops nothing still in-window.
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

// Prune-floor: the oldest OUTER created_at a steady-state query can still return, minus the
// max forward skew — so an id is forgotten only once the relay can no longer re-offer it.
// Tracks `now` (not the durable cursor): the live watcher and steady-state interval poll both
// query `>= now - LOOKBACK`; a downtime catch-up poll queries wider ONCE but advances the
// cursor immediately, so the wide window is never re-queried and its backlog ids are safe to
// prune right after dispatch. A legit NIP-59 wrap (created_at within ±2d) is thus never
// dropped while relay-eligible; only a garbage FAR-future created_at can re-appear (~weekly),
// which is bounded and idempotent downstream (classify-inbound sha1(from|body)) — the clamp
// on the stored value (see dispatch) is what keeps such an entry from pinning memory forever.
export function seenPruneFloor(nowSec) {
  return nowSec - LOOKBACK_SECONDS - MAX_FUTURE_SKEW_SECONDS;
}

// Keep every id whose created_at is at/above the prune floor — i.e. every id the relay could
// still re-offer. NO count cap: dropping an in-window id would re-deliver it. The set is
// naturally bounded by (window + skew) × message-rate; with a 3-day window that is tiny for
// per-agent DM volume.
export function pruneSeen(entries, pruneFloorSec) {
  return entries.filter((e) => e && typeof e.id === 'string' && Number.isFinite(e.t) && e.t >= pruneFloorSec);
}

export function persistSeen(projectDir, entries) {
  try {
    writeFileSync(seenFileFor(projectDir), JSON.stringify(entries.map((e) => [e.id, e.t])));
  } catch (e) {
    log(`Failed to persist seen-events: ${e.message}`);
  }
}

// --- Durable poll cursor (low-water mark) ---
// Persisted next to the seen-set and advanced ONLY after a fully successful poll, so a relay
// outage / long downtime can't skip maximally-backdated messages: on restart we resume from
// the last success instead of `now - interval`, and giftwrapSince clamps it correctly.
function cursorFileFor(projectDir) {
  return `${stateDirFor(projectDir)}/poll-cursor.json`;
}

export function loadCursor(projectDir) {
  try {
    const o = JSON.parse(readFileSync(cursorFileFor(projectDir), 'utf-8'));
    const s = Number(o && o.since);
    if (Number.isFinite(s) && s >= 0) return s;
  } catch {}
  return null;
}

export function saveCursor(projectDir, sinceSec) {
  try {
    writeFileSync(cursorFileFor(projectDir), JSON.stringify({ since: sinceSec }));
  } catch (e) {
    log(`Failed to persist poll cursor: ${e.message}`);
  }
}

// Advance the durable cursor to `nowSec` ONLY on a successful poll; leave it unchanged on
// failure (so the next attempt re-covers the same window).
export function nextCursor(prevCursorSec, nowSec, pollOk) {
  return pollOk ? nowSec : prevCursorSec;
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

// Returns the parsed helper result on success, or null on failure — the caller MUST treat
// null as "do not advance the cursor" (an empty-but-successful poll returns { messages: [] }).
function pollMessages(helperPath, identityFile, configFile, sinceSec) {
  try {
    const result = execFileSync('node', [
      helperPath, 'check-messages',
      '--identity', identityFile,
      '--config', configFile,
      '--since', String(Math.max(0, Math.floor(sinceSec))),
    ], {
      env: { ...process.env, NODE_PATH: resolve(__dirname, '..', 'node_modules') + ':' + (process.env.NODE_PATH || '') },
      timeout: 15000,
      encoding: 'utf-8',
    });
    return JSON.parse(result);
  } catch (e) {
    log(`Poll failed: ${e.message}`);
    return null;
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

  // Effective poll interval: in --live the interval poll runs as a 60s BELT under the
  // sub-second watcher (never below 60s so the belt is cheap); without --live it is the
  // configured interval. The belt is what bounds a SILENT watcher death to <=60s and keeps
  // the liveness heartbeat advancing when no messages arrive.
  const effectiveIntervalSecs = liveMode ? Math.max(intervalSecs, 60) : intervalSecs;
  let watcherAlive = false;
  const writeHeartbeat = () => {
    try {
      writeFileSync(heartbeatFileFor(projectDir), JSON.stringify({
        ts: Math.floor(Date.now() / 1000), pid: process.pid,
        live: liveMode, watcher: watcherAlive, effectiveIntervalSecs,
      }));
    } catch {}
  };
  writeHeartbeat(); // proof-of-life from the very first moment

  // Dedup state (persisted): insertion-ordered id list + fast lookup set. A SINGLE
  // dispatch path is shared by the interval poll and the live watcher, so a message can
  // never be double-delivered regardless of which source sees it first.
  const seenEntries = loadSeen(projectDir);
  const seenSet = new Set(seenEntries.map((e) => e.id));
  log(`Loaded ${seenEntries.length} previously-seen event id(s)`);

  // Durable poll cursor (low-water mark): resume from the last SUCCESSFUL poll across a
  // restart rather than `now - interval`, so downtime can't skip backdated messages.
  let cursorSec = loadCursor(projectDir);
  if (cursorSec == null) cursorSec = Math.floor((Date.now() - intervalSecs * 1000) / 1000);
  log(`Poll cursor: ${cursorSec} (${new Date(cursorSec * 1000).toISOString()})`);

  // dispatch(msg) → true if newly delivered, false if already seen (or unhookable).
  const dispatch = (msg) => {
    if (msg.id && seenSet.has(msg.id)) return false;
    if (msg.id) {
      const nowSec = Math.floor(Date.now() / 1000);
      // Stamp the entry with the OUTER wrap created_at (what the relay filters on), clamped
      // to now + max-future-skew so a garbage far-future timestamp can't pin the entry forever.
      const createdAt = Number.isFinite(Number(msg.wrap_created_at)) ? Number(msg.wrap_created_at) : nowSec;
      const t = Math.min(createdAt, nowSec + MAX_FUTURE_SKEW_SECONDS);
      seenSet.add(msg.id);
      seenEntries.push({ id: msg.id, t });
      // Prune only ids the relay can no longer return (created_at below the prune floor),
      // keeping the lookup set in sync. Never evicts an in-window id.
      const pruned = pruneSeen(seenEntries, seenPruneFloor(nowSec));
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

  const poll = () => {
    const nowSec = Math.floor(Date.now() / 1000);
    log('Polling for messages...');
    // Query from the durable cursor minus the max backdate, so a wrap backdated up to 2 days
    // before a just-after-cursor send is still returned; giftwrapSince clamps the upper bound.
    const querySince = Math.max(0, cursorSec - MAX_WRAP_BACKDATE_SECONDS);
    const result = pollMessages(helperPath, identityFile, configFile, querySince);
    if (!result) { log('Poll failed — cursor NOT advanced'); return; }  // never advance on failure
    const allMessages = result.messages || [];
    let dispatched = 0;
    for (const msg of allMessages) { if (dispatch(msg)) dispatched++; }
    // Advance + persist the durable cursor ONLY after a fully successful poll.
    cursorSec = nextCursor(cursorSec, nowSec, true);
    saveCursor(projectDir, cursorSec);
    if (dispatched === 0) {
      log(allMessages.length ? `No new messages (${allMessages.length} already seen)` : 'No new messages');
    } else {
      log(`${dispatched} new message(s)`);
    }
    writeHeartbeat(); // every poll tick is a proof-of-life (the belt keeps this fresh)
  };

  // Interval poll — in --live it is the 60s BELT that ALWAYS runs alongside the watcher
  // (dispatch() dedup makes double-delivery impossible), bounding any silent watcher death
  // to <=60s. Without --live it is the sole source at the configured interval.
  let intervalStarted = false;
  const startInterval = (reason) => {
    if (intervalStarted) return;
    intervalStarted = true;
    if (reason) log(`Interval poll active (${reason})`);
    setInterval(poll, effectiveIntervalSecs * 1000);
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
        watcherAlive = false; writeHeartbeat();
        return; // the belt (started below) covers delivery
      }
      currentWatcher = child;
      watcherAlive = true; writeHeartbeat();
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
          writeHeartbeat(); // live activity is proof-of-life too
        }
      });
      child.stderr.on('data', (d) => { const s = d.toString().trim(); if (s) log(`watch: ${s}`); });
      child.on('error', (e) => log(`Watcher error: ${e.message}`));
      child.on('exit', (code) => {
        currentWatcher = null;
        watcherAlive = false; writeHeartbeat();
        // The 60s poll belt (started unconditionally below) already guarantees delivery, so a
        // watcher death is never deafness — only a latency bump to <=60s. Still try to restore
        // sub-second delivery: fast respawns first, then a slow 60s revive loop indefinitely.
        if (retries < MAX_RETRIES) {
          retries++;
          const wait = 2000 * retries;
          log(`Watcher exited (code ${code}); respawn ${retries}/${MAX_RETRIES} in ${wait}ms`);
          setTimeout(startWatcher, wait);
        } else {
          log(`Watcher exited ${MAX_RETRIES}x — 60s poll belt covers delivery; reviving watcher in 60s`);
          setTimeout(() => { retries = 0; startWatcher(); }, 60000);
        }
      });
    };
    // Catch-up poll once so nothing sent during startup is missed, start the live watcher,
    // AND start the interval belt unconditionally (the belt is the silent-death safety net).
    poll();
    startWatcher();
    startInterval(`belt for live mode (${effectiveIntervalSecs}s)`);
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

// statusDaemon: PID-liveness by default; with `--probe` it ALSO reads the heartbeat and
// reports DEGRADED when the poll belt has stalled (watcher silently dead + belt wedged).
// Exit codes let scripts branch: 0 = running (probe: OK), 3 = not running, 4 = DEGRADED.
function statusDaemon(projectDir, probe = false) {
  const PID_FILE = pidFileFor(projectDir);
  if (!existsSync(PID_FILE)) {
    console.log('Daemon is not running.');
    if (probe) process.exit(3);
    return;
  }

  const pid = parseInt(readFileSync(PID_FILE, 'utf-8').trim(), 10);
  let alive = false;
  try { process.kill(pid, 0); alive = true; } catch {}
  if (!alive) {
    console.log(`Daemon is not running (stale PID file for ${pid}). Cleaning up.`);
    try { unlinkSync(PID_FILE); } catch {}
    if (probe) process.exit(3);
    return;
  }
  console.log(`Daemon is running (PID ${pid})`);
  if (!probe) return;

  const hb = readHeartbeat(projectDir);
  const nowSec = Math.floor(Date.now() / 1000);
  if (heartbeatStale(hb, nowSec)) {
    const age = hb && Number.isFinite(Number(hb.ts)) ? `${nowSec - Number(hb.ts)}s` : 'n/a (no heartbeat)';
    console.log(`probe: DEGRADED — heartbeat age ${age} exceeds 3x poll interval; watcher=${hb ? hb.watcher : '?'}`);
    process.exit(4);
  }
  console.log(`probe: OK — heartbeat age ${nowSec - Number(hb.ts)}s, watcher=${hb.watcher}, live=${hb.live}`);
}

// --- Main ---

// Only run the CLI when executed directly, not when a test imports this module for its pure
// helpers (stateDirFor / loadSeen / pruneSeen / heartbeatStale / readHeartbeat / …). realpath
// both sides so a symlinked invocation still matches.
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
    statusDaemon(resolve(projectDir), !!args.probe);
    break;
  default:
    fail(`Usage: sphere-daemon.mjs <start|stop|status> --project <dir> [--interval <secs>]

Commands:
  start    Start polling for messages (runs in foreground, use & for background)
  stop     Stop the running daemon
  status   Check if daemon is running (add --probe for heartbeat-based DEGRADED detection)

Options:
  --project <dir>     Target project directory (default: cwd)
  --interval <secs>   Poll interval in seconds (default: 5)
  --live              Persistent relay subscription (sub-second) + interval-poll BELT (60s)
  --probe             (status) also read the heartbeat: exit 0=OK, 3=not running, 4=DEGRADED`);
}
}
