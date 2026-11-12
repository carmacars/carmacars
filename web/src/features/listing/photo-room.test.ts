// Unit tests for the photographed showroom room (r39, 2400): the placement math, the mask's quality, the light match, and
// the worker using a stored room or, for a poor cut-out, the real photo.
//   node --test --experimental-strip-types src/features/listing/photo-room.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PHOTO_MAX_HEIGHT, PHOTO_TOP_MARGIN, lightMatch, maskQuality, photoPlace } from './photo-room.ts';
import { composeShowroom, encodeJpeg, photoRoomPrompt, coverModelPrompt } from './showroom.ts';
import { encodePng, type Rgba } from './subject-frame.ts';
import { runJob, type JobContext, type WorkerDeps } from './worker.ts';
import { fakePhotos } from '../../integrations/photos/fake.ts';
import { fakeText } from '../../integrations/llm/fake.ts';
// @ts-expect-error the fetch script is plain JavaScript
import { licenceOf, scoreRoom, slugOf } from '../../../scripts/showroom-photos.mjs';

const W = 1800, H = 1200;
/** Where the wheels stand for a place (the frame's bottom edge minus bottom minus the shadow band). */
const wheelOf = (p: { height: number; bottom: number }, ground: number) => H - p.bottom - p.height * ground;

test('placement: the car is 70% of the frame wide, centred, its wheels exactly on the room\'s floor line', () => {
  const f = { width: 1000, height: 400, ground: 0.15, side: 0.02 };
  const p = photoPlace(f, W, H, { floor: 0.82, carWidth: 0.7 });
  assert.ok(Math.abs(p.carShare - 0.7) < 0.002, `car share ${p.carShare}`);
  assert.ok(Math.abs(p.width * (1 - 2 * f.side) - W * 0.7) < 2, 'the car itself, without its side margins');
  assert.ok(Math.abs(p.left + p.width / 2 - W / 2) <= 1, 'centred');
  assert.ok(Math.abs(wheelOf(p, f.ground) - H * 0.82) <= 1.5, `wheels at ${wheelOf(p, f.ground)}`);
  // another room's floor moves the car with it, same size
  const q = photoPlace(f, W, H, { floor: 0.9, carWidth: 0.7 });
  assert.equal(q.width, p.width);
  assert.ok(Math.abs(wheelOf(q, f.ground) - H * 0.9) <= 1.5);
});

test('placement: a tall view (front or rear) is made smaller so its roof stays under the top margin, still on the floor line', () => {
  const f = { width: 500, height: 520, ground: 0.12, side: 0.03 };
  const p = photoPlace(f, W, H, { floor: 0.8, carWidth: 0.7 });
  const top = H - p.bottom - p.height;
  assert.ok(top >= H * PHOTO_TOP_MARGIN - 1.5, `roof at ${top}`);
  assert.ok(wheelOf(p, f.ground) - top <= H * PHOTO_MAX_HEIGHT + 1.5, 'never taller than half the frame above its wheels');
  assert.ok(p.carShare < 0.7, 'smaller than the usual width');
  assert.ok(Math.abs(wheelOf(p, f.ground) - H * 0.8) <= 1.5);
});

test('placement: settings out of range are held (floor 0.5 to 0.97, width 0.3 to 0.9)', () => {
  const f = { width: 1000, height: 400, ground: 0.15, side: 0 };
  const p = photoPlace(f, W, H, { floor: 2, carWidth: 5 });
  assert.ok(wheelOf(p, f.ground) <= H * 0.97 + 1.5);
  assert.ok(p.carShare <= 0.9 + 1e-9);
});

/** An RGBA mask drawn by a function of (x, y) giving alpha 0 to 255. */
function mask(w: number, h: number, a: (x: number, y: number) => number): Rgba {
  const data = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) { const i = (y * w + x) * 4; data[i] = 120; data[i + 1] = 120; data[i + 2] = 120; data[i + 3] = a(x, y); }
  return { width: w, height: h, data };
}
/** A car-like silhouette: a body box, a cabin on top, two wheels, a one-pixel soft edge. */
const carShape = (x: number, y: number) => {
  const inBody = x >= 100 && x < 700 && y >= 150 && y < 280, inCabin = x >= 250 && x < 560 && y >= 80 && y < 150;
  const wheel = (cx: number) => (x - cx) ** 2 + (y - 280) ** 2 < 45 ** 2;
  if (inBody || inCabin || wheel(210) || wheel(590)) return 255;
  const near = (x >= 99 && x <= 700 && y >= 149 && y <= 280) || (x >= 249 && x <= 560 && y >= 79 && y <= 150);
  return near ? 128 : 0;
};

test('mask quality: a clean car-like mask scores high; pieces, a wide uncertain edge or a ragged outline score low; empty is 0', () => {
  const clean = maskQuality(mask(800, 400, carShape));
  assert.ok(clean.score >= 0.85, `clean ${JSON.stringify(clean)}`);
  // the car and many loose bits (the segmenter kept parts of the room)
  const bits = maskQuality(mask(800, 400, (x, y) => (carShape(x, y) === 255 || ((x % 40 < 14) && (y % 40 < 14) && y > 300)) ? 255 : 0));
  assert.ok(bits.score < 0.6, `pieces ${JSON.stringify(bits)}`);
  assert.ok(bits.pieces > 5);
  // half-transparent everywhere around the car (the segmenter was unsure)
  const unsure = maskQuality(mask(800, 400, (x, y) => (carShape(x, y) === 255 ? 255 : y > 40 && y < 360 && x > 40 && x < 760 ? 110 : 0)));
  assert.ok(unsure.score < 0.6, `unsure ${JSON.stringify(unsure)}`);
  // a ragged outline (noise along the edge)
  const ragged = maskQuality(mask(800, 400, (x, y) => (carShape(x, y) === 255 && ((x * 7 + y * 13) % 5 !== 0 || (x > 300 && x < 500 && y > 180 && y < 250)) ? 255 : 0)));
  assert.ok(ragged.score < 0.6, `ragged ${JSON.stringify(ragged)}`);
  assert.equal(maskQuality(mask(200, 100, () => 0)).score, 0);
});

test('light match: the car is nudged towards the room, never more than 10% brighter or darker or 4% in colour', () => {
  const room = (r: number, g: number, b: number): Rgba => { const d = new Uint8ClampedArray(W * H * 4); for (let i = 0; i < d.length; i += 4) { d[i] = r; d[i + 1] = g; d[i + 2] = b; d[i + 3] = 255; } return { width: W, height: H, data: d }; };
  const car = { ...mask(300, 100, () => 255), ground: 0.1 };
  const warm = lightMatch(room(240, 200, 150), car, 0.8);
  assert.ok(warm[0] > warm[2], 'a warm room warms the car');
  for (const k of warm) assert.ok(k >= 0.9 * 0.96 - 1e-9 && k <= 1.1 * 1.04 + 1e-9, `gain ${k}`);
  const dark = lightMatch(room(10, 10, 10), car, 0.8);
  assert.ok(dark.every((k) => k >= 0.86 && k < 1), `a dark room darkens a little: ${dark}`);
});

test('compose in a photo: the room is kept outside the car, the shadow darkens the floor under it, the reflection is faint', () => {
  const d = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) { const i = (y * W + x) * 4, v = y < 900 ? 180 : 150; d[i] = v; d[i + 1] = v; d[i + 2] = v; d[i + 3] = 255; }
  const room: Rgba = { width: W, height: H, data: d };
  const car = { width: 600, height: 250, data: new Uint8ClampedArray(600 * 250 * 4), ground: 0.2 };
  for (let y = 0; y < 200; y++) for (let x = 0; x < 600; x++) { const i = (y * 600 + x) * 4; car.data[i] = 200; car.data[i + 1] = 30; car.data[i + 2] = 30; car.data[i + 3] = 255; }
  const f = { width: 600, height: 250, ground: 0.2, side: 0 };
  const p = photoPlace(f, W, H, { floor: 0.82, carWidth: 0.7 });
  const out = composeShowroom(car, p, { reflect: 0.12, gain: [1, 1, 1] }, room);
  const lum = (x: number, y: number) => { const i = (y * W + x) * 4; return (out.data[i]! + out.data[i + 1]! + out.data[i + 2]!) / 3; };
  const wheel = Math.round(wheelOf(p, f.ground));
  assert.equal(lum(40, 100), 180, 'the room far from the car is untouched');
  assert.ok(lum(W / 2, wheel + 4) < 150 * 0.6, 'the contact shadow is dark');
  const refl = lum(W / 2, wheel + 60);
  assert.ok(refl < 150 && refl > 40, `faint reflection and shadow (${refl})`);
  assert.equal(encodeJpeg(out)[0], 0xff);
});

test('the image model\'s words for a photographed room keep the room and add no sign; the cover with a model too', () => {
  assert.match(photoRoomPrompt(), /keep it exactly as it is/);
  assert.match(photoRoomPrompt(), /add no signs, logos or text/);
  assert.match(coverModelPrompt('', true), /add no signs, logos or text/);
  assert.match(coverModelPrompt('', false), /CarmaCars logo sign/);
});

// ---------------------------------------------------------------- the worker
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, ...new Array(2000).fill(7)]);
const budget = { ai_neurons_today: 0, ai_neurons_limit: 9000, transformations_month: 0, transformations_free: 5000 };
async function setup(cut: Rgba) {
  const png = await encodePng(cut);
  // the stored room: a plain warm grey photo stand-in (the real ones come from web/scripts/showroom-photos.mjs)
  const rd = new Uint8ClampedArray(900 * 600 * 4);
  for (let i = 0; i < rd.length; i += 4) { rd[i] = 170; rd[i + 1] = 160; rd[i + 2] = 150; rd[i + 3] = 255; }
  const roomJpeg = encodeJpeg({ width: 900, height: 600, data: rd });
  const priv = new Map<string, Uint8Array>([['vehicles/v1/work/edited-cutout.png', png], ['vehicles/v1/original/fl.jpg', encodeJpeg({ width: 400, height: 300, data: new Uint8ClampedArray(400 * 300 * 4).fill(200) })]]);
  const pub = new Map<string, Uint8Array>([['site/backdrop/photos/room-a.jpg', roomJpeg]]);
  const files = { privateUrl: async (p: string) => `priv:${p}`, publicUrl: (p: string) => `pub:${p}`, getPrivate: async (p: string) => priv.get(p) ?? null,
    putPrivate: async (p: string, b: Uint8Array) => { priv.set(p, b); }, putPublic: async (p: string, b: Uint8Array) => { pub.set(p, b); },
    getPublic: async (p: string) => pub.get(p) ?? null };
  const photos = { ...fakePhotos(async () => null), name: 'cloudflare-images' as const,
    cutout: async () => ({ ok: true as const, bytes: png, contentType: 'image/png', transformations: 1 }),
    composite: async () => ({ ok: true as const, bytes: JPEG, contentType: 'image/jpeg', transformations: 1 }) };
  const deps = (over: Partial<WorkerDeps> = {}): WorkerDeps => ({ claim: async () => ({ jobs: [], budget, held: { photos: false, copy: false }, due: 0 }), report: async () => ({}),
    decodeVin: async () => ({ provider: 'fake', result: { ok: true } }), text: fakeText(), photos, files, ...over });
  const job = (over: Partial<JobContext> = {}): JobContext => ({ id: 'j1', kind: 'process_photo', intake_id: 'i1', vehicle_id: 'v1', attempts: 1, max_attempts: 4, input: {},
    photo: { id: 'p1', shot_type: 'front_left', angle: 'front_left', original_path: 'vehicles/v1/original/fl.jpg', processed_path: null, rebackground: true, is_public: true,
      file_base: 'car-front-left-abcd1234', model: 'C-Class', is_cover: true, scene: 'showroom' },
    background: { slug: 'room-a', path: 'site/backdrop/photos/room-a.jpg', floor: 0.8, reflect: 0.1 }, cutout: { car_width: 0.7, min_quality: 0.6 }, ...over });
  return { deps, job, pub };
}

test('worker: a stored photo room is used (car 70% wide on its floor line, no lettering), noted with the mask\'s score and the room', async () => {
  const s = await setup(mask(800, 400, carShape));
  const r = await runJob(s.deps({ showroomNoKey: true }), s.job(), budget);
  const o = r.output as Record<string, unknown>;
  assert.equal(r.ok, true);
  const sr = o.showroom as Record<string, unknown>;
  assert.equal(sr.background, 'room-a');
  assert.ok((sr.mask_quality as number) >= 0.85);
  assert.equal(o.lettered, false, 'no lettering on a real wall');
  const pl = o.place as { width: number; left: number };
  assert.ok(Math.abs(pl.left + pl.width / 2 - 900) <= 1, 'centred');
  // the photo's corners are the room's warm grey (the drawn room is dark there)
  const out = s.pub.get('vehicles/v1/car-front-left-abcd1234.jpg')!;
  assert.equal(out[0], 0xff);
  // without a stored room (none set, or unreadable): the drawn room, lettered on the cover
  const drawn = await runJob(s.deps({ showroomNoKey: true }), s.job({ background: { slug: 'gone', path: 'site/backdrop/photos/gone.jpg', floor: 0.8, reflect: 0.1 } }), budget);
  assert.equal((drawn.output as Record<string, unknown>).lettered, true);
  assert.equal(((drawn.output as Record<string, unknown>).showroom as Record<string, unknown>).background, undefined);
});

test('worker: a poor cut-out is never composited: the real photo is used, flagged, with the reason and the score', async () => {
  const s = await setup(mask(800, 400, (x, y) => (carShape(x, y) === 255 ? 255 : y > 40 && y < 360 && x > 40 && x < 760 ? 110 : 0)));
  const r = await runJob(s.deps({ showroomNoKey: true }), s.job(), budget);
  const o = r.output as Record<string, unknown>;
  assert.equal(r.ok, true);
  assert.equal(o.used_original, true);
  assert.equal(o.preset_version, 'original');
  const sr = o.showroom as Record<string, unknown>;
  assert.equal(sr.used_original, true);
  assert.equal(sr.reason, 'low_mask');
  assert.ok((sr.mask_quality as number) < 0.6);
  // the black studio too
  const studio = await runJob(s.deps(), s.job({ photo: { ...s.job().photo!, scene: 'studio' } }), budget);
  assert.equal((studio.output as Record<string, unknown>).used_original, true);
  // a cut-out staff edited is theirs: used even when the segmenter's mask was poor
  const edited = await runJob(s.deps({ showroomNoKey: true }), s.job({ input: { edit: { cutout_path: 'vehicles/v1/work/edited-cutout.png' } } }), budget);
  assert.notEqual((edited.output as Record<string, unknown> | undefined)?.used_original, true);
});

test('the room fetcher keeps only CC0, public domain and CC BY, and landscape interiors without people or shows', () => {
  assert.equal(licenceOf('CC0'), 'CC0');
  assert.equal(licenceOf('Public domain'), 'Public domain');
  assert.equal(licenceOf('CC BY 4.0'), 'CC BY 4.0');
  for (const l of ['CC BY-SA 4.0', 'CC BY-NC 2.0', 'CC BY-ND 3.0', 'GFDL', '']) assert.equal(licenceOf(l), null, l);
  const f = { title: 'File:Empty car showroom interior.jpg', mime: 'image/jpeg', width: 4000, height: 2667, licence: 'CC0' };
  assert.ok((scoreRoom(f) ?? 0) > 5);
  assert.equal(scoreRoom({ ...f, licence: 'CC BY-SA 3.0' }), null);
  assert.equal(scoreRoom({ ...f, title: 'File:Visitors at the auto show.jpg' }), null);
  assert.equal(scoreRoom({ ...f, width: 2000, height: 3000 }), null, 'portrait');
  assert.equal(slugOf('File:Empty car showroom interior.jpg'), 'empty-car-showroom-interior');
});
