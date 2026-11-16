// r48 (3070): Gemini stands in for Workers AI on the company's server when no Workers AI token is set.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { geminiText, geminiModelFor, GEMINI_TEXT_DEFAULT } from './gemini.ts';

const req = { task: 'chat' as const, system: 's', prompt: 'p', schema: { type: 'object' }, maxOutputTokens: 50 };
const answer = (status: number, body: unknown, seen?: { body?: unknown }) => (async (_u: unknown, init?: RequestInit) => {
  if (seen) seen.body = JSON.parse(String(init?.body));
  return new Response(JSON.stringify(body), { status });
}) as unknown as typeof fetch;

test('a JSON answer is read, with the schema asked for in the system text', async () => {
  const seen: { body?: unknown } = {};
  const r = await geminiText('k', 'g-test', 1000, answer(200, { candidates: [{ content: { parts: [{ text: '```json\n{"reply":"hi"}\n```' }] } }], usageMetadata: { promptTokenCount: 7, candidatesTokenCount: 3 } }, seen)).generate<{ reply: string }>(req);
  assert.equal(r.ok, true);
  if (r.ok) { assert.equal(r.data.reply, 'hi'); assert.equal(r.model, 'gemini:g-test'); assert.equal(r.usage.inputTokens, 7); assert.equal(r.usage.neurons, 0); }
  const b = seen.body as { systemInstruction: { parts: Array<{ text: string }> }; generationConfig: { responseMimeType: string } };
  assert.match(b.systemInstruction.parts[0]!.text, /"type":"object"/);
  assert.equal(b.generationConfig.responseMimeType, 'application/json');
});

test('a quota, a refusal and prose answer a failed result, never a throw', async () => {
  const q = await geminiText('k', 'm', 1000, answer(429, {})).generate(req);
  assert.equal(q.ok, false); if (!q.ok) assert.equal(q.reason, 'quota');
  const f = await geminiText('k', 'm', 1000, answer(403, { error: { message: 'no' } })).generate(req);
  assert.equal(f.ok, false); if (!f.ok) assert.equal(f.reason, 'unavailable');
  const p = await geminiText('k', 'm', 1000, answer(200, { candidates: [{ content: { parts: [{ text: 'sorry' }] } }] })).generate(req);
  assert.equal(p.ok, false); if (!p.ok) assert.equal(p.reason, 'invalid_output');
});

test('a Workers AI model name is never sent to Gemini', () => {
  assert.equal(geminiModelFor('@cf/meta/llama-3.3-70b-instruct-fp8-fast'), GEMINI_TEXT_DEFAULT);
  assert.equal(geminiModelFor(undefined, 'x-model'), 'x-model');
  assert.equal(geminiModelFor('gemini-2.5-pro'), 'gemini-2.5-pro');
  assert.equal(geminiModelFor('../evil'), GEMINI_TEXT_DEFAULT);
});
