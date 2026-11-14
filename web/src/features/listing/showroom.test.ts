// Unit tests for the showroom scene (release 35, 0990): the free local composite and the provider fallback (no network:
// the image model's fetch is a fake).
//   node --test --experimental-strip-types src/features/listing/showroom.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FALLBACK_TEXT, PHOTO_SPEC, PLATE_RULE, SHARP_RULE, backgroundReplaced, backgroundSwapPrompt, ROOM, SHOWROOM_PRESET, composeShowroom, coverModelPrompt, decodeImage, fitFrame, encodeJpeg, localShowroom, sameCar, makeShowroom, marketingPrompt, nameBox, sceneOf, showroomBackdrop, showroomPrompt, whiteStudio,
  type ShowroomProvider } from './showroom.ts';
import { encodePng, type Rgba } from './subject-frame.ts';
import { resample } from '../../integrations/photos/local.ts';
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
const PLACE = { width: 1500, height: 625, left: 150, bottom: 115 };   // the wheels at 1200 - 115 - 125 = 960 (ROOM.floorLine)

test('the room is a dark showroom in perspective: ceiling lights, a lit wall, a darker polished floor; the same every time', () => {
  const a = showroomBackdrop(), b = showroomBackdrop();
  assert.deepEqual([a.width, a.height], [ROOM.width, ROOM.height]);
  assert.ok(Buffer.from(a.data).equals(Buffer.from(b.data)), 'deterministic');
  const wall = mean(a, ROOM.ceiling + 10, ROOM.junction - 20, ROOM.wallLeft, ROOM.wallRight), floor = mean(a, ROOM.junction + 10, ROOM.height);
  assert.ok(wall < 70 && wall > 15, `the wall is dark but lit (${wall})`);
  assert.ok(floor < wall, `the floor is darker than the wall (${floor} < ${wall})`);
  // the ceiling's linear lights are bright lines in a near black ceiling
  let lit = 0; for (let x = 300; x < 1500; x++) if (lum(a, x, 64) > 150) lit++;
  assert.ok(lit > 600, `a light strip across the ceiling (${lit})`);
  assert.ok(lum(a, 900, 100) < 40, 'the ceiling between the strips is dark');
  // the side walls meet the back wall at its corners: the left wall is darker than the lit back wall next to it
  assert.ok(lum(a, 100, 400) < lum(a, 300, 300), 'a side wall in shadow');
  // the vertical light strips beside the feature panel
  assert.ok(lum(a, ROOM.panel.left - 9, 400) > 180 && lum(a, ROOM.panel.right + 8, 400) > 180, 'light strips at the panel edges');
  // slats: the panel alternates slat and gap
  const row = 450; let changes = 0; for (let x = 500; x < 700; x++) if (Math.abs(lum(a, x, row) - lum(a, x + 1, row)) > 4) changes++;
  assert.ok(changes > 10, `vertical slats (${changes})`);
  // the floor mirrors the light strips: brighter under them than between them
  assert.ok(lum(a, ROOM.panel.left - 9, ROOM.junction + 30) > lum(a, 900, ROOM.junction + 30) - 6, 'the strips reflected');
  // the logo: the wall's dominant lit sign, about half the width of the panel or more
  let bright = 0, red = 0, left = Infinity, right = -Infinity;
  for (let y = ROOM.logo.top; y < ROOM.logo.top + 170; y++) for (let x = 300; x < 1500; x++) {
    const i = (y * a.width + x) * 4;
    if (lum(a, x, y) > 180) { bright++; left = Math.min(left, x); right = Math.max(right, x); }
    if (a.data[i]! > 150 && a.data[i + 1]! < 60) red++;
  }
  assert.ok(ROOM.logo.width >= 800, 'a big sign');
  assert.ok(bright > 15000, `the white of the logo (${bright})`);
  assert.ok(right - left > 750, `it spans most of the panel (${right - left} px)`);
  assert.ok(red > 2000, `the red of the logo (${red})`);
  // the sign's glow lights the wall around it
  assert.ok(lum(a, 900, ROOM.logo.top - 12) > lum(a, 900, 470) , 'the logo glows on the wall');
  // a vignette: the corners are darker than the middle of the floor
  assert.ok(lum(a, 5, 1195) < lum(a, 900, 1000), 'vignette');
});

test('the cover has the model lettered on the wall above the car when there is room; the other angles do not', () => {
  const plain = showroomBackdrop({ model: 'CLA-Class', cover: false });
  const cover = showroomBackdrop({ model: 'CLA-Class', cover: true, carTop: 560 });
  const box = nameBox(560);
  assert.ok(box.top + box.cap <= 560 - ROOM.name.gap + 1, 'above the car');
  assert.equal(nameBox(200).cap, ROOM.name.capMin, 'never smaller than its least size');
  assert.equal(nameBox(900).cap, ROOM.name.capMax, 'never larger than its most');
  const band = (img: Rgba) => mean(img, box.top, box.top + box.cap, 400, 1400);
  assert.ok(Buffer.from(plain.data).equals(Buffer.from(showroomBackdrop().data)), 'no lettering off the cover');
  assert.ok(band(cover) > band(plain) + 8, `the name shows on the cover (${band(cover)} vs ${band(plain)})`);
  assert.ok(band(cover) < 110, 'brushed metal, not glaring');
});

test('the car stands on the floor with a contact shadow, a soft reflection, and its pixels unchanged', () => {
  const plainFloor = showroomBackdrop({ carTop: 1200 - PLACE.bottom - PLACE.height });
  const img = composeShowroom(car(), PLACE);
  const at = (x: number, y: number) => { const i = (y * img.width + x) * 4; return [img.data[i]!, img.data[i + 1]!, img.data[i + 2]!]; };
  assert.deepEqual(at(900, 600), [200, 30, 30], 'the car exactly as it is');
  const wheel = ROOM.floorLine;
  assert.ok(lum(img, 900, wheel + 4) < lum(plainFloor, 900, wheel + 4) * 0.6, 'a dark contact shadow under the tyres');
  const [rr, rg] = at(900, wheel + 40);
  assert.ok(rr! > rg! + 4, 'its reflection tints the floor');
  assert.ok(rr! < 110, 'softly');
  assert.ok(Math.abs(lum(img, 900, 1195) - lum(plainFloor, 900, 1195)) < 6, 'the reflection fades out before the bottom');
  assert.ok(Math.abs(lum(img, 40, 300) - lum(plainFloor, 40, 300)) < 1, 'the wall beside the car is untouched');
});

test('the image model may relight the car or move it slightly; a different car, colour or a missing car is refused', () => {
  const c = car(), local = composeShowroom(c, PLACE);
  const shade = (img: Rgba, f: (r: number, g: number, b: number) => [number, number, number]) => {
    const out = { width: img.width, height: img.height, data: new Uint8ClampedArray(img.data) };
    for (let i = 0; i < out.data.length; i += 4) { const [r, g, b] = f(out.data[i]!, out.data[i + 1]!, out.data[i + 2]!); out.data[i] = r; out.data[i + 1] = g; out.data[i + 2] = b; }
    return out;
  };
  assert.equal(sameCar(shade(local, (r, g, b) => [r * 1.15, g * 1.15, b * 1.15]), local, c, PLACE), null, 'relit: the same car');
  assert.equal(sameCar(composeShowroom(c, { ...PLACE, left: PLACE.left + 40 }), local, c, PLACE), null, 'turned or moved a little: the same car');
  assert.equal(sameCar(composeShowroom(c, { ...PLACE, left: PLACE.left + 30, width: PLACE.width - 60, height: PLACE.height - 25, bottom: PLACE.bottom + 25 }), local, c, PLACE), null, 'a slightly different pose: the same car');
  assert.equal(sameCar(shade(local, (r, g, b) => (r > 150 && g < 60 ? [30, 40, 200] : [r, g, b])), local, c, PLACE), 'colour', 'another colour');
  assert.equal(sameCar(showroomBackdrop(), local, c, PLACE), 'colour', 'no car at all');
  const tall = (() => { const w = 600, h = 250, data = new Uint8ClampedArray(w * h * 4);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) { const i = (y * w + x) * 4; if (x > 200 && x < 400 && y < h * 0.8) { data[i] = 200; data[i + 1] = 30; data[i + 2] = 30; data[i + 3] = 255; } }
    return { width: w, height: h, data, ground: 0.2 }; })();
  assert.equal(sameCar(composeShowroom(tall, PLACE), local, c, PLACE), 'shape', 'another shape (a different or distorted car)');
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
  // the model answers 1344 x 896 (its own size): fitted to 1800 x 1200, used as it is once it is the same car
  const small = resample(composeShowroom(i.car, i.place, { model: i.model, cover: i.cover }), { x: 0, y: 0, w: 1800, h: 1200 }, 1344, 896);
  const png = await encodePng(small);
  const ok = await makeShowroom(i, [{ name: 'ai', make: async () => ({ ok: true, bytes: png, contentType: 'image/png', provider: 'ai', model: 'm1' }) }]);
  assert.deepEqual([ok.provider, ok.model, ok.note], ['ai', 'm1', null]);
  const img = await decodeImage(ok.bytes);
  assert.deepEqual([img?.width, img?.height], [1800, 1200]);
  assert.deepEqual([fitFrame(small).width, fitFrame(small).height], [1800, 1200]);
  // a flat grey answer (no car where the car was): not used
  const flat = await encodePng({ width: 1344, height: 896, data: new Uint8ClampedArray(1344 * 896 * 4).fill(60) });
  const changed = await makeShowroom(i, [{ name: 'ai', make: async () => ({ ok: true, bytes: flat, contentType: 'image/png', provider: 'ai' }) }]);
  assert.deepEqual([changed.provider, changed.reason, changed.note], ['local', 'changed', FALLBACK_TEXT.changed]);
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
  assert.match(showroomPrompt({ cover: false }), /same make, model, generation/);
  assert.match(showroomPrompt({ cover: false }), /large illuminated sign, the dominant feature/);
  assert.match(showroomPrompt({ cover: false }), /walnut wood slats/);
  assert.match(showroomPrompt({ cover: false }), /no lettering on the wall other than the logo/);
  assert.match(showroomPrompt({ cover: false }), /licence plate/i);
  assert.doesNotMatch(showroomPrompt({ cover: false, name: 'GLC43 AMG' }), /GLC43/, 'r40: only the cover has the name');
  assert.match(showroomPrompt({ cover: false }), /no model name/);
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
  assert.deepEqual(o.showroom, { provider: 'local', note: FALLBACK_TEXT.no_key, reason: 'no_key', mask_quality: 1, spec: PHOTO_SPEC });
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
  // the model answers with the scene it was given (the car where it was)
  const ai: ShowroomProvider = { name: 'ai', make: async (_i, local) => ({ ok: true, bytes: local, contentType: 'image/jpeg', provider: 'ai', model: 'm1' }) };
  const r = await runJob(s.deps({ showroomAi: ai }), s.job({ enhance: true }), budget);
  const o = r.output as Record<string, unknown>;
  assert.deepEqual(o.showroom, { provider: 'ai', model: 'm1', note: null, reason: null, mask_quality: 1, spec: PHOTO_SPEC });
  assert.equal('place' in o, false, 'no exact placement: the plate is checked again');
  assert.equal(o.enhance, null, 'not touched up again');
  const quota: ShowroomProvider = { name: 'ai', make: async () => ({ ok: false, reason: 'quota', message: 'Quota exceeded' }) };
  const q = await runJob(s.deps({ showroomAi: quota }), s.job(), budget);
  const qo = q.output as Record<string, unknown>;
  assert.deepEqual([q.ok, (qo.showroom as { provider: string }).provider, (qo.showroom as { note: string }).note], [true, 'local', FALLBACK_TEXT.quota]);
  assert.ok(qo.place);
});

// ---------------------------------------------------------------- 1053: marketing scenes
test('marketing scenes: the white studio, the words per scene, a copy made or "needs the image model"', async () => {
  const w = whiteStudio();
  assert.ok(Buffer.from(w.data).equals(Buffer.from(whiteStudio().data)), 'deterministic');
  assert.ok(lum(w, 900, 300) > 230 && lum(w, 900, 1100) < lum(w, 900, 300), 'a white wall over a light grey floor');
  const p = marketingPrompt({ label: 'Brick building', place: 'in front of the same brick building', reference: true });
  assert.match(p, /second image is a photo of that real place/);
  assert.match(p, /clearly the same car/);
  assert.match(p, /licence plate/i);
  assert.doesNotMatch(marketingPrompt({ label: 'Highway', place: 'an open highway', reference: false }), /second image/);
  // the worker: the car's kept cut-out in the scene
  const W = 1000, H = 650, data = new Uint8ClampedArray(W * H * 4);
  for (let y = 250; y < 420; y++) for (let x = 320; x < 680; x++) { const i = (y * W + x) * 4; data[i] = 40; data[i + 1] = 60; data[i + 2] = 200; data[i + 3] = 255; }
  const priv = new Map<string, Uint8Array>([['vehicles/v1/work/p1-mask.png', await encodePng({ width: W, height: H, data })], ['site/scenes/brick.jpg', encodeJpeg(whiteStudio())]]);
  const pub = new Map<string, Uint8Array>();
  const files = { privateUrl: async (x: string) => `priv:${x}`, publicUrl: (x: string) => `pub:${x}`, getPrivate: async (x: string) => priv.get(x) ?? null,
    putPrivate: async (x: string, b: Uint8Array) => { priv.set(x, b); }, putPublic: async (x: string, b: Uint8Array) => { pub.set(x, b); } };
  const deps = (over: Partial<WorkerDeps> = {}): WorkerDeps => ({ claim: async () => ({ jobs: [], budget, held: { photos: false, copy: false }, due: 0 }), report: async () => ({}),
    decodeVin: async () => ({ provider: 'fake', result: { ok: true } }), text: fakeText(), photos: fakePhotos(async () => null), files, ...over });
  const mk = (scene: string, made: 'local' | 'photo', reference: string | null = null): JobContext => ({ id: 'm1', kind: 'marketing_photo', intake_id: 'i1', vehicle_id: 'v1', attempts: 1, max_attempts: 4,
    input: { marketing: { id: `mk-${scene}`, vehicle_id: 'v1', photo_id: 'p1', scene, label: scene, made, place: 'a place', mask: 'vehicles/v1/work/p1-mask.png', adjust: null, reference } } });
  const local = await runJob(deps({ showroomNoKey: true }), mk('studio_white', 'local'), budget);
  const lo = (local.output as { marketing: { status: string; path: string } }).marketing;
  assert.equal(lo.status, 'made');
  assert.ok(pub.get(lo.path), 'stored as a marketing copy, never the website photo');
  const photo = await runJob(deps({ showroomNoKey: true }), mk('highway', 'photo'), budget);
  const po = (photo.output as { marketing: { status: string; note: string } }).marketing;
  assert.deepEqual([po.status, /needs the image model/.test(po.note)], ['needs_gemini', true]);
  let seen: { prompt?: string | null; reference?: unknown } = {};
  const ai: ShowroomProvider = { name: 'ai', make: async (i, b) => { seen = { prompt: i.prompt, reference: i.reference }; return { ok: true, bytes: b, contentType: 'image/jpeg', provider: 'ai', model: 'm1' }; } };
  const withRef = await runJob(deps({ showroomAi: ai }), mk('brick_building', 'photo', 'site/scenes/brick.jpg'), budget);
  assert.equal((withRef.output as { marketing: { status: string } }).marketing.status, 'made');
  assert.ok(seen.reference, 'the photo of the real place is given to the image model');
  assert.match(String(seen.prompt), /second image/);
});

// ---------------------------------------------------------------- r36 (2100): the listing's first photo
test('first photo: the model words keep the site\'s own rules; the flyer drawn on the cover photo; "with model" needs the image model', async () => {
  const p = coverModelPrompt('A glamorous model in a red evening dress.');
  assert.match(p, /glamorous model in a red evening dress/);
  assert.match(p, /fully clothed/);
  assert.match(p, /clearly adult professional model \(over 25/);
  assert.match(p, /nothing revealing, see-through, explicit or sexual/);
  assert.match(p, /clearly the same car/);
  assert.match(coverModelPrompt(''), /fully clothed/, 'the rules hold with no words in the settings');
  const W = 1000, H = 650, data = new Uint8ClampedArray(W * H * 4);
  for (let y = 250; y < 420; y++) for (let x = 320; x < 680; x++) { const i = (y * W + x) * 4; data[i] = 40; data[i + 1] = 60; data[i + 2] = 200; data[i + 3] = 255; }
  const priv = new Map<string, Uint8Array>([['vehicles/v1/work/p1-mask.png', await encodePng({ width: W, height: H, data })]]);
  const pub = new Map<string, Uint8Array>([['vehicles/v1/p1.jpg', encodeJpeg(whiteStudio())]]);
  const files = { privateUrl: async (x: string) => `priv:${x}`, publicUrl: (x: string) => `pub:${x}`, getPrivate: async (x: string) => priv.get(x) ?? null,
    putPrivate: async (x: string, b: Uint8Array) => { priv.set(x, b); }, putPublic: async (x: string, b: Uint8Array) => { pub.set(x, b); }, getPublic: async (x: string) => pub.get(x) ?? null };
  const deps = (over: Partial<WorkerDeps> = {}): WorkerDeps => ({ claim: async () => ({ jobs: [], budget, held: { photos: false, copy: false }, due: 0 }), report: async () => ({}),
    decodeVin: async () => ({ provider: 'fake', result: { ok: true } }), text: fakeText(), photos: fakePhotos(async () => null), files, ...over });
  const mk = (style: 'model' | 'flyer'): JobContext => ({ id: 'c1', kind: style === 'model' ? 'cover_model' : 'cover_flyer', intake_id: 'i1', vehicle_id: 'v1', attempts: 1, max_attempts: 4,
    input: { cover: { id: `cv-${style}`, vehicle_id: 'v1', photo_id: 'p1', style, source: 'vehicles/v1/p1.jpg', mask: 'vehicles/v1/work/p1-mask.png', adjust: null, model: 'C 300',
      prompt: 'A model in an evening dress.', flyer: { headline: '2023 MERCEDES-BENZ C 300', offer: 'FROM $89 A DAY', cta: 'BOOK NOW', logo: true } } } });
  const fl = (await runJob(deps(), mk('flyer'), budget)).output as { cover: { status: string; path: string; width: number } };
  assert.deepEqual([fl.cover.status, fl.cover.path, fl.cover.width], ['made', 'vehicles/v1/cover/cv-flyer.jpg', 1800]);
  assert.ok(pub.get(fl.cover.path), 'a file of its own: the cover photo is not changed');
  const none = (await runJob(deps({ showroomNoKey: true }), mk('model'), budget)).output as { cover: { status: string; note: string } };
  assert.deepEqual([none.cover.status, /needs the image model/.test(none.cover.note)], ['needs_gemini', true]);
  let seen = '';
  const ai: ShowroomProvider = { name: 'ai', make: async (i, b) => { seen = String(i.prompt); return { ok: true, bytes: b, contentType: 'image/jpeg', provider: 'ai', model: 'm1' }; } };
  const md = (await runJob(deps({ showroomAi: ai }), mk('model'), budget)).output as { cover: { status: string; path: string } };
  assert.deepEqual([md.cover.status, md.cover.path], ['made', 'vehicles/v1/cover/cv-model.jpg']);
  assert.match(seen, /evening dress/);
  assert.match(seen, /fully clothed/);
});

// ---------------------------------------------------------------- r43 (2690): Redo photos with Gemini: the image model is the only engine
test('worker: engine gemini with no key fails the step and puts nothing on the site (no free showroom, no original)', async () => {
  const s = await setup();
  const gem = (): JobContext => ({ ...s.job(), input: { engine: 'gemini' } });
  const none = await runJob(s.deps({ showroomNoKey: true }), gem(), budget);
  assert.equal(none.ok, false);
  assert.equal(none.retryable, false);
  assert.match(none.error ?? '', /^Redo with Gemini: Gemini is not set up/);
  assert.match(none.error ?? '', /The photo was not changed/);
  assert.equal(s.pub.size, 0, 'nothing was stored on the site');
  assert.equal(s.composited(), 0, 'and nothing was drawn by the Cloudflare composite');
});

test('worker: engine gemini fails with the reason when Gemini refuses, hits its limit or changes the car; it never falls back', async () => {
  const s = await setup();
  const gem = (): JobContext => ({ ...s.job(), input: { engine: 'gemini' } });
  for (const reason of ['quota', 'limit', 'off', 'blocked', 'error'] as const) {
    const ai: ShowroomProvider = { name: 'ai', make: async () => ({ ok: false, reason, message: `no: ${reason}` }) };
    const r = await runJob(s.deps({ showroomAi: ai }), gem(), budget);
    assert.equal(r.ok, false, reason);
    assert.match(r.error ?? '', /^Redo with Gemini: Gemini did not make it/, reason);
    assert.equal(r.retryable, false);
    // r44: the daily limit and a quota tell the database to queue the step again later (the others are final)
    assert.equal((r.output as { gemini_wait?: string } | undefined)?.gemini_wait, reason === 'limit' || reason === 'quota' ? reason : undefined, reason);
  }
  assert.equal(s.pub.size, 0, 'no file reached the site');
  assert.equal(s.composited(), 0);
  // the same job without the engine keeps the free showroom (the plain Redo)
  const quota: ShowroomProvider = { name: 'ai', make: async () => ({ ok: false, reason: 'quota', message: 'Quota exceeded' }) };
  const plain = await runJob(s.deps({ showroomAi: quota }), s.job(), budget);
  assert.equal(plain.ok, true);
});

test('worker: engine gemini uses the model\'s photo when it answers, and refuses an inside or studio photo', async () => {
  const s = await setup();
  const ai: ShowroomProvider = { name: 'ai', make: async (_i, local) => ({ ok: true, bytes: local, contentType: 'image/jpeg', provider: 'ai', model: 'm1' }) };
  const r = await runJob(s.deps({ showroomAi: ai }), { ...s.job(), input: { engine: 'gemini' } }, budget);
  assert.equal(r.ok, true);
  assert.equal(((r.output as Record<string, unknown>).showroom as { provider: string }).provider, 'ai');
  assert.ok(s.pub.has('vehicles/v1/car-front-left-abcd1234.jpg'));
  const studio = await runJob(s.deps({ showroomAi: ai }), { ...s.job({ scene: 'studio' }), input: { engine: 'gemini' } }, budget);
  assert.equal(studio.ok, false);
  assert.match(studio.error ?? '', /only an outside photo in the showroom/);
  const inside = await runJob(s.deps({ showroomAi: ai }), { ...s.job({ rebackground: false, shot_type: 'dashboard', angle: 'dashboard' }), input: { engine: 'gemini' } }, budget);
  assert.equal(inside.ok, false);
});

// ---------------------------------------------------------------- r44 (2780): the owner's four points
test('r44: every prompt keeps the plate on the plate and writes no text anywhere else', () => {
  for (const p of [showroomPrompt({ cover: false }), showroomPrompt({ cover: true, name: 'CLA' }), backgroundSwapPrompt({ cover: false }), marketingPrompt({ label: 'x', place: 'a street', reference: false }), coverModelPrompt('')]) {
    assert.ok(p.includes(PLATE_RULE), p.slice(0, 80));
    assert.match(p, /exactly where it is on the bumper/);
    assert.match(p, /nothing floating in the air/);
    assert.doesNotMatch(p, /Do not add or show a licence plate/, 'the old words made the model drop the plate and write its text elsewhere');
  }
});

test('r44: the showroom and the background swap replace every trace of the place, sharp from front to back', () => {
  for (const p of [showroomPrompt({ cover: false }), backgroundSwapPrompt({ cover: true, name: 'GLE' })]) {
    assert.match(p, /street, parking lot, sky, trees/);
    assert.ok(p.includes(SHARP_RULE));
    assert.match(p, /no bokeh/);
    assert.doesNotMatch(p, /shallow depth|blurred background/i);
  }
  const swap = backgroundSwapPrompt({ cover: true, name: 'GLE' });
  assert.match(swap, /second image is an empty, dark CarmaCars car showroom/);
  assert.match(swap, /"GLE"/);
  assert.doesNotMatch(backgroundSwapPrompt({ cover: false, name: 'GLE' }), /"GLE"/, 'only the cover has the name');
});

test('r44: the background check: the room passes, a sky or a white garage does not', () => {
  assert.equal(backgroundReplaced(showroomBackdrop()), true, 'the drawn room');
  assert.equal(backgroundReplaced(showroomBackdrop({ model: 'CLA', cover: true })), true, 'the cover room');
  const sky = showroomBackdrop();
  for (let y = 0; y < 200; y++) for (let x = 0; x < sky.width; x++) { const i = (y * sky.width + x) * 4; sky.data[i] = 150; sky.data[i + 1] = 190; sky.data[i + 2] = 240; }
  assert.equal(backgroundReplaced(sky), false, 'a sky at the top');
  const white = { width: 300, height: 200, data: new Uint8ClampedArray(300 * 200 * 4).fill(235) };
  assert.equal(backgroundReplaced(white), false, 'a white garage');
  assert.equal(PHOTO_SPEC, 'r45.1', 'keep equal to app.photo_spec() (migration 2840)');
});
