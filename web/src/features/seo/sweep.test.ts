import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sweepWith, type SweepClaim } from './worker.ts';

// 0124: the IndexNow sweep's loop. A claim that fails is reported (so the reason is kept and the queue waits), a
// batch is sent and its answer reported with the cursor, a refusal stops the run.
const batch = (n: number, phase = 'priority'): SweepClaim => ({ key: 'k'.repeat(32), paths: Array.from({ length: n }, (_, i) => `/p${i}`), cursor: { phase, p_pos: n }, files: null });

test('sweep: each batch sent, its answer reported with the cursor, rounds bounded', async () => {
  const reports: Array<Record<string, unknown>> = [];
  const sent: number[] = [];
  const r = await sweepWith({ claim: async () => batch(3), send: async (_k, p) => { sent.push(p.length); return { status: 202 }; }, report: async (p) => { reports.push(p); } }, 2);
  assert.deepEqual(r, { sent: 6 });
  assert.deepEqual(sent, [3, 3]);
  assert.deepEqual(reports.map((x) => [x.status, x.count, (x.cursor as { phase: string }).phase]), [[202, 3, 'priority'], [202, 3, 'priority']]);
});

test('sweep: a claim that fails is reported as such (status 0, its reason), nothing sent', async () => {
  const reports: Array<Record<string, unknown>> = [];
  let sends = 0;
  const r = await sweepWith({ claim: async () => { throw new Error('canceling statement due to statement timeout'); }, send: async () => { sends++; return { status: 200 }; }, report: async (p) => { reports.push(p); } }, 3);
  assert.equal(sends, 0);
  assert.equal(r.sent, 0);
  assert.match(r.why!, /^claim: canceling statement/);
  assert.equal(reports.length, 1);
  assert.equal(reports[0]!.status, 0);
  assert.match(String(reports[0]!.error), /^claim: /);
});

test('sweep: a 429 is reported with its Retry-After and stops the run; a network error is a status 0', async () => {
  const reports: Array<Record<string, unknown>> = [];
  const r = await sweepWith({ claim: async () => batch(2), send: async () => ({ status: 429, error: 'TooManyRequests', retryAfter: 120 }), report: async (p) => { reports.push(p); } }, 5);
  assert.deepEqual(r, { sent: 0, status: 429, why: 'TooManyRequests' });
  assert.equal(reports.length, 1);
  assert.equal(reports[0]!.retry_after, 120);
  const r2 = await sweepWith({ claim: async () => batch(2), send: async () => { throw new Error('fetch failed'); }, report: async () => undefined }, 1);
  assert.equal(r2.status, 0);
});

test('sweep: nothing to send (or no key) stops without a report', async () => {
  let reports = 0;
  const r = await sweepWith({ claim: async () => ({ paths: [], why: 'nothing to send' }), send: async () => ({ status: 200 }), report: async () => { reports++; } }, 3);
  assert.deepEqual(r, { sent: 0, why: 'nothing to send' });
  assert.equal(reports, 0);
});
