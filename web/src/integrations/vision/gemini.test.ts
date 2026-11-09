// Gemini as the vision fallback (release 35, 0910): an answer in JSON is read; the free trial's quota and a model the key may
// not use answer "not read" without throwing.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { geminiVision } from './gemini.ts';

const req = { purpose: 'dash_read' as const, system: 's', prompt: 'p', imageDataUrl: 'data:image/jpeg;base64,AAAA', maxOutputTokens: 100 };
const answer = (status: number, body: unknown) => (async () => new Response(JSON.stringify(body), { status })) as unknown as typeof fetch;

test('a JSON answer is read, with the model named', async () => {
  const r = await geminiVision('k', 'gemini-test', 1000, answer(200, { candidates: [{ content: { parts: [{ text: '{"odometer": 45210, "fuel_eighths": 6}' }] } }] })).read(req, []);
  assert.equal(r.ok, true);
  if (r.ok) { assert.deepEqual(r.data, { odometer: 45210, fuel_eighths: 6 }); assert.equal(r.model, 'gemini:gemini-test'); }
});

test('the free trial quota, a model not allowed and a bad image fall back quietly', async () => {
  const q = await geminiVision('k', 'm', 1000, answer(429, {})).read(req, []);
  assert.equal(q.ok, false); if (!q.ok) assert.equal(q.reason, 'quota');
  const f = await geminiVision('k', 'm', 1000, answer(403, { error: { message: 'model not allowed' } })).read(req, []);
  assert.equal(f.ok, false); if (!f.ok) assert.equal(f.reason, 'unavailable');
  const bad = await geminiVision('k', 'm', 1000, answer(200, {})).read({ ...req, imageDataUrl: 'nope' }, []);
  assert.equal(bad.ok, false);
  const thrown = await geminiVision('k', 'm', 1000, (async () => { throw new Error('offline'); }) as unknown as typeof fetch).read(req, []);
  assert.equal(thrown.ok, false);
});
