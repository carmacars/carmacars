// Unit tests for the listing worker and the copy checks, with fake providers (no network, no Cloudflare).
//   node --test --experimental-strip-types src/features/listing/worker.test.ts   (npm run test:unit)
import { test } from 'node:test';
import { decodeImage, encodeJpeg } from './showroom.ts';
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
  assert.equal(o.preset_version, 'studio_v5');
  // r33: the model's name lettered behind a real car again, as on the sample photos (one band per model)
  assert.ok(f.pub.has('site/backdrop/lettering-v2-rav4.png'), 'the model-name band is made for a named outside view');
  assert.equal(o.lettered, true);
  assert.equal(o.mask_path, 'vehicles/v1/work/p1-mask.png');
  assert.ok(f.priv.has('vehicles/v1/work/p1-mask.png'), 'the segmenter\'s cut-out (the mask) is kept privately');
  // a cut-out that cannot be read is placed the old way, and flagged
  assert.deepEqual(o.flags, ['not_framed']);
  assert.deepEqual([o.width, o.height], [1800, 1200]);
  assert.ok(f.pub.has('vehicles/v1/2023-toyota-rav4-front-left-abcd1234.jpg'));
  assert.ok(f.priv.has('vehicles/v1/work/p1-cutout.png'), 'the cut-out stays private');
  assert.equal(calls[0], 'pub:site/backdrop/studio_v2.png|pub:site/backdrop/lettering-v2-rav4.png@348|pub:site/backdrop/shadow_v1.png|priv:vehicles/v1/work/p1-cutout.png');
  assert.deepEqual([r.units, r.unit, r.cost_microusd], [2, 'transformations', 0]);
});

// r28 (studio_v3): the cut-out framed to the car, placed at about 80% of the width on the floor line; marks left out
test('photo: a readable cut-out is framed to the car and placed big on the floor line; a flagged mark beside the car is gone', async () => {
  const { encodePng } = await import('./subject-frame.ts');
  const W = 1000, H = 650, data = new Uint8ClampedArray(W * H * 4);
  const fill = (x0: number, y0: number, x1: number, y1: number) => { for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) data[(y * W + x) * 4 + 3] = 255; };
  fill(320, 250, 680, 420); fill(850, 600, 980, 625);   // the car (a side view, 36% of the width) and a corner mark
  const png = await encodePng({ width: W, height: H, data });
  const f = files();
  const placed: Array<{ width: number; height: number; left: number; bottom: number } | null | undefined> = [];
  const photos = { ...fakePhotos(getter(f)), name: 'cloudflare-images' as const,
    cutout: async () => ({ ok: true as const, bytes: png, contentType: 'image/png', transformations: 1 }),
    composite: async (r: { place?: { width: number; height: number; left: number; bottom: number } | null }) => { placed.push(r.place); return { ok: true as const, bytes: JPEG, contentType: 'image/jpeg', transformations: 1 }; } };
  const r = await runJob(deps({ photos }, f), job('process_photo', { photo: { ...job('process_photo').photo!, watermark: true } }), budget);
  const o = r.output as Record<string, unknown>;
  assert.equal(o.preset_version, 'studio_v5');
  assert.deepEqual(o.flags, []);
  assert.equal(o.watermark_removed, true);
  assert.equal((o.framing as { dropped: number }).dropped, 1);
  const p = placed[0]!;
  assert.ok(p, 'drawn where placeSubject put it');
  assert.ok(p.width / 1800 > 0.8 && p.width / 1800 < 0.92, `the framed cut-out (car plus its shadow's spread) is ${p.width / 1800} of the width`);
  const framed = f.priv.get('vehicles/v1/work/p1-cutout.png')!;
  assert.equal(framed[0], 0x89, 'the framed cut-out is stored as the private cut-out');
});

test('photo: the touch-up (0568) is measured on the car itself, applied last and its values kept; off, nothing is applied', async () => {
  const { encodePng } = await import('./subject-frame.ts');
  const W = 1000, H = 650, data = new Uint8ClampedArray(W * H * 4);
  for (let y = 250; y < 420; y++) for (let x = 320; x < 680; x++) { const i = (y * W + x) * 4; data[i] = 40 + (x % 120); data[i + 1] = 40; data[i + 2] = 50; data[i + 3] = 255; }
  const png = await encodePng({ width: W, height: H, data });
  const run = async (enhance: boolean) => {
    const f = files();
    const applied: unknown[] = [];
    const photos = { ...fakePhotos(getter(f)), name: 'cloudflare-images' as const,
      cutout: async () => ({ ok: true as const, bytes: png, contentType: 'image/png', transformations: 1 }),
      composite: async () => ({ ok: true as const, bytes: JPEG, contentType: 'image/jpeg', transformations: 1 }),
      enhance: async (r: { values: unknown }) => { applied.push(r.values); return { ok: true as const, bytes: new Uint8Array([0xff, 0xd8, 0xff, 9]), contentType: 'image/jpeg', transformations: 1 }; } };
    const r = await runJob(deps({ photos }, f), job('process_photo', { photo: { ...job('process_photo').photo!, enhance } }), budget);
    return { r, applied, f };
  };
  const on = await run(true);
  const o = on.r.output as { enhance: Record<string, number> | null };
  assert.equal(on.applied.length, 1);
  assert.deepEqual(o.enhance, on.applied[0]);
  assert.ok((o.enhance!.saturation ?? 9) <= 1.08 && (o.enhance!.contrast ?? 9) <= 1.08);
  assert.equal(on.r.units, 3, 'cut-out, studio, touch-up: no preview for an outside photo');
  assert.deepEqual([...on.f.pub.get('vehicles/v1/2023-toyota-rav4-front-left-abcd1234.jpg')!], [0xff, 0xd8, 0xff, 9], 'the touched-up file is the public one');
  assert.ok(on.f.priv.has('vehicles/v1/work/p1-base.jpg'), 'the photo before the touch-up is kept');
  const off = await run(false);
  assert.equal(off.applied.length, 0);
  assert.equal((off.r.output as { enhance: unknown }).enhance, null);
});

test('photo: a flagged inside photo has its edge mark cut off; a mark in the middle or no model keeps it flagged', async () => {
  const inside = (over: Partial<NonNullable<JobContext['photo']>> = {}) => job('process_photo', { photo: { ...job('process_photo').photo!, rebackground: false, shot_type: 'other', angle: 'other', watermark: true, ...over } });
  const trims: unknown[] = [];
  const mk = (marks: Array<{ x: number; y: number; w: number; h: number }> | null) => {
    const f = files();
    const photos = { ...fakePhotos(getter(f)), normalize: async (r: { sourceUrl: string; trim?: unknown }) => { trims.push(r.trim ?? null); return { ok: true as const, bytes: JPEG, contentType: 'image/jpeg', transformations: 1 }; } };
    return deps({ photos, findMarks: async () => marks }, f);
  };
  const corner = await runJob(mk([{ x: 0.82, y: 0.9, w: 0.16, h: 0.07 }]), inside(), budget);
  assert.equal((corner.output as Record<string, unknown>).watermark_removed, true);
  assert.deepEqual(trims[1], { top: 0, right: 0, bottom: Math.round((1 - 0.9 + 0.015) * 1200), left: 0 }, 'the bottom band holding the corner mark is cut off');
  assert.equal(corner.units, 2);
  const middle = await runJob(mk([{ x: 0.3, y: 0.3, w: 0.4, h: 0.4 }]), inside(), budget);
  assert.equal((middle.output as Record<string, unknown>).watermark_removed, false);
  const none = await runJob(mk([]), inside(), budget);
  assert.equal((none.output as Record<string, unknown>).watermark_removed, true);
  const noModel = await runJob(mk(null), inside(), budget);
  assert.equal((noModel.output as Record<string, unknown>).watermark_removed, false);
  const unflagged = await runJob(mk([{ x: 0.82, y: 0.9, w: 0.16, h: 0.07 }]), inside({ watermark: false }), budget);
  assert.equal('watermark_removed' in (unflagged.output as Record<string, unknown>), false, 'a photo nobody flagged is not sent to the model');
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

test('photo r35 (1050): a quota never fails a photo; the original goes on the site at the site\'s size, made again later', async () => {
  const f = files();
  // a real 3000 x 2000 camera photo
  f.priv.set('vehicles/v1/original/fl.jpg', encodeJpeg({ width: 3000, height: 2000, data: new Uint8ClampedArray(3000 * 2000 * 4).fill(120) }, 80));
  const quota = { ...fakePhotos(getter(f)), cutout: async () => ({ ok: false as const, reason: 'quota' as const, retryable: true, message: 'Image transformations are rate limited' }) };
  const r = await runJob(deps({ photos: quota }, f), job('process_photo'), budget);
  const o = r.output as Record<string, unknown>;
  assert.deepEqual([r.ok, o.used_original, o.flags], [true, true, ['background_not_replaced']]);
  assert.match(String(o.fallback_reason), /^usage_paused: /, 'the usage retry makes it again once the service may be used');
  const img = await decodeImage(f.pub.get(String(o.processed_path))!);
  assert.deepEqual([img?.width, img?.height], [1800, 1200], 'downscaled here, never the camera\'s full file');
  // an outage is tried again, and on the last attempt the original is used too
  const down = { ...fakePhotos(getter(f)), cutout: async () => ({ ok: false as const, reason: 'unavailable' as const, retryable: true, message: 'down' }) };
  assert.deepEqual([(await runJob(deps({ photos: down }, f), job('process_photo'), budget)).ok], [false]);
  assert.equal((await runJob(deps({ photos: down }, f), job('process_photo', { attempts: 4 }), budget)).ok, true);
  // the allowance used: an inside photo is still made (only the cut-out waits)
  const inside = await runJob(deps({}, f), job('process_photo', { photo: { ...job('process_photo').photo!, rebackground: false, shot_type: 'dashboard', angle: 'dashboard' } }), { ...budget, images_paused: true });
  assert.equal((inside.output as Record<string, unknown>).used_original, undefined);
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
  const r = await runJob(deps({}, f), job('process_photo', { photo: { ...job('process_photo').photo!, rebackground: false, shot_type: 'trunk', angle: 'trunk' } }), budget);
  assert.deepEqual([(r.output as Record<string, unknown>).width, (r.output as Record<string, unknown>).preset_version], [1600, 'normalize_v1']);
  // 0521: a dashboard or seats photo gets its windows treated: a cut-out this check cannot read is blurred, never the studio
  const dash = await runJob(deps({}, f), job('process_photo', { photo: { ...job('process_photo').photo!, rebackground: false, shot_type: 'dashboard', angle: 'dashboard' } }), budget);
  assert.deepEqual([(dash.output as Record<string, unknown>).width, (dash.output as Record<string, unknown>).preset_version, (dash.output as Record<string, unknown>).flags], [1600, 'windows_blur_v1', ['windows_blurred']]);
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
  // studio_v3: the framed cut-out carries its shadow and is drawn at the place given
  await ok.composite({ backdropUrl: 'b', shadowUrl: 's', cutoutUrl: 'c', width: 1800, height: 1200, lettering: null, place: { width: 1500, height: 560, left: 150, bottom: 250 } });
  const v3 = seen[2]!.draw as Array<Record<string, unknown>>;
  assert.deepEqual(v3, [{ url: 'c', width: 1500, height: 560, fit: 'contain', left: 150, bottom: 250 }]);
  await ok.normalize({ sourceUrl: 'x', width: 1600, height: 1200, trim: { top: 0, right: 0, bottom: 150, left: 0 } });
  assert.deepEqual(seen[3]!.trim, { top: 0, right: 0, bottom: 150, left: 0 });
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

// r33 (0700): the lettering on the cover and the named outside views only; the cut-out editor's edit and mask jobs
test('photo r33: the model name behind the cover and the named outside views, not behind an extra outside photo', async () => {
  const { letterThis } = await import('./worker.ts');
  assert.equal(letterThis({ rebackground: true, shot_type: 'left' }), true);
  assert.equal(letterThis({ rebackground: true, shot_type: 'exterior_more' }), false);
  assert.equal(letterThis({ rebackground: true, shot_type: 'exterior_more', is_cover: true }), true, 'the cover, whatever its shot');
  assert.equal(letterThis({ rebackground: false, shot_type: 'dashboard', is_cover: true }), false, 'never behind an inside photo');
  const f = files();
  const lett: Array<string | null> = [];
  const photos = { ...fakePhotos(getter(f)), name: 'cloudflare-images' as const,
    composite: async (r: { lettering?: { url: string } | null }) => { lett.push(r.lettering?.url ?? null); return { ok: true as const, bytes: JPEG, contentType: 'image/jpeg', transformations: 1 }; },
    cutout: async () => ({ ok: true as const, bytes: new Uint8Array(20000), contentType: 'image/png', transformations: 1 }) };
  const r = await runJob(deps({ photos }, f), job('process_photo', { photo: { ...job('process_photo').photo!, shot_type: 'exterior_more', model: 'CLA-Class' } }), budget);
  assert.equal((r.output as Record<string, unknown>).lettered, false);
  assert.deepEqual(lett, [null]);
  await runJob(deps({ photos }, f), job('process_photo', { photo: { ...job('process_photo').photo!, model: 'CLA-Class' } }), budget);
  assert.equal(lett[1], 'pub:site/backdrop/lettering-v2-cla.png', 'CLA-Class is lettered CLA');
});

test('photo r33: an edit is made from the edited cut-out (no segmenter call), moved and sized; the old file is kept', async () => {
  const { encodePng } = await import('./subject-frame.ts');
  const W = 1000, H = 650, data = new Uint8ClampedArray(W * H * 4);
  for (let y = 250; y < 420; y++) for (let x = 320; x < 680; x++) data[(y * W + x) * 4 + 3] = 255;
  const png = await encodePng({ width: W, height: H, data });
  const f = files();
  f.priv.set('vehicles/v1/work/p1-edit-abc123.png', png);
  f.pub.set('vehicles/v1/2023-toyota-rav4-front-left-abcd1234.jpg', JPEG);
  let cut = 0;
  const placed: Array<{ width: number; left: number; bottom: number } | null | undefined> = [];
  const photos = { ...fakePhotos(getter(f)), name: 'cloudflare-images' as const,
    cutout: async () => { cut++; return { ok: true as const, bytes: png, contentType: 'image/png', transformations: 1 }; },
    composite: async (r: { place?: { width: number; height: number; left: number; bottom: number } | null }) => { placed.push(r.place); return { ok: true as const, bytes: JPEG, contentType: 'image/jpeg', transformations: 1 }; } };
  const base = job('process_photo').photo!;
  const plain = await runJob(deps({ photos }, f), job('process_photo', { photo: base }), budget);
  const edited = await runJob(deps({ photos }, f), job('process_photo', { input: { edit: { cutout_path: 'vehicles/v1/work/p1-edit-abc123.png', adjust: { dx: 0.05, dy: 0, scale: 0.9 } } },
    photo: { ...base, file_base: `${base.file_base}-v1` } }), budget);
  assert.equal(cut, 1, 'the edit does not call the segmenter');
  const o = edited.output as Record<string, unknown>;
  assert.equal(o.edited, true);
  assert.equal(o.processed_path, 'vehicles/v1/2023-toyota-rav4-front-left-abcd1234-v1.jpg', 'a new file name: the version before stays');
  assert.ok(f.pub.has('vehicles/v1/2023-toyota-rav4-front-left-abcd1234.jpg'));
  assert.equal('mask_path' in o, false, 'the automatic mask is not replaced by the edit');
  const [a, b] = [placed[0]!, placed[1]!];
  assert.equal(b.width, Math.round(a.width * 0.9));
  assert.ok(Math.abs((b.left + b.width / 2) - (a.left + a.width / 2 + 90)) <= 1, 'moved right by 5% of the frame');
  assert.equal(b.bottom, a.bottom, 'the wheels stay on their line');
  assert.deepEqual(o.place, { width: b.width, height: (b as { height?: number }).height, left: b.left, bottom: b.bottom });
  assert.ok((plain.output as Record<string, unknown>).place);
  // the edited cut-out gone: tried again, never the original put on the site in its place
  const lost = await runJob(deps({ photos }, f), job('process_photo', { attempts: 4, input: { edit: { cutout_path: 'vehicles/v1/work/p1-edit-gone12.png' } } }), budget);
  assert.deepEqual([lost.ok, lost.retryable], [false, false]);
  const paused = await runJob(deps({ photos }, f), job('process_photo', { input: { edit: { cutout_path: 'vehicles/v1/work/p1-edit-abc123.png' } } }), { ...budget, images_paused: true });
  // r35 (1050): an edit needs no cut-out, and the other steps are made locally: a used allowance no longer holds it
  assert.equal(paused.ok, true);
});

test('photo r33: a mask asked for by the editor is the segmenter\'s cut-out only; the photo is not made again', async () => {
  const f = files();
  const photos = { ...fakePhotos(getter(f)), name: 'cloudflare-images' as const,
    composite: async () => { throw new Error('not drawn'); },
    cutout: async () => ({ ok: true as const, bytes: new Uint8Array(20000), contentType: 'image/png', transformations: 1 }) };
  const r = await runJob(deps({ photos }, f), job('process_photo', { input: { mask_only: true } }), budget);
  assert.equal(r.ok, true);
  assert.deepEqual(r.output, { mask_only: true, mask_path: 'vehicles/v1/work/p1-mask.png' });
  assert.equal(f.pub.size, 0, 'nothing public is written');
  assert.equal(r.units, 1);
});

test('r36b (2200): the missing angle is made from the car\'s photos by the image model, or waits for it', async () => {
  const f = files();
  f.pub.set('vehicles/v1/front.jpg', JPEG);
  const angle = { id: 'a1', vehicle_id: 'v1', shot: 'rear', label: 'Rear', sources: ['vehicles/v1/front.jpg', 'vehicles/v1/missing.jpg'], prompt: 'the rear view' };
  const getPublic = async (p: string) => f.pub.get(p) ?? null;
  const none = await runJob(deps({}, f), job('angle_make', { input: { angle } }), budget);
  assert.equal((none.output as { angle: { status: string } }).angle.status, 'needs_gemini');
  let seen = 0;
  const made = await runJob(deps({ files: { ...f.api, getPublic }, angleAi: async (i) => { seen = i.images.length; assert.equal(i.prompt, 'the rear view'); return { ok: true, bytes: JPEG, contentType: 'image/jpeg', provider: 'ai' }; } }, f),
    job('angle_make', { input: { angle } }), budget);
  assert.equal(seen, 1);
  assert.deepEqual((made.output as { angle: unknown }).angle, { id: 'a1', status: 'made', path: 'vehicles/v1/generated/a1.jpg', provider: 'ai' });
  assert.ok(f.pub.has('vehicles/v1/generated/a1.jpg'));
  const limit = await runJob(deps({ files: { ...f.api, getPublic }, angleAi: async () => ({ ok: false, reason: 'limit', message: 'x' }) }, f), job('angle_make', { input: { angle } }), budget);
  assert.match(JSON.stringify(limit.output), /needs_gemini.*free daily use/);
});

test('r38 (2372): the image service refusing never fails a listing: sizes, a mask, and a photo queued without the service', async () => {
  const f = files();
  f.pub.set('vehicles/v1/a.jpg', JPEG);
  const quota = { ...fakePhotos(getter(f)), resize: async () => ({ ok: false as const, reason: 'quota' as const, retryable: true, message: 'Image transformations are rate limited or over the month\'s allowance' }),
    cutout: async () => ({ ok: false as const, reason: 'quota' as const, retryable: true, message: 'rate limited' }) };
  const sized = await runJob(deps({ photos: quota }, f), job('resize', { photo: { ...job('process_photo').photo!, processed_path: 'vehicles/v1/a.jpg' } }), budget);
  assert.deepEqual([sized.ok, (sized.output as Record<string, unknown>).variants, (sized.output as Record<string, unknown>).flags], [true, [], ['no_variants']], 'the master alone, never a failed step');
  const mask = await runJob(deps({ photos: quota }, f), job('process_photo', { input: { mask_only: true } }), budget);
  assert.deepEqual([mask.ok, (mask.output as Record<string, unknown>).mask_pending], [true, true], 'the mask is asked again later; the photo keeps its studio file');
  // queued by "Process photos without the resize service": an outage is not retried, the original goes on the site
  f.priv.set('vehicles/v1/original/fl.jpg', JPEG);
  const down = { ...fakePhotos(getter(f)), cutout: async () => ({ ok: false as const, reason: 'unavailable' as const, retryable: true, message: 'down' }) };
  const local = await runJob(deps({ photos: down }, f), job('process_photo', { input: { local_only: true } }), budget);
  assert.deepEqual([local.ok, (local.output as Record<string, unknown>).used_original], [true, true]);
});
