import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cachedCheck, guardText, guardVision, PAUSED_MESSAGE } from './guard.ts';
import type { TextGenerator } from '../llm/types.ts';
import type { VisionModel } from '../vision/types.ts';

const req = { task: 'guide_rewrite' as const, system: 's', prompt: 'p', schema: {}, maxOutputTokens: 10 };

test('a paused Workers AI is never called: the answer is quota', async () => {
  let calls = 0;
  const gen: TextGenerator = { name: 'workers-ai', model: 'm', generate: async () => { calls++; return { ok: true, data: {} as never, model: 'm', usage: { inputTokens: 1, outputTokens: 1, neurons: 1 } }; } };
  const r = await guardText(gen, async () => true).generate(req);
  assert.equal(calls, 0);
  assert.deepEqual(r, { ok: false, reason: 'quota', message: PAUSED_MESSAGE });
  const ok = await guardText(gen, async () => false).generate(req);
  assert.equal(calls, 1);
  assert.equal(ok.ok, true);
});

test('the toll and plate reader obeys the pause too', async () => {
  let calls = 0;
  const v: VisionModel = { name: 'workers-ai', read: async () => { calls++; return { ok: true, data: {}, model: 'm', usage: { inputTokens: 1, outputTokens: 1, neurons: 1 }, tried: ['m'] }; } };
  const r = await guardVision(v, async () => true).read({ system: 's', prompt: 'p', imageDataUrl: 'data:image/png;base64,', maxOutputTokens: 5, purpose: 'toll_read' }, ['m']);
  assert.equal(calls, 0);
  assert.equal(r.ok, false);
  assert.equal(!r.ok && r.reason, 'quota');
});

test('the guard is read once per 30 seconds', async () => {
  let reads = 0;
  let t = 0;
  const c = cachedCheck(async () => { reads++; return reads > 1; }, 30_000, () => t);
  assert.equal(await c(), false);
  t = 10_000;
  assert.equal(await c(), false);
  assert.equal(reads, 1);
  t = 31_000;
  assert.equal(await c(), true);
  assert.equal(reads, 2);
});
