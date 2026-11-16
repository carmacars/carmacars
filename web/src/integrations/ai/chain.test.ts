import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cachedRoutes, chainText, chainTranscriber, chainVision, providerOrder, type Provider, type Route, type Served } from './chain.ts';
import { guardText } from './guard.ts';
import { formatFor, localReady, ollamaChat } from './ollama.ts';
import { localText } from '../llm/local.ts';
import { localVision } from '../vision/local.ts';
import { localTranscriber } from '../transcribe/local.ts';
import { chainModels, localModel } from '../../features/assistant/models.ts';
import type { GenerateResult, TextGenerator } from '../llm/types.ts';
import type { VisionModel, VisionResult } from '../vision/types.ts';
import type { Transcriber, TranscribeResult } from '../transcribe/types.ts';
import type { AssistantModel, ModelResult } from '../../features/assistant/agent.ts';

// r48 part AI (3095): the chain with stand-in providers: the order per route, a failure handed on, private features never
// at Gemini, every call recorded with its provider; the local adapters against a stand-in of Ollama and whisper.cpp.

const usage = { inputTokens: 1, outputTokens: 1, neurons: 0 };
const text = (name: TextGenerator['name'], r: GenerateResult<unknown>, calls: string[]): TextGenerator =>
  ({ name, model: name, generate: async <T>() => { calls.push(name); return r as GenerateResult<T>; } });
const okText = (m: string): GenerateResult<unknown> => ({ ok: true, data: { from: m }, model: m, usage });
const fail = (reason: 'quota' | 'unavailable' | 'timeout' | 'invalid_output', message: string = reason) => ({ ok: false as const, reason, message });
const deps = (route: Route = 'auto') => { const served: Served[] = []; return { served, d: { route: async () => route, served: (s: Served) => served.push(s), now: () => 0 } }; };
const chatReq = { task: 'chat' as const, system: 's', prompt: 'p', schema: {}, maxOutputTokens: 10 };
const summaryReq = { ...chatReq, task: 'phone_summary' as const };

test('the order: Workers AI, the server, Gemini; a private feature never reaches Gemini', () => {
  assert.deepEqual(providerOrder('auto', 'chat'), ['workers_ai', 'local', 'gemini']);
  assert.deepEqual(providerOrder(undefined, 'chat'), ['workers_ai', 'local', 'gemini']);
  assert.deepEqual(providerOrder('local_first', 'seo_car'), ['local', 'workers_ai', 'gemini']);
  assert.deepEqual(providerOrder('no_gemini', 'chat'), ['workers_ai', 'local']);
  assert.deepEqual(providerOrder('workers_ai_only', 'chat'), ['workers_ai']);
  assert.deepEqual(providerOrder('local_only', 'chat'), ['local']);
  for (const p of ['licence_read', 'permit_read', 'interview_transcribe', 'call_transcribe', 'phone_summary', 'interview_followup', 'interview_score']) {
    assert.ok(!providerOrder('auto', p).includes('gemini'), p);
    assert.ok(!providerOrder('local_first', p).includes('gemini'), p);
  }
});

test('Workers AI answers: nothing else is asked, the call is recorded as Workers AI', async () => {
  const calls: string[] = [];
  const { served, d } = deps();
  const g = chainText({ workers_ai: text('workers-ai', okText('@cf/x'), calls), local: text('local', okText('local:q'), calls), gemini: text('gemini', okText('gemini:f'), calls) }, d);
  const r = await g.generate(chatReq);
  assert.equal(r.ok && r.model, '@cf/x');
  assert.deepEqual(calls, ['workers-ai']);
  assert.deepEqual(served.map((s) => [s.purpose, s.provider, s.ok]), [['chat', 'workers_ai', true]]);
});

test('Workers AI over its allowance (the guard): the server\'s model answers, never billed', async () => {
  const calls: string[] = [];
  const { served, d } = deps();
  const guarded = guardText(text('workers-ai', okText('@cf/x'), calls), async () => true);
  const g = chainText({ workers_ai: guarded, local: text('local', okText('local:q'), calls), gemini: text('gemini', okText('gemini:f'), calls) }, d);
  const r = await g.generate(chatReq);
  assert.equal(r.ok && r.model, 'local:q');
  assert.deepEqual(calls, ['local'], 'the paused Workers AI is never called');
  assert.deepEqual(served.map((s) => [s.provider, s.ok, s.reason]), [['workers_ai', false, 'quota'], ['local', true, null]]);
});

test('the server warming up and Workers AI out: Gemini for chat, never for a call summary', async () => {
  const calls: string[] = [];
  const links = () => ({ workers_ai: text('workers-ai', fail('quota'), calls), local: text('local', fail('unavailable', 'warming up'), calls), gemini: text('gemini', okText('gemini:f'), calls) });
  const a = await chainText(links(), deps().d).generate(chatReq);
  assert.equal(a.ok && a.model, 'gemini:f');
  calls.length = 0;
  const { served, d } = deps();
  const b = await chainText(links(), d).generate(summaryReq);
  assert.deepEqual(calls, ['workers-ai', 'local']);
  assert.equal(b.ok, false);
  assert.equal(!b.ok && b.reason, 'quota', 'the quota answer wins: the caller waits for the allowance, nothing is counted');
  assert.ok(!served.some((s) => s.provider === 'gemini'));
});

test('a route set by an Admin: local first, Workers AI only', async () => {
  const calls: string[] = [];
  const links = () => ({ workers_ai: text('workers-ai', okText('@cf/x'), calls), local: text('local', okText('local:q'), calls) });
  assert.equal((await chainText(links(), deps('local_first').d).generate(chatReq)).ok, true);
  assert.deepEqual(calls, ['local']);
  calls.length = 0;
  const only = { workers_ai: text('workers-ai', fail('timeout'), calls), local: text('local', okText('local:q'), calls) };
  const r = await chainText(only, deps('workers_ai_only').d).generate(chatReq);
  assert.equal(!r.ok && r.reason, 'timeout');
  assert.deepEqual(calls, ['workers-ai']);
});

test('no provider at all: unavailable, recorded as none', async () => {
  const { served, d } = deps();
  const r = await chainText({}, d).generate(chatReq);
  assert.equal(!r.ok && r.reason, 'unavailable');
  assert.deepEqual(served.map((s) => s.provider), ['none']);
});

test('vision: a licence is read by Workers AI or the server, never Gemini; a car photo may go to Gemini', async () => {
  const calls: string[] = [];
  const v = (name: VisionModel['name'], r: VisionResult): VisionModel => ({ name, read: async () => { calls.push(name); return r; } });
  const no: VisionResult = { ok: false, reason: 'quota', message: 'q', tried: ['@cf/v'] };
  const down: VisionResult = { ok: false, reason: 'unavailable', message: 'warming up', tried: ['local:vl'] };
  const yes: VisionResult = { ok: true, data: { plate: 'x' }, model: 'gemini:f', usage, tried: ['gemini:f'] };
  const links = { workers_ai: v('workers-ai', no), local: v('local', down), gemini: v('gemini', yes) };
  const req = { system: 's', prompt: 'p', imageDataUrl: 'data:image/jpeg;base64,AA', maxOutputTokens: 5 };
  const lic = await chainVision(links, deps().d).read({ ...req, purpose: 'licence_read' }, ['@cf/v']);
  assert.equal(lic.ok, false);
  assert.deepEqual(calls, ['workers-ai', 'local']);
  calls.length = 0;
  const plate = await chainVision(links, deps().d).read({ ...req, purpose: 'plate_detect' }, ['@cf/v']);
  assert.equal(plate.ok, true);
  assert.deepEqual(plate.tried, ['@cf/v', 'local:vl', 'gemini:f']);
});

test('speech: Workers AI, then the server\'s whisper; never Gemini even if given', async () => {
  const calls: string[] = [];
  const t = (name: Transcriber['name'], r: TranscribeResult): Transcriber => ({ name, transcribe: async () => { calls.push(name); return r; } });
  const { served, d } = deps();
  const tr = chainTranscriber({ workers_ai: t('workers-ai', { ok: false, reason: 'quota', message: 'q' }), local: t('local', { ok: true, text: 'hello', model: 'local:whisper', neurons: 0 }),
    gemini: t('fake', { ok: true, text: 'leak', model: 'g', neurons: 0 }) } as Partial<Record<Provider, Transcriber>>, d, 'call_transcribe');
  const r = await tr.transcribe({ audio: new Uint8Array(4), type: 'audio/mpeg', seconds: 30 });
  assert.equal(r.ok && r.text, 'hello');
  assert.deepEqual(calls, ['workers-ai', 'local']);
  assert.deepEqual(served.map((s) => [s.purpose, s.provider]), [['call_transcribe', 'workers_ai'], ['call_transcribe', 'local']]);
});

test('a provider that throws is a failure handed on; the record never stops a call', async () => {
  const boom: TextGenerator = { name: 'workers-ai', model: 'x', generate: async () => { throw new Error('socket'); } };
  const r = await chainText({ workers_ai: boom, local: text('local', okText('local:q'), []) }, { route: async () => 'auto', served: () => { throw new Error('db down'); } }).generate(chatReq);
  assert.equal(r.ok && r.model, 'local:q');
});

test('routes are read once a minute; an unknown or unreadable route is auto', async () => {
  let reads = 0, t = 0;
  const r = cachedRoutes(async () => { reads++; return { chat: 'local_first', seo_car: 'bogus' }; }, 60_000, () => t);
  assert.equal(await r('chat'), 'local_first');
  assert.equal(await r('seo_car'), 'auto');
  assert.equal(await r('vin_read'), 'auto');
  assert.equal(reads, 1);
  t = 61_000;
  await r('chat');
  assert.equal(reads, 2);
  assert.equal(await cachedRoutes(async () => { throw new Error('no db'); })('chat'), 'auto');
});

// ------------------------------------------------------------------ the local adapters against stand-ins
type Seen = { url: string; body: Record<string, unknown> | FormData | null };
function ollama(answer: (body: Record<string, unknown>) => { status?: number; json: unknown }, seen: Seen[] = []): typeof fetch {
  return (async (u: string | URL, init?: RequestInit) => {
    const body = init?.body instanceof FormData ? init.body : init?.body ? JSON.parse(String(init.body)) : null;
    seen.push({ url: String(u), body });
    const a = answer(body ?? {});
    return new Response(JSON.stringify(a.json), { status: a.status ?? 200, headers: { 'content-type': 'application/json' } });
  }) as typeof fetch;
}

test('local text: Ollama\'s chat with the schema, JSON read back, no neurons, a floor on the timeout', async () => {
  const seen: Seen[] = [];
  const f = ollama(() => ({ json: { message: { content: '```json\n{"reply":"Hi"}\n```' }, prompt_eval_count: 40, eval_count: 5 } }), seen);
  const g = localText('http://llm:11434/', 'qwen2.5:3b', 12_000, f);
  const schema = { type: 'object', properties: { reply: { type: 'string' } } };
  const r = await g.generate<{ reply: string }>({ ...chatReq, schema });
  assert.equal(r.ok && r.data.reply, 'Hi');
  assert.equal(r.ok && r.model, 'local:qwen2.5:3b');
  assert.deepEqual(r.ok && r.usage, { inputTokens: 40, outputTokens: 5, neurons: 0 });
  const b = seen[0]!.body as Record<string, unknown>;
  assert.equal(seen[0]!.url, 'http://llm:11434/api/chat');
  assert.deepEqual(b.format, schema);
  assert.equal(b.stream, false);
  assert.equal((b.options as Record<string, unknown>).num_predict, 10);
  assert.equal(formatFor({ type: 'object' }), 'json');
});

test('local text: a model not pulled yet is warming up (unavailable); a refused schema is asked in JSON mode', async () => {
  const missing = await localText('http://llm', 'qwen2.5:3b', 0, ollama(() => ({ status: 404, json: { error: 'model "qwen2.5:3b" not found, try pulling it first' } }))).generate(chatReq);
  assert.equal(!missing.ok && missing.reason, 'unavailable');
  assert.match(!missing.ok ? missing.message : '', /warming up/);
  const formats: unknown[] = [];
  const f = ollama((b) => { formats.push(b.format); return b.format === 'json' ? { json: { message: { content: '{"a":1}' } } } : { status: 400, json: { error: 'invalid schema' } }; });
  const r = await localText('http://llm', 'm', 0, f).generate({ ...chatReq, schema: { type: 'object', properties: { a: { type: 'number' } } } });
  assert.equal(r.ok, true);
  assert.equal(formats.length, 2);
  assert.equal(formats[1], 'json');
  const down = await ollamaChat('http://llm', 'm', { system: 's', user: 'u', format: 'json', maxTokens: 5, temperature: 0 }, 1000, (async () => { throw new TypeError('fetch failed'); }) as typeof fetch);
  assert.equal(!down.ok && down.reason, 'unavailable');
});

test('local vision: the image goes as base64 (made smaller first), JSON back', async () => {
  const seen: Seen[] = [];
  const v = localVision('http://llm', 'qwen2.5vl:3b', { fetch: ollama(() => ({ json: { message: { content: 'Answer: {"plate_visible": true}' } } }), seen), shrink: async () => 'data:image/jpeg;base64,U01BTEw=' });
  const r = await v.read({ purpose: 'plate_detect', system: 's', prompt: 'p', imageDataUrl: 'data:image/jpeg;base64,QklH', maxOutputTokens: 50 }, ['@cf/ignored']);
  assert.equal(r.ok, true);
  assert.deepEqual(r.ok && r.data, { plate_visible: true });
  const msgs = (seen[0]!.body as { messages: Array<{ images?: string[] }> }).messages;
  assert.deepEqual(msgs[1]!.images, ['U01BTEw=']);
});

test('local speech: whisper.cpp\'s /inference with the file, the text back; warming up is unavailable', async () => {
  const seen: Seen[] = [];
  const t = localTranscriber('http://stt:8080', ollama(() => ({ json: { text: '  Hello,   is the car free  ' } }), seen));
  const r = await t.transcribe({ audio: new Uint8Array([1, 2, 3]), type: 'audio/webm;codecs=opus', seconds: 12 });
  assert.equal(r.ok && r.text, 'Hello, is the car free');
  assert.equal(r.ok && r.neurons, 0);
  assert.equal(seen[0]!.url, 'http://stt:8080/inference');
  const form = seen[0]!.body as FormData;
  assert.equal(form.get('language'), 'en');
  assert.equal((form.get('file') as File).name, 'audio.webm');
  const warm = await localTranscriber('http://stt', ollama(() => ({ status: 503, json: { error: 'loading model' } }))).transcribe({ audio: new Uint8Array(1), type: 'audio/mpeg', seconds: 1 });
  assert.equal(!warm.ok && warm.reason, 'unavailable');
});

test('readiness: a model with another digest is not ready; the speech server listening is', async () => {
  const f = (async (u: string | URL) => {
    if (String(u).endsWith('/api/tags')) return new Response(JSON.stringify({ models: [{ name: 'qwen2.5:3b', digest: '357c53fb659c1234' }, { name: 'qwen2.5vl:3b', digest: 'ffffffffffff' }] }));
    return new Response('not found', { status: 404 });
  }) as typeof fetch;
  const r = await localReady({ llmUrl: 'http://llm', sttUrl: 'http://stt', textModel: 'qwen2.5:3b', visionModel: 'qwen2.5vl:3b', textDigest: '357c53fb659c', visionDigest: 'fb90415cde1e' }, f);
  assert.equal(r.text, true);
  assert.equal(r.vision, false);
  assert.equal(r.stt, true);
  assert.match(r.detail, /vision model qwen2.5vl:3b warming up/);
  const none = await localReady({ llmUrl: 'http://llm', textModel: 'qwen2.5:3b' }, (async () => { throw new TypeError('refused'); }) as typeof fetch);
  assert.equal(none.text, false);
  assert.match(none.detail, /not reachable/);
});

test('the staff assistant: Workers AI out, the local model takes the step; each step recorded', async () => {
  const step = (name: AssistantModel['name'], service: AssistantModel['service'], r: ModelResult): AssistantModel => ({ name, service, step: async () => r });
  const served: string[] = [];
  const local = localModel('http://llm', 'qwen2.5:3b', { fetch: ollama(() => ({ json: { message: { content: '{"action":"reply","reply":"3 pickups today"}' } } })) });
  const m = chainModels([step('workers-ai', 'workers_ai', { ok: false, reason: 'quota', message: 'used' }), local], (s) => served.push(`${s.provider}:${s.ok}`));
  const r = await m.step('system', [{ role: 'user', text: 'what is on today?' }], []);
  assert.equal(r.ok && r.step.action, 'reply');
  assert.equal(r.ok && r.model, 'local:qwen2.5:3b');
  assert.deepEqual(r.ok && r.usage, { units: 0, unit: 'neurons' });
  assert.deepEqual(served, ['workers_ai:false', 'local:true']);
  const both = chainModels([step('workers-ai', 'workers_ai', { ok: false, reason: 'quota', message: 'used' }), step('local', 'local', { ok: false, reason: 'unavailable', message: 'warming' })]);
  const q = await both.step('s', [], []);
  assert.equal(!q.ok && q.reason, 'quota');
});
