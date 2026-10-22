// The pace of the bulk imports (0106, src/lib/import-pace.ts).
//   node --test --experimental-strip-types src/lib/import-pace.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PACE, backoffMs, beforeBatch, busyReason } from './import-pace.ts';

test('busy: sessions running, lock waits, a long statement, a slow question, no answer', () => {
  assert.equal(busyReason({ active: 1, waiting: 0, longest_ms: 200 }, 40), null);
  assert.match(busyReason({ active: PACE.maxActive }, 40)!, /sessions running/);
  assert.match(busyReason({ active: 0, waiting: 3 }, 40)!, /waiting on a lock/);
  assert.match(busyReason({ active: 0, longest_ms: 12_000 }, 40)!, /running for 12 s/);
  assert.match(busyReason({ active: 0 }, 2_000)!, /took 2000 ms/);
  assert.match(busyReason(null, 10)!, /did not answer/);
  assert.equal(busyReason({ active: 7 }, 10, { maxActive: 10 }), null, 'the limits can be set');
  assert.equal(busyReason({ active: 0 }, 2_500, { maxProbeMs: 3_000 }), null);
});

test('the wait grows to 15 s', () => {
  assert.deepEqual([0, 1, 2, 3, 4].map(backoffMs), [2_000, 4_000, 8_000, 15_000, 15_000]);
});

test('before a batch: the pause, then waits while busy, then goes on', async () => {
  let t = 0; const slept: number[] = []; const log: string[] = [];
  const answers = [{ active: 9 }, { active: 8 }, { active: 1 }];
  const r = await beforeBatch(async () => answers.shift()!, { now: () => t, sleep: async (ms) => { slept.push(ms); t += ms; }, log: (l) => log.push(l) });
  assert.deepEqual(slept, [500, 2_000, 4_000]);
  assert.deepEqual(r, { waitedMs: 6_000, busy: 2 });
  assert.equal(log.length, 2);
  assert.match(log[0]!, /9 sessions running a statement/);
});

test('a quiet database: only the pause; a failing question counts as busy; never waits past the limit', async () => {
  let t = 0; const slept: number[] = [];
  const o = { now: () => t, sleep: async (ms: number) => { slept.push(ms); t += ms; } };
  assert.deepEqual(await beforeBatch(async () => ({ active: 0 }), o), { waitedMs: 0, busy: 0 });
  assert.deepEqual(slept, [500]);
  slept.length = 0; let n = 0;
  await beforeBatch(async () => { if (n++ < 1) throw new Error('timeout'); return { active: 0 }; }, o);
  assert.deepEqual(slept, [500, 2_000]);
  slept.length = 0;
  const r = await beforeBatch(async () => ({ active: 50 }), { ...o, maxWaitMs: 30_000, pauseMs: 0 });
  assert.ok(r.waitedMs >= 30_000 && r.waitedMs < 50_000, String(r.waitedMs));
  assert.deepEqual(slept, [2_000, 4_000, 8_000, 15_000, 15_000]);
});
