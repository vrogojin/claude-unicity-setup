// Tests for the A2A poller NIP-59 gift-wrap fix.
//
// Bug (diagnosed live by krugol-agent): our DM poller queries the relay with
// `since = cursor` and the relay filters on each event's `created_at`. NIP-17 DMs are
// NIP-59 gift-wrapped (kind 1059) and NIP-59 randomizes the OUTER wrap's `created_at`
// BACKWARD by up to ~2 days. So once the cursor has advanced past a wrap's backdated
// timestamp, a `since=cursor` query PERMANENTLY excludes it — silent, permanent
// receive-side loss. Secondary bug: the daemon's per-repo state dir keyed on
// sha1(resolve(path)) split in two on Windows (c:\ vs C:\ drive-letter case), splitting
// the seen-set.
//
// Fix under test: rolling `now - LOOKBACK` gift-wrap floor (giftwrapSince) + persistent
// outer-wrap-id dedup pruned by the same window (loadSeen/pruneSeen/persistSeen) +
// drive-letter normalization (driveLetterNormalize) that is a strict no-op on POSIX.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';

import { giftwrapSince, GIFTWRAP_LOOKBACK_SECONDS } from '../lib/sphere-helper.mjs';
import { driveLetterNormalize, stateDirFor, loadSeen, pruneSeen, persistSeen } from '../lib/sphere-daemon.mjs';

const HOUR = 3600;
const DAY = 24 * HOUR;

// ---------------------------------------------------------------------------------
// 1. Rolling lookback: a backdated gift-wrap is INCLUDED even after the cursor advanced.
// ---------------------------------------------------------------------------------
test('giftwrapSince: backdated wrap is surfaced despite an advanced cursor', () => {
  const now = 2_000_000_000;                 // fixed "now" for determinism
  const cursor = now;                        // cursor has advanced all the way to now
  const wrapCreatedAt = now - 26 * HOUR;     // NIP-59 backdated the outer wrap ~26h

  // The OLD (buggy) behavior was a plain advancing cursor: since = cursor. The relay
  // would then EXCLUDE any wrap with created_at < since — dropping our backdated wrap.
  assert.ok(wrapCreatedAt < cursor, 'precondition: backdated wrap is older than the cursor (old code would drop it)');

  // NEW behavior: the floor never advances past now - LOOKBACK, so the wrap is included.
  const floor = giftwrapSince(cursor, now);
  assert.equal(floor, now - GIFTWRAP_LOOKBACK_SECONDS, 'floor pinned to now - LOOKBACK');
  assert.ok(wrapCreatedAt >= floor, 'backdated wrap is now INSIDE the query window (not dropped)');
});

test('giftwrapSince: LOOKBACK default is 3 days (> NIP-59 2-day max backdate + margin)', () => {
  assert.equal(GIFTWRAP_LOOKBACK_SECONDS, 3 * DAY);
  // Even a wrap backdated the full NIP-59 max (2 days) sits comfortably inside the window
  // with a day of margin for cursor drift — the exact gap the old 2-day skew left open.
  const now = 2_000_000_000;
  const maxBackdated = now - 2 * DAY;
  assert.ok(maxBackdated >= giftwrapSince(now, now), '2-day-backdated wrap is inside the window');
});

test('giftwrapSince: an explicit smaller --since is preserved (manual drain still works)', () => {
  const now = 2_000_000_000;
  assert.equal(giftwrapSince(0, now), 0, '--since 0 drains everything');
  // A far-behind cursor (daemon caught up after downtime) reaches back further than LOOKBACK.
  const stale = now - 10 * DAY;
  assert.equal(giftwrapSince(stale, now), stale, 'a cursor older than LOOKBACK is honored as-is');
  // Never negative.
  assert.ok(giftwrapSince(100, 100) >= 0);
});

// ---------------------------------------------------------------------------------
// 2. Two-poll seen-dedup: the wide window re-offers the same wrap; it dispatches ONCE.
//    Exercises the real persist → load round-trip + outer-wrap-id dedup.
// ---------------------------------------------------------------------------------
test('seen-dedup: backdated wrap surfaces on poll #1, is deduped on poll #2', () => {
  const dir = mkdtempSync(join(tmpdir(), 'poller-seen-'));
  mkdirSync(stateDirFor(dir), { recursive: true });          // where persistSeen writes
  try {
    // A minimal daemon-style dispatch over the persistent seen store.
    const seenEntries = loadSeen(dir);                       // empty on first run
    const seenSet = new Set(seenEntries.map((e) => e.id));
    const dispatch = (msg, nowSec) => {
      if (msg.id && seenSet.has(msg.id)) return false;       // already delivered
      if (msg.id) {
        seenSet.add(msg.id);
        seenEntries.push({ id: msg.id, t: nowSec });
        persistSeen(dir, seenEntries);
      }
      return true;
    };

    // The SAME outer gift-wrap event is returned by both polls because the rolling window
    // is wide (its backdated created_at keeps matching). Its id is the OUTER wrap id.
    const wrap = { id: 'wrap-outer-id-abc', type: 'dm', from: 'peer', body: 'PROBE-7731' };
    const now = 2_000_000_000;

    assert.equal(dispatch(wrap, now), true, 'poll #1 delivers the backdated wrap');
    assert.equal(dispatch(wrap, now + 5), false, 'poll #2 does NOT re-deliver it (seen dedup)');

    // And a fresh daemon (restart) reloads the seen-set from disk → still deduped.
    const reloaded = loadSeen(dir);
    const reloadedSet = new Set(reloaded.map((e) => e.id));
    assert.ok(reloadedSet.has(wrap.id), 'seen id survives a restart (persisted)');
  } finally {
    rmSync(dir, { recursive: true, force: true });
    try { rmSync(stateDirFor(dir), { recursive: true, force: true }); } catch {}
  }
});

test('seen store: reads a legacy string[] seen-events.json without dropping ids', () => {
  // loadSeen reads from stateDirFor(dir)/seen-events.json — use a unique project path so
  // the derived state dir is unique to this test, then plant a legacy-format file there.
  const proj = join(tmpdir(), `poller-legacy-${process.pid}-${Date.now()}`);
  const stateDir = stateDirFor(proj);
  try {
    mkdirSync(stateDir, { recursive: true });
    // Pre-fix format was a plain array of id strings.
    writeFileSync(join(stateDir, 'seen-events.json'), JSON.stringify(['legacy-1', 'legacy-2']));
    const entries = loadSeen(proj);
    const ids = entries.map((e) => e.id).sort();
    assert.deepEqual(ids, ['legacy-1', 'legacy-2'], 'legacy string ids are read');
    assert.ok(entries.every((e) => Number.isFinite(e.t)), 'legacy ids get a timestamp stamp');

    // And after a save the file is upgraded to the [id, t] pair format, still readable.
    persistSeen(proj, entries);
    const round = loadSeen(proj);
    assert.deepEqual(round.map((e) => e.id).sort(), ['legacy-1', 'legacy-2']);
  } finally {
    try { rmSync(stateDir, { recursive: true, force: true }); } catch {}
  }
});

// ---------------------------------------------------------------------------------
// 3. Time-based pruning: ids older than the window are dropped; in-window ids kept;
//    a hard count cap bounds growth.
// ---------------------------------------------------------------------------------
test('pruneSeen: drops ids older than the re-query window, keeps in-window ids', () => {
  const now = 2_000_000_000;
  const entries = [
    { id: 'fresh', t: now - 1 * HOUR },
    { id: 'edge-in', t: now - (GIFTWRAP_LOOKBACK_SECONDS - HOUR) },
    { id: 'stale', t: now - (GIFTWRAP_LOOKBACK_SECONDS + DAY) },
  ];
  const kept = pruneSeen(entries, now).map((e) => e.id);
  assert.ok(kept.includes('fresh'));
  assert.ok(kept.includes('edge-in'));
  assert.ok(!kept.includes('stale'), 'stale id (outside window) is pruned');
});

test('pruneSeen: hard-caps to the newest 5000 entries', () => {
  const now = 2_000_000_000;
  const entries = [];
  for (let i = 0; i < 6000; i++) entries.push({ id: `id-${i}`, t: now - 10 });
  const kept = pruneSeen(entries, now);
  assert.equal(kept.length, 5000, 'capped at SEEN_MAX');
  assert.equal(kept[kept.length - 1].id, 'id-5999', 'keeps the newest entries');
  assert.equal(kept[0].id, 'id-1000', 'drops the oldest overflow');
});

// ---------------------------------------------------------------------------------
// 4. Drive-letter normalization: c:\ and C:\ collapse on win32; POSIX byte-identical.
// ---------------------------------------------------------------------------------
test('driveLetterNormalize: c:\\ and C:\\ collapse to one key on win32', () => {
  const lower = driveLetterNormalize('c:\\Users\\agent\\repo', 'win32');
  const upper = driveLetterNormalize('C:\\Users\\agent\\repo', 'win32');
  assert.equal(lower, upper, 'both drive-letter cases normalize to the same string');
  assert.equal(lower, 'c:\\Users\\agent\\repo', 'drive letter lower-cased, rest of path preserved');
});

test('driveLetterNormalize: POSIX path is unchanged (no-op)', () => {
  const p = '/home/vrogojin/concierge';
  assert.equal(driveLetterNormalize(p, 'linux'), p);
  assert.equal(driveLetterNormalize(p, 'darwin'), p);
  // A path that merely contains a colon is untouched on POSIX.
  assert.equal(driveLetterNormalize('/tmp/a:b', 'linux'), '/tmp/a:b');
});

test('stateDirFor: POSIX state key is byte-identical to the pre-fix sha1(resolve(path)) scheme', () => {
  // Regression guard: the running daemon must resolve the SAME state dir after this change,
  // or it loses its PID file + seen-set. Compare against the exact old formula.
  const p = '/home/vrogojin/concierge';
  const oldKey = createHash('sha1').update(resolve(p)).digest('hex').slice(0, 12);
  assert.equal(stateDirFor(p), `/tmp/claude/${oldKey}`, 'Linux state dir unchanged');
});
