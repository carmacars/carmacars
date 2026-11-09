// Unit tests for the showroom scene (release 35, 0990): the free local composite and the provider fallback (no network:
// the image model's fetch is a fake).
//   node --test --experimental-strip-types src/features/listing/showroom.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FALLBACK_TEXT, ROOM, SHOWROOM_PRESET, composeShowroom, decodeImage, fitFrame, localShowroom, makeShowroom, sceneOf, showroomBackdrop, showroomPrompt,
  type ShowroomProvider } from './showroom.ts';
import { encodePng, type Rgba } from './subject-frame.ts';
import { geminiEditImage, GEMINI_DEFAULT_MODEL } from '../../integrations/photos/gemini.ts';
import { runJob, type JobContext, type WorkerDeps } from './worker.ts';
import { fakePhotos } from '../../integrations/photos/fake.ts';
import { fakeText } from '../../integrations/llm/fake.ts';

const lum = (img: Rgba, x: number, y: number) => { const i = (y * img.width + x) * 4; return (img.data[i]! + img.data[i + 1]! + img.data[i + 2]!) / 3; };
const mean = (img: Rgba, y0: number, y1: number, x0 = 0, x1 = img.width) => { let s = 0, n = 0; for (let y = y0; y < y1; y += 3) for (let x = x0; x < x1; x += 3) { s += lum(img, x, y); n++; } return s / n; };

/** A stand-in car: a red body over a dark contact shadow (the bottom fifth), as frameRgba gives it. */
function car(w = 600, h = 250): Rgba & { ground: number } {
  const data = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const i = (y * w + x) * 4;
    if (y < h * 0.8) { data[i] = 200; data[i + 1] = 30; data[i + 2] = 30; data[i + 3] = 255; } else { data[i + 3] = 90; }
  }
  return { width: w, height: h, data, ground: 0.2 };
}
const PLACE = { width: 1500, height: 625, left: 150, bottom: 187 };   // the wheels at 1200 - 187 - 125 = 888

test('the room is dark and plain, the logo lit on the wall, the same every time', () => {
  const a = showroomBackdrop(), b = showroomBackdrop();
  assert.deepEqual([a.width, a.height], [ROOM.width, ROOM.height]);
  assert.ok(Buffer.from(a.data).equals(Buffer.from(b.data)), 'deterministic');
  assert.ok(mean(a, 0, ROOM.junction) < 60, `the wall is dark (${mean(a, 0, ROOM.junction)})`);
  assert.ok(mean(a, ROOM.junction + 5, ROOM.height) < 30, 'the floor is darker');
  assert.ok(mean(a, ROOM.junction + 5, ROOM.height) < mean(a, 0, ROOM.junction), 'floor below wall');
  let bright = 0, red = 0;
  for (let y = ROOM.logo.top; y < ROOM.logo.top + 90; y++) for (let x = 650; x < 1150; x++) {
    const i = (y * a.width + x) * 4;
    if (lum(a, x, y) > 180) bright++;
    if (a.data[i]! > 150 && a.data[i + 1]! < 60) red++;
  }
  assert.ok(bright > 2000, 'the white of the logo');
  assert.ok(red > 200, 'the red of the logo');
});

test('the cover has the model lettered on the wall; the other angles do not', () => {
  const plain = showroomBackdrop({ model: 'CLA-Class', cover: false });
  const cover = showroomBackdrop({ model: 'CLA-Class', cover: true });
  const band = (img: Rgba) => mean(img, ROOM.name.baseline - 240, ROOM.name.baseline, 200, 1600);
  assert.ok(Buffer.from(plain.data).equals(Buffer.from(showroomBackdrop().data)), 'no lettering off the cover');
  assert.ok(band(cover) > band(plain) + 2, 'the name shows on the cover');
  assert.ok(band(cover) < 80, 'quietly: the wall stays dark');
});

test('the car is placed with its wheels on the floor line and a faint reflection under it', () => {
  const img = composeShowroom(car(), PLACE);
  const at = (x: number, y: number) => { const i = (y * img.width + x) * 4; return [img.data[i]!, img.data[i + 1]!, img.data[i + 2]!]; };
  const [r, g] = at(900, 600);
  assert.ok(r! > 180 && g! < 50, 'the car itself');
  const [rr, rg] = at(900, ROOM.floorLine + 40);
  assert.ok(rr! > rg! + 8, 'its reflection tints the floor');
  assert.ok(rr! < 120, 'faintly');
  const [br, bg] = at(900, 1150);
  assert.ok(Math.abs(br! - bg!) < 6, 'the reflection fades out before the bottom');
  assert.ok(lum(img, 40, 300) < 50, 'the wall beside the car is untouched');
});

test('local provider: a JPEG of the frame, the same bytes every time, no network', async () => {
  const i = { car: car(), place: PLACE, model: 'C-Class', cover: true, photoId: 'p1' };
  const a = localShowroom.make(i), b = localShowroom.make(i);
  assert.ok(a.ok && b.ok);
  assert.equal(a.bytes[0], 0xff); assert.equal(a.bytes[1], 0xd8);
  assert.ok(Buffer.from(a.bytes).equals(Buffer.from(b.bytes)), 'deterministic');
  const back = await decodeImage(a.bytes);
  assert.deepEqual([back?.width, back?.height], [1800, 1200]);
  assert.equal(sceneOf({ scene: 'showroom' }), 'showroom');
  assert.equal(sceneOf({ scene: 'other' }), 'studio');
  assert.equal(sceneOf(null), 'studio');
});

test('fallback: a quota, a refusal or an error keeps the free showroom with the reason; an answer is fitted to the frame', async () => {
  const i = { car: car(), place: PLACE, model: 'C-Class', cover: false, photoId: 'p1' };
  const local = localShowroom.make(i) as { bytes: Uint8Array };
  const fails = (reason: 'quota' | 'model' | 'limit'): ShowroomProvider => ({ name: 'ai', make: async () => ({ ok: false, reason, message: 'x' }) });
  for (const reason of ['quota', 'model', 'limit'] as const) {
    const r = await makeShowroom(i, [fails(reason)]);
    assert.equal(r.provider, 'local');
    assert.equal(r.reason, reason);
    assert.equal(r.note, FALLBACK_TEXT[reason]);
    assert.ok(Buffer.from(r.bytes).equals(Buffer.from(local.bytes)), 'the local scene itself');
  }
  const thrown = await makeShowroom(i, [{ name: 'ai', make: async () => { throw new Error('boom'); } }]);
  assert.deepEqual([thrown.provider, thrown.reason], ['local', 'error']);
  const unreadable = await makeShowroom(i, [{ name: 'ai', make: async () => ({ ok: true, bytes: new Uint8Array([1, 2, 3]), contentType: 'image/png', provider: 'ai' }) }]);
  assert.deepEqual([unreadable.provider, unreadable.reason], ['local', 'blocked']);
  const none = await makeShowroom(i, [], true);
  assert.deepEqual([none.provider, none.reason], ['local', 'no_key']);
  assert.equal((await makeShowroom(i, [])).note, null, 'no note when no model was meant to be asked');
  // the model answers 1344 x 896: the photo is fitted to 1800 x 1200
  const small = { width: 1344, height: 896, data: new Uint8ClampedArray(1344 * 896 * 4).fill(60) };
  const png = await encodePng(small);
  const ok = await makeShowroom(i, [{ name: 'ai', make: async () => ({ ok: true, bytes: png, contentType: 'image/png', provider: 'ai', model: 'm1' }) }]);
  assert.deepEqual([ok.provider, ok.model, ok.note], ['ai', 'm1', null]);
  const img = await decodeImage(ok.bytes);
  assert.deepEqual([img?.width, img?.height], [1800, 1200]);
  assert.deepEqual([fitFrame(small).width, fitFrame(small).height], [1800, 1200]);
});

test('the image model: key in a header, image in and out; 429 is a quota, 404 a model not allowed, a throw an error', async () => {
  const seen: Array<{ url: string; init: RequestInit }> = [];
  const png = await encodePng({ width: 4, height: 4, data: new Uint8ClampedArray(64).fill(200) });
  const answer = (status: number, body: unknown) => async (url: string | URL | Request, init?: RequestInit) => {
    seen.push({ url: String(url), init: init! });
    return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
  };
  const img = { bytes: new Uint8Array([0xff, 0xd8, 1, 2]), contentType: 'image/jpeg' };
  const ok = await geminiEditImage({ apiKey: 'k-example', fetch: answer(200, { candidates: [{ content: { parts: [{ text: 'here' }, { inlineData: { mimeType: 'image/png', data: Buffer.from(png).toString('base64') } }] } }] }) as typeof fetch }, img, 'p');
  assert.ok(ok.ok && ok.provider === 'ai' && ok.model === GEMINI_DEFAULT_MODEL);
  assert.ok(seen[0]!.url.endsWith(`/models/${GEMINI_DEFAULT_MODEL}:generateContent`));
  assert.ok(!seen[0]!.url.includes('k-example'), 'the key is never in the address');
  assert.equal((seen[0]!.init.headers as Record<string, string>)['x-goog-api-key'], 'k-example');
  const sent = JSON.parse(String(seen[0]!.init.body));
  assert.equal(sent.contents[0].parts[1].inline_data.mime_type, 'image/jpeg');
  assert.deepEqual(sent.generationConfig.responseModalities, ['IMAGE']);
  const q = await geminiEditImage({ apiKey: 'k', fetch: answer(429, { error: { status: 'RESOURCE_EXHAUSTED', message: 'Quota exceeded' } }) as typeof fetch }, img, 'p');
  assert.deepEqual(q.ok ? null : q.reason, 'quota');
  const m = await geminiEditImage({ apiKey: 'k', model: 'gemini-9-image', fetch: answer(404, { error: { status: 'NOT_FOUND', message: 'models/gemini-9-image is not found' } }) as typeof fetch }, img, 'p');
  assert.deepEqual(m.ok ? null : m.reason, 'model');
  const e = await geminiEditImage({ apiKey: 'k', fetch: (async () => { throw new TypeError('network down'); }) as typeof fetch }, img, 'p');
  assert.deepEqual(e.ok ? null : e.reason, 'error');
  const none = await geminiEditImage({ apiKey: 'k', fetch: answer(200, { candidates: [{ finishReason: 'IMAGE_SAFETY', content: { parts: [{ text: 'no' }] } }] }) as typeof fetch }, img, 'p');
  assert.deepEqual(none.ok ? null : [none.reason, none.message], ['blocked', 'IMAGE_SAFETY']);
  const bad = await geminiEditImage({ apiKey: 'k', model: 'bad name!', fetch: answer(200, {}) as typeof fetch }, img, 'p');
  assert.deepEqual(bad.ok ? null : bad.reason, 'model');
  assert.match(showroomPrompt({ cover: true, name: 'CLA' }), /lettering "CLA"/);
  assert.match(showroomPrompt({ cover: false }), /Do not add any lettering/);
  assert.match(showroomPrompt({ cover: false }), /licence plate/);
});

// ---------------------------------------------------------------- the worker with the showroom scene
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, ...new Array(2000).fill(7)]);
const budget = { ai_neurons_today: 0, ai_neurons_limit: 9000, transformations_month: 0, transformations_free: 5000 };
async function setup() {
  const W = 1000, H = 650, data = new Uint8ClampedArray(W * H * 4);
  for (let y = 250; y < 420; y++) for (let x = 320; x < 680; x++) { const i = (y * W + x) * 4; data[i] = 40; data[i + 1] = 60; data[i + 2] = 200; data[i + 3] = 255; }
  const png = await encodePng({ width: W, height: H, data });
  const priv = new Map<string, Uint8Array>([['vehicles/v1/original/fl.jpg', JPEG]]);
  const pub = new Map<string, Uint8Array>();
  const files = { privateUrl: async (p: string) => `priv:${p}`, publicUrl: (p: string) => `pub:${p}`, getPrivate: async (p: string) => priv.get(p) ?? null,
    putPrivate: async (p: string, b: Uint8Array) => { priv.set(p, b); }, putPublic: async (p: string, b: Uint8Array) => { pub.set(p, b); } };
  let composited = 0;
  const photos = { ...fakePhotos(async () => null), name: 'cloudflare-images' as const,
    cutout: async () => ({ ok: true as const, bytes: png, contentType: 'image/png', transformations: 1 }),
    composite: async () => { composited++; return { ok: true as const, bytes: JPEG, contentType: 'image/jpeg', transformations: 1 }; } };
  const deps = (over: Partial<WorkerDeps> = {}): WorkerDeps => ({ claim: async () => ({ jobs: [], budget, held: { photos: false, copy: false }, due: 0 }), report: async () => ({}),
    decodeVin: async () => ({ provider: 'fake', result: { ok: true } }), text: fakeText(), photos, files, ...over });
  const job = (photo: Partial<NonNullable<JobContext['photo']>> = {}): JobContext => ({ id: 'j1', kind: 'process_photo', intake_id: 'i1', vehicle_id: 'v1', attempts: 1, max_attempts: 4, input: {},
    photo: { id: 'p1', shot_type: 'front_left', angle: 'front_left', original_path: 'vehicles/v1/original/fl.jpg', processed_path: null, rebackground: true, is_public: true,
      file_base: 'car-front-left-abcd1234', model: 'C-Class', is_cover: true, scene: 'showroom', ...photo } });
  return { deps, job, pub, composited: () => composited };
}

test('worker: a showroom photo is made here (no draw call), lettered on the cover, placed, noted when no key is set', async () => {
  const s = await setup();
  const r = await runJob(s.deps({ showroomNoKey: true }), s.job(), budget);
  const o = r.output as Record<string, unknown>;
  assert.equal(r.ok, true);
  assert.equal(o.preset_version, SHOWROOM_PRESET);
  assert.equal(s.composited(), 0, 'no transformation for the scene');
  assert.equal(o.lettered, true);
  assert.deepEqual(o.showroom, { provider: 'local', note: FALLBACK_TEXT.no_key, reason: 'no_key' });
  assert.ok(o.place, 'the placement is kept (the plate cover can carry over)');
  const file = s.pub.get('vehicles/v1/car-front-left-abcd1234.jpg')!;
  assert.equal(file[0], 0xff);
  assert.equal(r.units, 1, 'only the cut-out is counted');
  const side = await runJob(s.deps(), s.job({ is_cover: false, shot_type: 'side_left' }), budget);
  assert.equal((side.output as Record<string, unknown>).lettered, false, 'not lettered off the cover');
  const studio = await runJob(s.deps(), s.job({ scene: 'studio' }), budget);
  assert.equal((studio.output as Record<string, unknown>).preset_version, 'studio_v5');
  assert.equal(s.composited(), 1, 'the black studio is drawn as before');
});

test('worker: the image model\'s photo is used without a placement; a quota keeps the free showroom with the reason', async () => {
  const s = await setup();
  const png = await encodePng({ width: 1344, height: 896, data: new Uint8ClampedArray(1344 * 896 * 4).fill(90) });
  const ai: ShowroomProvider = { name: 'ai', make: async () => ({ ok: true, bytes: png, contentType: 'image/png', provider: 'ai', model: 'm1' }) };
  const r = await runJob(s.deps({ showroomAi: ai }), s.job({ enhance: true }), budget);
  const o = r.output as Record<string, unknown>;
  assert.deepEqual(o.showroom, { provider: 'ai', model: 'm1', note: null, reason: null });
  assert.equal('place' in o, false, 'no exact placement: the plate is checked again');
  assert.equal(o.enhance, null, 'not touched up again');
  const quota: ShowroomProvider = { name: 'ai', make: async () => ({ ok: false, reason: 'quota', message: 'Quota exceeded' }) };
  const q = await runJob(s.deps({ showroomAi: quota }), s.job(), budget);
  const qo = q.output as Record<string, unknown>;
  assert.deepEqual([q.ok, (qo.showroom as { provider: string }).provider, (qo.showroom as { note: string }).note], [true, 'local', FALLBACK_TEXT.quota]);
  assert.ok(qo.place);
});
