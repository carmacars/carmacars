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

// ---------------------------------------------------------------- 0133: by feature, within the day's tiers
import { estimateNeurons, roomCheck, tierOf, TASK_PURPOSE, type AiRoom } from './guard.ts';

test('every purpose has its tier, as app.ai_tier in the database', () => {
  assert.equal(tierOf('staff_assistant'), 'assistant');
  for (const p of ['chat', 'phone_draft', 'phone_summary', 'toll_read', 'plate_detect', 'guide_review']) assert.equal(tierOf(p), 'live', p);
  for (const p of ['seo_car', 'seo_page', 'seo_article', 'draft_copy', 'guide_rewrite', 'turo_email', 'colour_read', 'something_new']) assert.equal(tierOf(p), 'background', p);
  assert.equal(TASK_PURPOSE.car_copy, 'seo_car');
  assert.equal(TASK_PURPOSE.listing_draft, 'draft_copy');
});

test('the estimate: the prompt and half the output a call may write, at the 70B model\'s rates', () => {
  // a guide rewrite: 16,000 characters of prompt, 4,000 output tokens: about 107 + 410 neurons
  assert.equal(estimateNeurons(16_000, 4000), 517);
  assert.equal(estimateNeurons(0, 0), 0);
});

test('a background call that does not fit its room is not made; the staff assistant\'s reserve stays', async () => {
  let reads = 0;
  const budget: AiRoom = { included: 10_000, used: 2_400, room: { assistant: 7_600, live: 600, background: 300 } };
  const r = roomCheck(async () => { reads++; return budget; }, 20_000, () => 0);
  let calls = 0;
  const gen: TextGenerator = { name: 'workers-ai', model: 'm', generate: async () => { calls++; return { ok: true, data: {} as never, model: 'm', usage: { inputTokens: 1, outputTokens: 1, neurons: 250 } }; } };
  const g = guardText(gen, r.paused, r.spent);
  // a search page: about 2,200 output tokens (225 neurons by the estimate) fits the 300 left
  const small = await g.generate({ task: 'seo_page', system: 's', prompt: 'p', schema: {}, maxOutputTokens: 2200 });
  assert.equal(small.ok, true);
  assert.equal(calls, 1);
  // 250 spent: 50 left for background; the next one waits, with the share message (Workers AI itself is not stopped)
  const next = await g.generate({ task: 'article', system: 's', prompt: 'p', schema: {}, maxOutputTokens: 3500 });
  assert.equal(next.ok, false);
  assert.equal(!next.ok && next.reason, 'quota');
  assert.match(!next.ok ? next.message : '', /share of today's free allowance/);
  assert.equal(calls, 1);
  // live chat still has room, and the assistant's reserve is untouched by background spending
  assert.equal(await r.paused({ purpose: 'chat', estimate: 100 }), false);
  assert.equal(await r.paused({ purpose: 'staff_assistant', estimate: 100 }), false);
  assert.equal(reads, 1);
});

test('the budget read again after its time; one that cannot be read does not stop anything', async () => {
  let t = 0;
  let n = 0;
  const r = roomCheck(async () => { n++; if (n === 2) throw new Error('db'); return { included: 10_000, used: 10_000, room: { assistant: 0, live: 0, background: 0 } }; }, 20_000, () => t);
  assert.equal(await r.paused(), true);
  assert.equal(await r.paused({ purpose: 'staff_assistant', estimate: 1 }), true);
  t = 25_000;
  assert.equal(await r.paused({ purpose: 'chat', estimate: 1 }), false);
});
