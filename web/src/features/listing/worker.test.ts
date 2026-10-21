// Unit tests for the listing worker and the copy checks, with fake providers (no network, no Cloudflare).
//   node --test --experimental-strip-types src/features/listing/worker.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runListingWorker, runJob, type Claim, type JobContext, type JobResult, type WorkerDeps } from './worker.ts';
import { draftProblems, normalizeDraft, systemPrompt, userPrompt, DEFAULT_RULES } from './prompt.ts';
import { fakeDraft, fakeText } from '../../integrations/llm/fake.ts';
import { fakePhotos } from '../../integrations/photos/fake.ts';
import { cloudflareImages } from '../../integrations/photos/cloudflare.ts';
import { neuronsFor, workersAi } from '../../integrations/llm/workers-ai.ts';
import type { TextGenerator } from '../../integrations/llm/types.ts';

const FACTS = { year: 2023, make: 'Toyota', model: 'RAV4', trim: 'XLE', colour: 'Grey', fuel: 'hybrid', body_style: 'SUV', seats: 5, transmission: 'automatic', doors: 4, drivetrain: 'AWD', home_area: 'Toronto' };
const budget = { ai_neurons_today: 0, ai_neurons_limit: 9000, transformations_month: 0, transformations_free: 5000 };
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, ...new Array(20000).fill(7)]);

function job(kind: JobContext['kind'], over: Partial<JobContext> = {}): JobContext {
  return { id: `${kind}-1`, kind, intake_id: 'i1', vehicle_id: 'v1', attempts: 1, max_attempts: 4, input: {}, facts: FACTS, staff_notes: 'Roof rack included', classes: ['suv', 'standard', 'premium'],
    copy_rules: { headline_chars: [40, 70], description_words: [120, 220], features: [6, 14], faq: [3, 8], banned_phrases: ['look no further'] },
    photo: { id: 'p1', shot_type: 'front_left', angle: 'front_left', original_path: 'vehicles/v1/original/fl.jpg', processed_path: null, rebackground: true, is_public: true, file_base: '2023-toyota-rav4-front-left-abcd1234' },
    ...over };
}

function files() {
  const priv = new Map<string, Uint8Array>([['vehicles/v1/original/fl.jpg', JPEG]]);
  const pub = new Map<string, Uint8Array>();
  return {
    priv, pub,
    api: {
      privateUrl: async (p: string) => `priv:${p}`,
      publicUrl: (p: string) => `pub:${p}`,
      getPrivate: async (p: string) => priv.get(p) ?? null,
      putPrivate: async (p: string, b: Uint8Array) => { priv.set(p, b); },
      putPublic: async (p: string, b: Uint8Array) => { pub.set(p, b); }
    }
  };
}
const getter = (f: ReturnType<typeof files>) => async (u: string) => (u.startsWith('priv:') ? f.priv.get(u.slice(5)) : f.pub.get(u.slice(4))) ?? null;

function deps(over: Partial<WorkerDeps> = {}, f = files()): WorkerDeps {
  return { claim: async () => ({ jobs: [], budget, held: { photos: false, copy: false }, due: 0 }), report: async () => ({}),
    decodeVin: async () => ({ provider: 'fake', result: { ok: true, year: '2023', make: 'Toyota', model: 'RAV4' } }),
    text: fakeText(), photos: fakePhotos(getter(f)), files: f.api, ...over };
}

test('the prompt carries the rules: plain English, no dashes, CarmaCars only, facts only, JSON', () => {
  const s = systemPrompt();
  for (const re of [/plain Canadian English/, /em dash/, /CarmaCars only/, /numbered company/, /Do not invent/, /JSON/]) assert.match(s, re);
  const u = userPrompt(FACTS, 'Roof rack included', ['suv'], DEFAULT_RULES, ['the headline is too short']);
  assert.match(u, /<facts>\{"year":2023/);
  assert.match(u, /<staff_notes>Roof rack included<\/staff_notes>/);
  assert.match(u, /fix every one: the headline is too short/);
});

test('the checks catch dashes, the numbered company, banned phrases, lengths and claims the facts do not support', () => {
  const good = fakeDraft(FACTS);
  assert.deepEqual(draftProblems(normalizeDraft(good)!, FACTS), []);
  const bad = normalizeDraft({ ...good, headline: 'Short — car', description: good.description + ' Operated by 18122211 Canada Inc. Look no further. It gets 6 L/100 km and has 203 hp.' })!;
  const p = draftProblems(bad, FACTS, { ...DEFAULT_RULES, banned_phrases: ['look no further'] }).join(' | ');
  assert.match(p, /headline must be 40 to 69/);
  assert.match(p, /em dash/);
  assert.match(p, /numbered or legal company/);
  assert.match(p, /look no further/);
  assert.match(p, /fuel economy/);
  assert.match(p, /horsepower/);
});

test('decode: the VIN goes to the decoder; an unreachable decoder is retried, an unknown VIN is a final answer', async () => {
  const seen: string[] = [];
  const d = deps({ decodeVin: async (v) => { seen.push(v); return { provider: 'vpic', result: { ok: true, year: '2023', make: 'Toyota', model: 'RAV4' } }; } });
  const r = await runJob(d, job('decode_vin', { vin: 'JTMB1RFV7PD000001' }), budget);
  assert.equal(r.ok, true);
  assert.equal((r.output as Record<string, unknown>).make, 'Toyota');
  assert.deepEqual(seen, ['JTMB1RFV7PD000001']);
  const down = await runJob(deps({ decodeVin: async () => ({ provider: 'vpic', result: { ok: false, error_code: 'unreachable' } }) }), job('decode_vin', { vin: 'JTMB1RFV7PD000001' }), budget);
  assert.deepEqual([down.ok, down.retryable], [false, true]);
  const bad = await runJob(d, job('decode_vin', { vin: 'NOT-A-VIN' }), budget);
  assert.deepEqual([bad.ok, (bad.output as Record<string, unknown>).error_code], [true, 'invalid_vin']);
});

test('draft: a valid draft is stored with its model, prompt version and proposed classes (only listed ones), neurons recorded', async () => {
  const r = await runJob(deps(), job('draft_copy'), budget);
  assert.equal(r.ok, true);
  const o = r.output as Record<string, unknown>;
  assert.equal(o.model, 'fake-draft-v1');
  assert.equal(o.prompt_version, 'listing-draft-v1');
  assert.deepEqual(o.classes, ['suv']);
  assert.deepEqual(o.problems, []);
  assert.equal(r.unit, 'neurons');
});

test('draft: a rule-breaking answer is rewritten once with the problems listed, then stored as it is', async () => {
  const prompts: string[] = [];
  const bad: TextGenerator = { name: 'workers-ai', model: 'm', async generate<T>(req: { prompt: string }) {
    prompts.push(req.prompt);
    return { ok: true as const, data: { ...fakeDraft(FACTS), headline: 'Too short — yes' } as T, model: 'm', usage: { inputTokens: 2500, outputTokens: 900, neurons: 251 } }; } };
  const r = await runJob(deps({ text: bad }), job('draft_copy'), budget);
  assert.equal(prompts.length, 2);
  assert.match(prompts[1]!, /fix every one: .*headline/);
  assert.equal(r.ok, true);
  assert.ok(((r.output as Record<string, unknown>).problems as string[]).length > 0);
  assert.equal(r.units, 502);
  assert.equal(r.cost_microusd, 0, 'within the free daily neurons it costs nothing');
});

test('draft: above the free daily neurons the paid rate is recorded; a model outage is retried', async () => {
  const pricey: TextGenerator = { name: 'workers-ai', model: 'm', async generate<T>() { return { ok: true as const, data: fakeDraft(FACTS) as T, model: 'm', usage: { inputTokens: 1, outputTokens: 1, neurons: 300 } }; } };
  const r = await runJob(deps({ text: pricey }), job('draft_copy'), { ...budget, ai_neurons_today: 9900 });
  assert.equal(r.cost_microusd, 200 * 11);
  const down: TextGenerator = { name: 'workers-ai', model: 'm', async generate() { return { ok: false as const, reason: 'unavailable' as const, message: '5xx' }; } };
  const f = await runJob(deps({ text: down }), job('draft_copy'), budget);
  assert.deepEqual([f.ok, f.retryable], [false, true]);
});

test('Workers AI: JSON mode on the instruct model through the binding; neurons from the token counts', async () => {
  const calls: Array<{ model: string; input: Record<string, unknown> }> = [];
  const ai = { async run(model: string, input: Record<string, unknown>) { calls.push({ model, input }); return { response: JSON.stringify(fakeDraft(FACTS)), usage: { prompt_tokens: 2500, completion_tokens: 900 } }; } };
  const t = workersAi(ai);
  const r = await t.generate({ task: 'listing_draft', system: 's', prompt: 'p', schema: { type: 'object' }, maxOutputTokens: 1400 });
  assert.equal(r.ok, true);
  assert.equal(calls[0]!.model, '@cf/meta/llama-3.3-70b-instruct-fp8-fast');
  assert.deepEqual((calls[0]!.input.response_format as Record<string, unknown>).type, 'json_schema');
  assert.equal(r.ok && r.usage.neurons, neuronsFor('@cf/meta/llama-3.3-70b-instruct-fp8-fast', 2500, 900));
  const quota = workersAi({ async run() { throw new Error('4006: you have used up your daily free allocation of 10,000 neurons'); } });
  const q = await quota.generate({ task: 'listing_draft', system: 's', prompt: 'p', schema: {}, maxOutputTokens: 10 });
  assert.deepEqual([q.ok, !q.ok && q.reason], [false, 'quota']);
  const junk = workersAi({ async run() { return { response: 'Sure! Here is your listing.' }; } });
  const jr = await junk.generate({ task: 'listing_draft', system: 's', prompt: 'p', schema: {}, maxOutputTokens: 10 });
  assert.deepEqual([jr.ok, !jr.ok && jr.reason], [false, 'invalid_output']);
});

test('photo: an exterior is cut out, placed on the backdrop with the shadow, stored public under its SEO name', async () => {
  const f = files();
  const calls: string[] = [];
  const photos = { ...fakePhotos(getter(f)), name: 'cloudflare-images' as const,
    composite: async (r: { backdropUrl: string; shadowUrl: string; cutoutUrl: string; lettering?: { url: string; top: number } | null }) => { calls.push(`${r.backdropUrl}|${r.lettering?.url ?? '-'}@${r.lettering?.top ?? '-'}|${r.shadowUrl}|${r.cutoutUrl}`); return { ok: true as const, bytes: JPEG, contentType: 'image/jpeg', transformations: 1 }; },
    cutout: async () => ({ ok: true as const, bytes: new Uint8Array(20000), contentType: 'image/png', transformations: 1 }) };
  const r = await runJob(deps({ photos }, f), job('process_photo', { photo: { ...job('process_photo').photo!, model: 'RAV4' } }), budget);
  assert.equal(r.ok, true);
  const o = r.output as Record<string, unknown>;
  assert.equal(o.processed_path, 'vehicles/v1/2023-toyota-rav4-front-left-abcd1234.jpg');
  assert.equal(o.preset_version, 'studio_v2');
  const band = f.pub.get('site/backdrop/lettering-v1-rav4.png');
  assert.ok(band && band[0] === 0x89 && band[1] === 0x50, 'the model-name band is a PNG in the public bucket');
  assert.deepEqual([o.width, o.height], [1800, 1200]);
  assert.ok(f.pub.has('vehicles/v1/2023-toyota-rav4-front-left-abcd1234.jpg'));
  assert.ok(f.priv.has('vehicles/v1/work/p1-cutout.png'), 'the cut-out stays private');
  assert.equal(calls[0], 'pub:site/backdrop/studio_v2.png|pub:site/backdrop/lettering-v1-rav4.png@348|pub:site/backdrop/shadow_v1.png|priv:vehicles/v1/work/p1-cutout.png');
  assert.deepEqual([r.units, r.unit, r.cost_microusd], [2, 'transformations', 0]);
});

test('photo fallback: transformations not enabled on the zone keeps the original on the site and flags it for staff', async () => {
  const f = files();
  const r = await runJob(deps({ photos: fakePhotos(getter(f), 'not_enabled') }, f), job('process_photo'), budget);
  assert.equal(r.ok, true);
  const o = r.output as Record<string, unknown>;
  assert.equal(o.used_original, true);
  assert.deepEqual(o.flags, ['background_not_replaced']);
  assert.ok(f.pub.has(String(o.processed_path)));
  assert.equal(r.provider, 'fake:fallback');
});

test('photo: no car found is flagged as a bad cut-out; a provider outage is retried, not a fallback', async () => {
  const f = files();
  const none = { ...fakePhotos(getter(f)), cutout: async () => ({ ok: false as const, reason: 'no_subject' as const, retryable: false, message: 'No car' }) };
  const r = await runJob(deps({ photos: none }, f), job('process_photo'), budget);
  assert.deepEqual((r.output as Record<string, unknown>).flags, ['bad_cutout']);
  const down = { ...fakePhotos(getter(f)), cutout: async () => ({ ok: false as const, reason: 'unavailable' as const, retryable: true, message: '502' }) };
  const r2 = await runJob(deps({ photos: down }, f), job('process_photo'), budget);
  assert.deepEqual([r2.ok, r2.retryable], [false, true]);
});

test('photo: interiors are normalized (no backdrop); the odometer is never published', async () => {
  const f = files();
  const r = await runJob(deps({}, f), job('process_photo', { photo: { ...job('process_photo').photo!, rebackground: false, shot_type: 'dashboard' } }), budget);
  assert.deepEqual([(r.output as Record<string, unknown>).width, (r.output as Record<string, unknown>).preset_version], [1600, 'normalize_v1']);
  const odo = await runJob(deps({}, f), job('process_photo', { photo: { ...job('process_photo').photo!, is_public: false, shot_type: 'odometer' } }), budget);
  assert.deepEqual([odo.ok, (odo.output as Record<string, unknown>).used_original, (odo.output as Record<string, unknown>).processed_path], [true, true, undefined]);
});

test('resize: the site sizes as WebP next to the master; without transformations the master stands alone', async () => {
  const f = files();
  f.pub.set('vehicles/v1/a.jpg', JPEG);
  const r = await runJob(deps({}, f), job('resize', { photo: { ...job('process_photo').photo!, processed_path: 'vehicles/v1/a.jpg', file_base: 'a' } }), budget);
  assert.deepEqual((r.output as { variants: { width: number; path: string }[] }).variants.map((v) => `${v.width}:${v.path}`), ['480:vehicles/v1/a-480.webp', '800:vehicles/v1/a-800.webp', '1200:vehicles/v1/a-1200.webp']);
  const off = await runJob(deps({ photos: fakePhotos(getter(f), 'not_enabled') }, f), job('resize', { photo: { ...job('process_photo').photo!, processed_path: 'vehicles/v1/a.jpg' } }), budget);
  assert.deepEqual([off.ok, (off.output as Record<string, unknown>).variants], [true, []]);
});

test('cloudflare adapter: segment=foreground as a PNG; an untouched JPEG back means transformations are off', async () => {
  const seen: Array<Record<string, unknown>> = [];
  const ok = cloudflareImages(async (_u, init) => { seen.push((init.cf as { image: Record<string, unknown> }).image); return new Response(new Uint8Array(30000), { headers: { 'content-type': 'image/png' } }); });
  const c = await ok.cutout('https://x/o.jpg');
  assert.equal(c.ok, true);
  assert.equal(seen[0]!.segment, 'foreground');
  assert.equal(seen[0]!.format, 'png');
  await ok.composite({ backdropUrl: 'b', shadowUrl: 's', cutoutUrl: 'c', width: 1800, height: 1200, lettering: { url: 'l', top: 348, width: 1800 } });
  const draw = seen[1]!.draw as Array<Record<string, unknown>>;
  assert.deepEqual(draw.map((x) => x.url), ['l', 's', 'c'], 'the lettering behind, then the shadow, the car on top');
  assert.deepEqual([draw[0]!.top, draw[2]!.bottom], [348, 300], 'lettering and floor line where the sample cars have them');
  const off = cloudflareImages(async () => new Response(new Uint8Array(30000), { headers: { 'content-type': 'image/jpeg' } }));
  const r = await off.cutout('https://x/o.jpg');
  assert.deepEqual([r.ok, !r.ok && r.reason, !r.ok && r.retryable], [false, 'not_enabled', false]);
  const busy = cloudflareImages(async () => new Response('x', { status: 503 }));
  const b = await busy.resize({ sourceUrl: 'x', width: 480 });
  assert.deepEqual([b.ok, !b.ok && b.retryable], [false, true]);
});

test('the run: claims in batches, reports every job, stops when the queue is empty or the time is up', async () => {
  const queue: JobContext[] = [job('decode_vin', { id: 'a', vin: 'JTMB1RFV7PD000001' }), job('draft_copy', { id: 'b' }), job('publish', { id: 'c' })];
  const reported: Array<[string, JobResult]> = [];
  const d = deps({
    claim: async (n): Promise<Claim> => ({ jobs: queue.splice(0, n), budget, held: { photos: false, copy: false }, due: queue.length }),
    report: async (id, r) => { reported.push([id, r]); }
  });
  const s = await runListingWorker(d, { batch: 2 });
  assert.deepEqual([s.claimed, s.succeeded, s.failed], [3, 3, 0]);
  assert.deepEqual(reported.map(([id]) => id).sort(), ['a', 'b', 'c']);
  let t = 0;
  const slow = deps({ claim: async () => ({ jobs: [job('publish')], budget, held: { photos: false, copy: false }, due: 1 }), now: () => (t += 10_000) });
  const s2 = await runListingWorker(slow, { deadlineMs: 25_000, maxJobs: 100 });
  assert.ok(s2.claimed <= 2, 'stops at the deadline');
});

test('the run: a job that throws is reported as a retryable failure, not lost', async () => {
  const reported: JobResult[] = [];
  const queue = [job('decode_vin', { vin: 'JTMB1RFV7PD000001' })];
  const d = deps({ claim: async () => ({ jobs: queue.splice(0), budget, held: { photos: false, copy: false }, due: 0 }), report: async (_id, r) => { reported.push(r); },
    decodeVin: async () => { throw new Error('boom'); } });
  const s = await runListingWorker(d);
  assert.equal(s.failed, 1);
  assert.deepEqual([reported[0]!.ok, reported[0]!.retryable, reported[0]!.error], [false, true, 'boom']);
});
