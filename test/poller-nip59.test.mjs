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
// Fix under test:
//   - rolling `now - LOOKBACK` gift-wrap floor (giftwrapSince), honoring explicit --since;
//   - persistent outer-wrap-id dedup keyed on the OUTER created_at and pruned by
//     query-eligibility (seenPruneFloor/pruneSeen) — no count cap, honors NIP-59 future skew;
//   - a durable poll cursor (loadCursor/saveCursor/nextCursor) advanced ONLY on a successful
//     poll, so downtime can't skip maximally-backdated messages;
//   - drive-letter normalization (driveLetterNormalize) that is a strict no-op on POSIX.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';

import { giftwrapSince, GIFTWRAP_LOOKBACK_SECONDS } from '../lib/sphere-helper.mjs';
import {
  driveLetterNormalize, stateDirFor, loadSeen, pruneSeen, persistSeen,
  seenPruneFloor, loadCursor, saveCursor, nextCursor,
} from '../lib/sphere-daemon.mjs';

const HOUR = 3600;
const DAY = 24 * HOUR;
const MAX_BACKDATE = 2 * DAY;   // NIP-59 max backward skew (mirrors the daemon)
const MAX_FUTURE = 2 * DAY;     // NIP-59 max forward skew (mirrors the daemon)

// Faithful mirror of the daemon's dispatch()+seen bookkeeping over the pure functions:
// stamps each id with the OUTER wrap created_at (clamped to now+MAX_FUTURE), dedups on the
// outer id, and prunes by query-eligibility on every message. Used to prove no re-delivery.
function makeTracker() {
  const entries = [];
  const set = new Set();
  return {
    entries, set,
    dispatch(msg, nowSec) {
      if (msg.id && set.has(msg.id)) return false;
      const createdAt = Number.isFinite(Number(msg.wrap_created_at)) ? Number(msg.wrap_created_at) : nowSec;
      const t = Math.min(createdAt, nowSec + MAX_FUTURE);
      set.add(msg.id);
      entries.push({ id: msg.id, t });
      const pruned = pruneSeen(entries, seenPruneFloor(nowSec));
      if (pruned.length !== entries.length) {
        const keep = new Set(pruned.map((e) => e.id));
        for (const e of entries) if (!keep.has(e.id)) set.delete(e.id);
        entries.length = 0;
        for (const e of pruned) entries.push(e);
      }
      return true;
    },
  };
}

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
test('pruneSeen: keeps ids the relay can still return, drops only unreturnable ones', () => {
  const now = 2_000_000_000;
  const floor = seenPruneFloor(now); // steady-state prune floor (created_at-based)
  const entries = [
    { id: 'fresh', t: now - HOUR },
    { id: 'at-floor', t: floor },        // exactly at the floor — still relay-eligible
    { id: 'below', t: floor - HOUR },    // below the floor — can never be returned again
  ];
  const kept = pruneSeen(entries, floor).map((e) => e.id);
  assert.ok(kept.includes('fresh'));
  assert.ok(kept.includes('at-floor'));
  assert.ok(!kept.includes('below'), 'only the unreturnable id is pruned');
});

test('pruneSeen: never evicts an in-window id — no count cap (>5000 all retained)', () => {
  const now = 2_000_000_000;
  const floor = seenPruneFloor(now);
  const entries = [];
  for (let i = 0; i < 6000; i++) entries.push({ id: `id-${i}`, t: now - 10 }); // all in-window
  const kept = pruneSeen(entries, floor);
  assert.equal(kept.length, 6000, 'all 6000 in-window ids retained (the old 5000 cap is gone)');
});

test('future-stamped wrap (created_at = now + 2d): delivered once, never re-delivered across the window', () => {
  const tr = makeTracker();
  const t0 = 2_000_000_000;
  // NIP-59 can stamp the outer wrap up to +2 days. A receipt-time TTL would forget it early
  // (its "age" looks negative), then re-deliver it while the relay still returns it.
  const wrap = { id: 'future-outer-id', type: 'dm', from: 'peer', body: 'hi', wrap_created_at: t0 + 2 * DAY };
  assert.equal(tr.dispatch(wrap, t0), true, 'delivered once on first poll');
  for (const dt of [HOUR, DAY, 2 * DAY, 3 * DAY]) {
    assert.equal(tr.dispatch(wrap, t0 + dt), false, `not re-delivered at +${dt}s (still in seen-set)`);
  }
  assert.ok(tr.set.has('future-outer-id'), 'future-stamped id survives the whole window');
});

test('>5000-in-window burst: all retained, none re-delivered on the next poll', () => {
  const tr = makeTracker();
  const t0 = 2_000_000_000;
  for (let i = 0; i < 6000; i++) {
    assert.equal(tr.dispatch({ id: `b-${i}`, type: 'dm', from: 'p', body: 'x', wrap_created_at: t0 - 10 }, t0), true);
  }
  assert.equal(tr.entries.length, 6000, 'all 6000 kept (no cap evicts in-window ids)');
  let redelivered = 0;
  for (let i = 0; i < 6000; i++) {
    if (tr.dispatch({ id: `b-${i}`, wrap_created_at: t0 - 10 }, t0 + 5)) redelivered++;
  }
  assert.equal(redelivered, 0, 'no in-window id re-delivered after a >5000 burst');
});

test('cursor: persisted + loaded on restart, advanced ONLY on a successful poll', () => {
  const proj = join(tmpdir(), `poller-cursor-${process.pid}-${Date.now()}`);
  const sd = stateDirFor(proj);
  try {
    mkdirSync(sd, { recursive: true });
    assert.equal(loadCursor(proj), null, 'no cursor initially → daemon falls back to now-interval');
    saveCursor(proj, 1000);
    assert.equal(loadCursor(proj), 1000, 'cursor round-trips through disk (survives restart)');
    assert.equal(nextCursor(1000, 2000, true), 2000, 'successful poll advances the cursor to now');
    assert.equal(nextCursor(1000, 2000, false), 1000, 'FAILED poll leaves the cursor unchanged');
  } finally {
    try { rmSync(sd, { recursive: true, force: true }); } catch {}
  }
});

test('downtime: a durable cursor + backdate reach recovers a maximally-backdated message', () => {
  const now = 2_000_000_000;
  const lastSuccess = now - 5 * DAY;              // daemon was down ~5 days
  const realSend = lastSuccess + HOUR;            // a message sent just after the last success
  const wrapCreatedAt = realSend - MAX_BACKDATE;  // backdated the full 2 days

  // Daemon queries from (durable cursor − max backdate); giftwrapSince clamps the top.
  const querySince = Math.max(0, lastSuccess - MAX_BACKDATE);
  const floor = giftwrapSince(querySince, now);
  assert.ok(wrapCreatedAt >= floor, 'backdated-during-downtime wrap IS inside the recovered window');

  // Contrast: a non-durable cursor reset to ~now on restart clamps to now-LOOKBACK and MISSES it.
  const naiveFloor = giftwrapSince(now, now); // = now - LOOKBACK
  assert.ok(wrapCreatedAt < naiveFloor, 'a reset-to-now cursor would have permanently dropped it');
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
