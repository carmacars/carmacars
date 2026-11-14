// Unit tests for the r45 photo standard (features/listing/r45.ts) and the worker's r45 step, with fakes (no network).
//   node --test --experimental-strip-types src/features/listing/r45.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { R45_SPEC, STANDARD_ANGLES, angleSources, blurPlates, boxContrast, checkPrompt, detailPrompt, exteriorPrompt, generatePrompt, interiorPrompt, judgeCheck, missingAngles,
  promptFor, PLATE_BLUR_RULE, NO_TEXT_RULE } from './r45.ts';
import { PHOTO_SPEC, encodeJpeg } from './showroom.ts';
import { orderPhotos, photoRank } from '../../lib/photo-order.ts';
import { runJob, type JobContext, type JobResult, type WorkerDeps } from './worker.ts';

type R45Out = { r45: { pass: boolean; spec: string; plates: unknown[]; reasons: string[]; wait?: string; generated?: boolean }; preset_version: string; showroom: { mode: string };
  width: number; height: number; processed_path: string; variants: Array<{ width: number }> };
const out = (r: JobResult) => r.output as unknown as R45Out;
import { fakePhotos } from '../../integrations/photos/fake.ts';
import { fakeText } from '../../integrations/llm/fake.ts';
import type { Rgba } from './subject-frame.ts';

const CAR = { year: 2022, make: 'Mercedes-Benz', model: 'CLA 250', trim: '4MATIC', colour: 'Polar White' };

test('the standard is one value everywhere', () => {
  assert.equal(R45_SPEC, 'r45.1');
  assert.equal(PHOTO_SPEC, R45_SPEC);
});

test('the standard angles: the front three-quarter first, outside before inside, the order the site shows', () => {
  assert.deepEqual(STANDARD_ANGLES.map((a) => a.shot), ['front_left', 'front', 'left', 'rear_left', 'rear', 'dashboard', 'front_seats', 'rear_seats', 'trunk']);
  const ranks = STANDARD_ANGLES.map((a) => photoRank(a.shot));
  assert.deepEqual([...ranks].sort((a, b) => a - b), ranks, 'the site order is the standard order');
  assert.ok(STANDARD_ANGLES.filter((a) => a.exterior).every((a) => photoRank(a.shot) < 20) && STANDARD_ANGLES.filter((a) => !a.exterior).every((a) => photoRank(a.shot) >= 20));
});

test('ordering: an inside photo is never first while an outside one exists, and a generated front three-quarter leads', () => {
  const list = [{ shot: 'dashboard', is_cover: true }, { shot: 'rear' }, { shot: 'trunk' }, { shot: 'front_left', generated: true }, { shot: 'front_seats' }, { shot: 'left' }];
  assert.deepEqual(orderPhotos(list).map((p) => p.shot), ['front_left', 'left', 'rear', 'dashboard', 'front_seats', 'trunk']);
});

test('angle planning: a car with one or two photos gets every other standard angle, a flagged photo does not count', () => {
  assert.deepEqual(missingAngles([{ shot: 'front_left' }, { shot: 'dashboard' }]).map((a) => a.shot), ['front', 'left', 'rear_left', 'rear', 'front_seats', 'rear_seats', 'trunk']);
  assert.ok(missingAngles([{ shot: 'front_left', flagged: true }]).some((a) => a.shot === 'front_left'));
  assert.equal(missingAngles(STANDARD_ANGLES.map((a) => ({ shot: a.shot }))).length, 0);
  const photos = [{ shot: 'dashboard' }, { shot: 'rear', generated: true }, { shot: 'front_left' }, { shot: 'trunk' }, { shot: 'left', flagged: true }, { shot: 'rear_left' }];
  assert.deepEqual(angleSources('front', photos).map((p) => p.shot), ['front_left', 'rear_left', 'dashboard'], 'real photos only, the same side first');
  assert.deepEqual(angleSources('rear_seats', photos).map((p) => p.shot), ['dashboard', 'trunk', 'front_left']);
});

test('the words: the whole background replaced, the car unchanged, every plate blurred, no text anywhere', () => {
  const e = exteriorPrompt({ car: CAR, shot: 'front_left' });
  assert.match(e, /replace the ENTIRE background/);
  assert.match(e, /Nothing of the original surroundings may remain/);
  assert.match(e, /2022 Mercedes-Benz CLA 250 4MATIC, Polar White/);
  assert.match(e, /not warped/);
  for (const p of [e, interiorPrompt({ car: CAR, shot: 'dashboard' }), generatePrompt({ car: CAR, shot: 'rear', sources: 2 }), detailPrompt({ car: CAR, shot: 'wheel' })]) {
    assert.ok(p.includes(PLATE_BLUR_RULE) || !/plate/i.test(p.replace(PLATE_BLUR_RULE, '')), 'the plate rule');
    assert.ok(p.includes(NO_TEXT_RULE));
    assert.doesNotMatch(p, /CARMA Ontario|plain blank face|write the plate/i, 'no plate is drawn or left blank');
  }
  assert.match(PLATE_BLUR_RULE, /no letter or number on it can be read/);
  assert.match(PLATE_BLUR_RULE, /Blur nothing else/);
  const i = interiorPrompt({ car: CAR, shot: 'front_seats' });
  assert.match(i, /remove clutter/);
  assert.match(i, /no blur anywhere/);
  const g = generatePrompt({ car: CAR, shot: 'rear_left', sources: 3 });
  assert.match(g, /first 3 images are real photos/);
  assert.match(g, /rear three-quarter/);
  assert.match(g, /last image is the empty CarmaCars car showroom/);
  assert.doesNotMatch(generatePrompt({ car: CAR, shot: 'trunk', sources: 1 }), /last image is the empty/);
  assert.equal(promptFor({ car: CAR, shot: 'front', generated: false }), exteriorPrompt({ car: CAR, shot: 'front' }));
  assert.equal(promptFor({ car: CAR, shot: 'other', generated: false }), detailPrompt({ car: CAR, shot: 'other' }));
  assert.match(checkPrompt({ car: CAR, shot: 'front_left', generated: false }), /"original_background".*"warped".*"wrong_colour".*"wrong_model".*"parts_changed".*"text_elsewhere".*"plate_readable"/);
});

const OK = { original_background: false, warped: false, wrong_colour: false, wrong_model: false, parts_changed: false, text_elsewhere: false, plate_readable: false, blurry: false, clutter: false, view: 'front_left', plates: [] };
test('the check: each problem refuses the photo; no answer refuses it', () => {
  assert.deepEqual(judgeCheck(OK, { shot: 'front_left', generated: false, edgesDark: true }), { pass: true, reasons: [], plates: [], view: 'front_left' });
  for (const k of ['original_background', 'warped', 'wrong_colour', 'wrong_model', 'parts_changed', 'text_elsewhere', 'blurry'] as const) {
    const v = judgeCheck({ ...OK, [k]: true }, { shot: 'front_left', generated: false });
    assert.equal(v.pass, false, k); assert.deepEqual(v.reasons, [k]);
  }
  assert.deepEqual(judgeCheck(null, { shot: 'front', generated: false }).reasons, ['no_answer']);
  assert.deepEqual(judgeCheck(OK, { shot: 'front_left', generated: false, edgesDark: false }).reasons, ['edges_not_dark'], 'the site\'s own edge check');
  assert.deepEqual(judgeCheck({ ...OK, clutter: true, view: 'dashboard' }, { shot: 'dashboard', generated: false }).reasons, ['clutter']);
  assert.deepEqual(judgeCheck({ ...OK, view: 'dashboard' }, { shot: 'front_left', generated: false }).reasons, ['wrong_view'], 'an outside photo must show the outside');
  assert.deepEqual(judgeCheck({ ...OK, view: 'rear' }, { shot: 'front', generated: true }).reasons, ['wrong_view'], 'a generated view must be the view asked');
  assert.equal(judgeCheck({ ...OK, view: 'front_right' }, { shot: 'front_left', generated: true }).pass, true, 'the other side of the same view is fine');
});

test('the check: a plate on the car is blurred by the site; text off the car or a plate it cannot place refuses', () => {
  const plate = { box_2d: [720, 430, 770, 570] };
  const v = judgeCheck({ ...OK, plate_readable: true, plates: [plate] }, { shot: 'front_left', generated: false });
  assert.equal(v.pass, true);
  assert.equal(v.plates.length, 1);
  assert.ok(Math.abs(v.plates[0]!.x - 0.43) < 1e-9 && Math.abs(v.plates[0]!.y - 0.72) < 1e-9);
  assert.deepEqual(judgeCheck({ ...OK, plates: [{ box_2d: [100, 300, 160, 700] }] }, { shot: 'front_left', generated: false }).reasons, ['plate_off_car'], 'a "plate" on the wall');
  assert.deepEqual(judgeCheck({ ...OK, plate_readable: true, plates: [] }, { shot: 'rear', generated: false, edgesDark: true }).reasons, ['plate_readable']);
});

function textured(W: number, H: number): Rgba {
  const d = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) { const i = (y * W + x) * 4, v = ((x >> 1) + (y >> 1)) % 2 ? 250 : 5; d[i] = v; d[i + 1] = v; d[i + 2] = v; d[i + 3] = 255; }
  return { width: W, height: H, data: d };
}
test('the plate blur: no character can be read in the box, nothing outside it changes', () => {
  const img = textured(400, 300);
  const before = new Uint8ClampedArray(img.data);
  const box = { x: 0.4, y: 0.7, w: 0.2, h: 0.08 };
  const c0 = boxContrast(img, box);
  blurPlates(img, [box]);
  assert.ok(boxContrast(img, box) < c0 * 0.1, `contrast ${boxContrast(img, box)} vs ${c0}`);
  // far from the box: untouched
  for (const [x, y] of [[10, 10], [390, 290], [200, 50]] as const) { const i = (y * 400 + x) * 4; assert.equal(img.data[i], before[i]); }
});

// ---------------------------------------------------------------- the worker's r45 step
/** Gemini's answer in the fakes: the dark room all round (the edge check passes). */
const dark = (W: number, H: number): Rgba => ({ width: W, height: H, data: new Uint8ClampedArray(W * H * 4).map((_, i) => (i % 4 === 3 ? 255 : 24)) });
const JPEG = encodeJpeg(textured(64, 48), 80);
function deps(over: Partial<WorkerDeps> = {}) {
  const priv = new Map<string, Uint8Array>([['vehicles/v1/original/fl.jpg', JPEG], ['vehicles/v1/original/d.jpg', JPEG]]);
  const pub = new Map<string, Uint8Array>();
  const asked: Array<{ images: number; prompt: string }> = [];
  const d: WorkerDeps = {
    claim: async () => ({ jobs: [], budget: { ai_neurons_today: 0, ai_neurons_limit: 1, transformations_month: 0, transformations_free: 1 }, held: { photos: false, copy: false }, due: 0 }),
    report: async () => undefined, decodeVin: async () => ({ provider: 'x', result: { ok: false } }), text: fakeText(),
    photos: fakePhotos(async () => null),
    files: { privateUrl: async (p) => p, publicUrl: (p) => p, getPrivate: async (p) => priv.get(p) ?? null, putPrivate: async (p, b) => { priv.set(p, b); }, putPublic: async (p, b) => { pub.set(p, b); } },
    angleAi: async (i) => { asked.push({ images: i.images.length, prompt: i.prompt }); return { ok: true, bytes: encodeJpeg(dark(300, 200), 80), contentType: 'image/jpeg', provider: 'ai', model: 'gemini-2.5-flash-image' }; },
    checkPhoto: async () => ({ data: { ...OK, plates: [{ box_2d: [700, 420, 760, 560] }] }, model: 'gemini:gemini-2.5-flash' }),
    ...over
  };
  return { d, pub, asked };
}
const job = (over: Partial<JobContext> = {}): JobContext => ({ id: 'abcdef12-0000', kind: 'photo_r45', intake_id: 'i1', vehicle_id: 'v1', attempts: 1, max_attempts: 4,
  input: { r45: { mode: 'edit', car: CAR } }, photo: { id: 'p1', shot_type: 'front_left', angle: 'front_left', original_path: 'vehicles/v1/original/fl.jpg', processed_path: 'old.jpg',
    rebackground: true, is_public: true, file_base: 'cla-front-left' }, ...over });
const budget = { ai_neurons_today: 0, ai_neurons_limit: 1, transformations_month: 0, transformations_free: 1 };

test('r45: the original and the showroom go to Gemini, the check passes, the plate is blurred, the photo and its sizes stored', async () => {
  const { d, pub, asked } = deps();
  const r = await runJob(d, job(), budget);
  assert.equal(r.ok, true);
  const o = out(r);
  assert.equal(o.r45.pass, true);
  assert.equal(o.r45.spec, 'r45.1');
  assert.equal(o.r45.plates.length, 1);
  assert.equal(o.preset_version, 'gemini_r45');
  assert.equal(o.showroom.mode, 'edit');
  assert.deepEqual([o.width, o.height], [1800, 1200]);
  assert.ok(pub.has(o.processed_path) && o.processed_path.startsWith('vehicles/v1/cla-front-left-r45'));
  assert.deepEqual(o.variants.map((v) => v.width), [480, 800, 1200]);
  assert.equal(asked.length, 1);
  assert.equal(asked[0]!.images, 2, 'the original and the empty room');
  assert.match(asked[0]!.prompt, /replace the ENTIRE background/);
});

test('r45: refused by the check, nothing is stored; the daily limit waits; a generated view uses the car\'s photos', async () => {
  const bad = deps({ checkPhoto: async () => ({ data: { ...OK, original_background: true }, model: 'g' }) });
  const r = await runJob(bad.d, job(), budget);
  assert.equal(r.ok, true);
  assert.equal(out(r).r45.pass, false);
  assert.deepEqual(out(r).r45.reasons, ['original_background']);
  assert.equal(bad.pub.size, 0);
  const lim = deps({ angleAi: async () => ({ ok: false, reason: 'limit', message: 'today' }) });
  assert.equal(out(await runJob(lim.d, job(), budget)).r45.wait, 'limit');
  const g = deps({ checkPhoto: async () => ({ data: { ...OK, view: 'rear' }, model: 'g' }) });
  const r2 = await runJob(g.d, job({ input: { r45: { mode: 'generate', car: CAR, sources: ['vehicles/v1/original/fl.jpg', 'vehicles/v1/original/d.jpg'] } },
    photo: { id: 'p2', shot_type: 'rear', angle: 'rear', original_path: 'vehicles/v1/original/fl.jpg', processed_path: null, rebackground: true, is_public: true, file_base: 'cla-rear' } }), budget);
  assert.equal(out(r2).r45.pass, true);
  assert.equal(out(r2).r45.generated, true);
  assert.equal(g.asked[0]!.images, 3, 'two photos of the car and the room');
  assert.match(g.asked[0]!.prompt, /straight rear view/);
});

test('r45: a new upload (process_photo) is made the same way, never by the cut-out', async () => {
  let cut = 0;
  const { d } = deps();
  d.photos = { ...d.photos, cutout: async (u: string) => { cut++; return fakePhotos(async () => null).cutout(u); } };
  const r = await runJob(d, job({ kind: 'process_photo', input: {} }), budget);
  assert.equal(r.ok, true);
  assert.equal(out(r).r45.pass, true);
  assert.equal(cut, 0);
  const no = deps({ checkPhoto: async () => null });
  const r2 = await runJob(no.d, job({ kind: 'process_photo', input: {} }), budget);
  assert.equal(r2.ok, false, 'not checked: not published');
});
