// Unit tests for the r48 photo standard (features/listing/r48.ts) and the worker's r48 step (worker.ts makeR48), with a fake
// Gemini (no network). r48.4 (5080): the car alone on a flat key colour, keyed and put on the drawn dealership by the site;
// every image the words number is the image sent; the gate before the paid check; a render kept when its check did not
// answer; check-in photos sent when the car has no listing photo; the real photos cut out after the standard views.
//   node --test --experimental-strip-types src/features/listing/r48.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { HARD_REASONS, PLATE_FAMILIES, R48_ANGLES, R48_SPEC, REAL_PHOTO_RULE, feedbackLine, guidePath, imageRoles, judgePlate, judgeR48, plateEndOf, plateFamily, platePath, platePrompt,
  plateRule, r48Angle, r48CheckPrompt, r48ExtraPrompt, r48Prompt, viewReasons } from './r48.ts';
import { STANDARD_ANGLES } from './r45.ts';
import { encodeJpeg } from './showroom.ts';
import { STUDIO_FRAME } from './studio-gate.ts';
import { runJob, type JobContext, type JobResult, type WorkerDeps } from './worker.ts';
import { fakePhotos } from '../../integrations/photos/fake.ts';
import { fakeText } from '../../integrations/llm/fake.ts';
import type { Rgba } from './subject-frame.ts';

const CAR = { year: 2022, make: 'Mercedes-Benz', model: 'CLA 250', trim: '4MATIC', colour: 'Polar White' };

test('the nine angles: the r45 standard set in its order, the front three-quarter first, each with its framing', () => {
  assert.equal(R48_SPEC, 'r48.4');
  assert.deepEqual(R48_ANGLES.map((a) => a.shot), STANDARD_ANGLES.map((a) => a.shot));
  assert.equal(R48_ANGLES[0]!.shot, 'front_left');
  for (const a of R48_ANGLES) {
    assert.match(a.framing, /mm full-frame lens look/, `${a.shot}: a focal length`);
    assert.match(a.framing, /height|level/, `${a.shot}: a camera height`);
  }
  assert.match(r48Angle('front_left')!.framing, /nose points to the LEFT edge of the frame/, 'the sample covers\' direction');
  assert.match(r48Angle('rear_left')!.framing, /45 degrees/);
  assert.match(r48Angle('left')!.framing, /90 degrees/);
});

test('the guide of each angle per body type; the plate words stay for the marketing studio', () => {
  assert.deepEqual(['front_left', 'front', 'left', 'rear_left', 'rear', 'dashboard', 'trunk'].map(plateFamily), ['side', 'side', 'side', 'side', 'side', null, null]);
  assert.equal(guidePath('suv', 'front_left'), 'site/r48/guides/suv-lead.jpg');
  assert.equal(guidePath(null, 'rear_left'), 'site/r48/guides/sedan-rear34.jpg');
  assert.equal(guidePath('../x', 'left'), 'site/r48/guides/sedan-side.jpg', 'a body key is never a path');
  assert.equal(guidePath('suv', 'trunk'), null);
  assert.match(platePath('front', 'ab12'), /^site\/r48\/plates\/[a-z0-9-]+\.jpg$/);
  for (const f of PLATE_FAMILIES) assert.match(platePrompt(f), /A real photograph of a modern, minimal, dark car dealership/);
  assert.equal(judgePlate({ looks_real: true, has_text: false, has_logo: false, has_cars_or_people: false, free_floor: true }).pass, true);
});

test('r48.4 the words: the car alone on the key colour, every image numbered as sent, no room, no plate image, no sign asked', () => {
  const p = r48Prompt({ car: CAR, shot: 'front_left', refs: 4, guide: true, stock: true, key: 'green' });
  assert.match(p, /Images 1 to 4 are real photos of THIS car/);
  assert.match(p, /Image 5 is a composition guide/);
  assert.match(p, /Image 6 is a stock photo of the same model/);
  assert.doesNotMatch(p, /Image 7|background plate|CarmaCars sign|THE PLACE|contact shadow/, 'the room is the site\'s, never asked of the model');
  assert.match(p, /perfectly flat, uniform pure chroma-key green \(#00FF00\)/);
  assert.match(p, /WHOLE car is inside the frame with a clear margin/);
  for (const a of R48_ANGLES) assert.doesNotMatch(a.framing, /percent of the frame|on the floor|floor in front/, `${a.shot}: no size or floor asked that the key words contradict`);
  assert.match(p, /nose MUST point to the LEFT of the frame/);
  assert.match(p, /2022 Mercedes-Benz CLA 250 4MATIC, Polar White/);
  assert.ok(p.includes(REAL_PHOTO_RULE));
  assert.match(p, /removed cleanly/);
  assert.match(p, /NO TEXT AND NO LOGOS/);
  assert.doesNotMatch(p, /REFUSED/);
  assert.match(r48Prompt({ car: { ...CAR, colour: 'British Racing Green' }, shot: 'left', refs: 1, guide: false, stock: false, key: 'magenta' }), /magenta \(#FF00FF\)/);
  // inside: nothing keyed, no stock photo
  const i = r48Prompt({ car: CAR, shot: 'dashboard', refs: 2, guide: true, stock: true });
  assert.doesNotMatch(i, /chroma-key|stock photo/);
  assert.match(i, /no background is swapped/);
  assert.equal(imageRoles({ refs: 1, guide: false, stock: false, shot: 'trunk' }).length, 1);
  // the stock photo alone: it is image 1, the guide image 2 (the worker sends them in that order)
  const s = r48Prompt({ car: CAR, shot: 'front_left', refs: 0, guide: true, stock: true, stockOnly: true, key: 'green' });
  assert.match(s, /Image 1 is a stock photo of this exact model/);
  assert.match(s, /Image 2 is a composition guide/);
  // an extra photo: the car as it is, on the key
  const x = r48ExtraPrompt({ car: CAR, key: 'green' });
  assert.match(x, /Keep the car exactly as it is in the photo: the same camera angle/);
  assert.match(x, /pure chroma-key green/);
});

test('a retry is told why the last try was refused, the gate\'s reasons included', () => {
  const p = r48Prompt({ car: CAR, shot: 'rear', refs: 2, guide: false, stock: false, feedback: ['wrong_wheels', 'looks_cgi', 'gate_key_background'] });
  assert.match(p, /AN EARLIER TRY WAS REFUSED because the wheels were not the car's wheels; it looked like a render, not a photograph; the background was not one flat key colour/);
  assert.equal(feedbackLine([]), '');
  assert.equal(feedbackLine(['unknown']), '');
});

const OK = { wrong_colour: false, wrong_model: false, wrong_wheels: false, parts_changed: false, warped: false, looks_cgi: false, wrong_framing: false, original_background: false,
  text_elsewhere: false, plate_readable: false, blurry: false, clutter: false, view: 'front_left', nose: 'left', plates: [] as unknown[] };
test('the check: each problem refuses; the plate is blurred by the site', () => {
  assert.equal(judgeR48(OK, { shot: 'front_left' }).pass, true);
  assert.deepEqual(judgeR48(null, { shot: 'front_left' }).reasons, ['no_answer']);
  for (const k of ['wrong_colour', 'wrong_model', 'wrong_wheels', 'parts_changed', 'warped', 'looks_cgi', 'wrong_framing', 'text_elsewhere', 'blurry', 'original_background'] as const) {
    assert.deepEqual(judgeR48({ ...OK, [k]: true }, { shot: 'front_left' }).reasons, [k], k);
  }
  const plated = judgeR48({ ...OK, plate_readable: true, plates: [{ box_2d: [700, 420, 760, 560] }] }, { shot: 'front_left' });
  assert.deepEqual(plated.reasons, ['plate_left']);
  const late = judgeR48({ ...OK, plate_readable: true, plates: [{ box_2d: [700, 420, 760, 560] }] }, { shot: 'front_left', tries: 2 });
  assert.equal(late.pass, true);
  assert.equal(late.plates.length, 1);
  assert.deepEqual(judgeR48({ ...OK, plate_readable: true }, { shot: 'front_left' }).reasons, ['plate_readable']);
  assert.ok(judgeR48({ ...OK, plates: [{ box_2d: [50, 100, 120, 900] }] }, { shot: 'front_left' }).reasons.includes('plate_off_car'));
  assert.deepEqual(judgeR48({ ...OK, clutter: true, view: 'trunk', nose: 'none' }, { shot: 'trunk' }).reasons, ['clutter']);
  const words = r48CheckPrompt({ car: CAR, shot: 'left', key: 'green' });
  assert.match(words, /90 degrees/);
  assert.match(words, /flat pure chroma-key green background \(the background is wanted/);
  assert.doesNotMatch(words, /background plate|car_box|logo_wrong|name_wrong/, 'nothing asked that the site does itself');
});

test('r48.4 one view rule: the words say the nose MUST point the standard way, and the check refuses anything else', () => {
  // the words and the verdict agree: 3701 let "camera" pass the check and then refused it at the gate, after both were paid
  assert.deepEqual(viewReasons('front_left', 'front_left', 'camera'), ['wrong_direction']);
  assert.deepEqual(viewReasons('front_left', 'front_left', null), ['wrong_direction']);
  assert.deepEqual(viewReasons('front_left', 'front_right', 'left'), [], 'the same view of the other side, nose the standard way');
  assert.deepEqual(viewReasons('left', 'right', 'right'), ['wrong_direction']);
  assert.deepEqual(viewReasons('rear_left', 'rear_left', 'right'), []);
  assert.deepEqual(viewReasons('front', 'front', 'camera'), [], 'no direction rule straight on');
  assert.deepEqual(viewReasons('front', 'other', null), ['wrong_view']);
  assert.deepEqual(viewReasons('dashboard', 'dashboard', 'none'), []);
  assert.deepEqual(viewReasons('studio_extra', 'other', null), [], 'an extra photo keeps its own angle');
  assert.deepEqual(judgeR48({ ...OK, nose: 'camera' }, { shot: 'front_left', tries: 2 }).reasons, ['wrong_direction'], 'hard: never kept late');
  assert.deepEqual(judgeR48({ ...OK, view: 'rear' }, { shot: 'front_left' }).reasons, ['wrong_view']);
  const late = judgeR48({ ...OK, parts_changed: true, looks_cgi: true, wrong_framing: true }, { shot: 'front_left', tries: 2 });
  assert.equal(late.pass, true, 'looks alone pass on the third try');
  assert.deepEqual(late.soft?.sort(), ['looks_cgi', 'parts_changed', 'wrong_framing']);
  assert.ok(HARD_REASONS.includes('wrong_direction') && !HARD_REASONS.includes('looks_cgi'));
  assert.equal(judgeR48({ ...OK, wrong_framing: true, view: 'other', nose: 'none' }, { shot: 'studio_extra' }).pass, true, 'an extra photo: no framing or view rule');
});

// ---------------------------------------------------------------- the worker with a fake Gemini
const room = (W: number, H: number): Rgba => ({ width: W, height: H, data: new Uint8ClampedArray(W * H * 4).map((_, i) => (i % 4 === 3 ? 255 : 120)) });
const JPEG = encodeJpeg(room(64, 48), 80);
/** What Gemini is asked for: the car (a grey body with dark wheels) alone on flat green, inside the frame. */
function keyedCar(o: { bg?: [number, number, number]; x0?: number; x1?: number } = {}): Rgba {
  const W = 300, H = 200, d = new Uint8ClampedArray(W * H * 4);
  const bg = o.bg ?? [0, 255, 0], x0 = o.x0 ?? 0.15, x1 = o.x1 ?? 0.85;
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const fx = x / W, fy = y / H, i = (y * W + x) * 4;
    let c = bg;
    if (fx >= x0 && fx <= x1 && fy >= 0.35 && fy <= 0.7) c = [150, 152, 158];
    if (fy > 0.62 && fy <= 0.72 && ((fx >= x0 + 0.08 && fx <= x0 + 0.2) || (fx >= x1 - 0.2 && fx <= x1 - 0.08))) c = [20, 20, 20];
    d[i] = c[0]; d[i + 1] = c[1]; d[i + 2] = c[2]; d[i + 3] = 255;
  }
  return { width: W, height: H, data: d };
}
const CAR_JPEG = encodeJpeg(keyedCar(), 95);
type Out = { r45: { pass: boolean; spec: string; reasons: string[]; wait?: string; why?: string; generated?: boolean; refs?: number; handover_refs?: number; stock_only?: boolean; key?: string;
    gate?: { pass: boolean; measures: { win?: unknown; car?: { x: number; w: number } } } };
  preset_version: string; processed_path: string; width: number; showroom: { mode: string; background?: string } };
const out = (r: JobResult) => r.output as unknown as Out;
function deps(over: Partial<WorkerDeps> = {}, answers: unknown[] = [OK]) {
  const priv = new Map<string, Uint8Array>([['vehicles/v1/original/fl.jpg', JPEG], ['vehicles/v1/original/rear.jpg', JPEG]]);
  const cond = new Map<string, Uint8Array>([['reports/r1/front_left.jpg', JPEG], ['reports/r1/rear.jpg', JPEG]]);
  const pub = new Map<string, Uint8Array>([['site/r48/guides/sedan-lead.jpg', JPEG], ['seo-photos/mercedes-benz/cla/2020-2024-1280.webp', JPEG]]);
  const asked: Array<{ images: number; prompt: string }> = [];
  const checks: Array<{ images: number; prompt: string }> = [];
  let k = 0;
  const d: WorkerDeps = {
    claim: async () => ({ jobs: [], budget: { ai_neurons_today: 0, ai_neurons_limit: 1, transformations_month: 0, transformations_free: 1 }, held: { photos: false, copy: false }, due: 0 }),
    report: async () => undefined, decodeVin: async () => ({ provider: 'x', result: { ok: false } }), text: fakeText(),
    photos: fakePhotos(async () => null),
    files: { privateUrl: async (p) => p, publicUrl: (p) => p, getPrivate: async (p) => priv.get(p) ?? null, putPrivate: async (p, b) => { priv.set(p, b); },
      putPublic: async (p, b) => { pub.set(p, b); }, getPublic: async (p) => pub.get(p) ?? null, getCondition: async (p) => cond.get(p) ?? null,
      removePrivate: async (p) => { priv.delete(p); } },
    angleAi: async (i) => { asked.push({ images: i.images.length, prompt: i.prompt }); return { ok: true, bytes: CAR_JPEG, contentType: 'image/jpeg', provider: 'ai', model: 'gemini-2.5-flash-image' }; },
    checkPhoto: async (i) => { checks.push({ images: i.images.length, prompt: i.prompt }); const a = answers[Math.min(k++, answers.length - 1)]; return { data: a, model: 'gemini:gemini-2.5-flash' }; },
    ...over
  };
  return { d, pub, priv, asked, checks };
}
const refs = [{ bucket: 'vehicle-originals', path: 'vehicles/v1/original/fl.jpg', from: 'listing' as const }, { bucket: 'vehicle-originals', path: 'vehicles/v1/original/rear.jpg', from: 'listing' as const }];
const job = (over: Partial<JobContext> = {}, inp: Record<string, unknown> = {}): JobContext => ({ id: 'abcdef12-0000', kind: 'photo_r45', intake_id: 'i1', vehicle_id: 'v1', attempts: 1, max_attempts: 4,
  input: { r45: { mode: 'r48', car: CAR, shot: 'front_left', refs, guide: 'site/r48/guides/sedan-lead.jpg', stock: 'seo-photos/mercedes-benz/cla/2020-2024-1280.webp', body: 'sedan', ...inp } },
  photo: { id: 'p1', shot_type: 'front_left', angle: 'front_left', original_path: 'vehicles/v1/original/fl.jpg', processed_path: null, rebackground: true, is_public: false, file_base: 'cla-r48-front-left' }, ...over });
const budget = { ai_neurons_today: 0, ai_neurons_limit: 1, transformations_month: 0, transformations_free: 1 };
const PENDING = 'vehicles/v1/original/r48-pending-p1';

test('r48.4 pass: the photos, the guide and the stock photo go to Gemini as numbered; the car is keyed and put on the dealership at its place', async () => {
  const { d, pub, priv, asked, checks } = deps();
  const r = await runJob(d, job(), budget);
  const o = out(r);
  assert.equal(o.r45.pass, true, JSON.stringify(o.r45));
  assert.equal(o.r45.spec, 'r48.4');
  assert.equal(o.preset_version, 'gemini_r48');
  assert.equal(o.width, 1800);
  assert.ok(pub.has(o.processed_path) && o.processed_path.includes('-r48'));
  assert.equal(asked.length, 1);
  assert.equal(asked[0]!.images, 4, 'two real photos, the guide, the stock photo');
  assert.match(asked[0]!.prompt, /Images 1 to 2 are real photos of THIS car.*Image 3 is a composition guide.*Image 4 is a stock photo/);
  assert.equal(checks.length, 1);
  assert.equal(checks[0]!.images, 3, 'the render and the two real photos');
  // the car stands at the front three-quarter's place, the same for every car
  const g = o.r45.gate!;
  assert.equal(g.pass, true);
  assert.deepEqual(g.measures.win, { x: 0, y: 0, w: 1, h: 1 });
  assert.ok(Math.abs(g.measures.car!.w - STUDIO_FRAME.front_left!.width) < 0.03, JSON.stringify(g.measures.car));
  assert.ok(!priv.has(PENDING), 'the kept render is dropped once judged');
});

test('r48.4 the cover keeps its empty room (the drive-off matte\'s plate), another view not; a green car is keyed on magenta', async () => {
  const cover = deps();
  const r = out(await runJob(cover.d, job(), budget));
  assert.equal(r.r45.pass, true, JSON.stringify(r.r45));
  assert.match(String(r.showroom.background), /^site\/r48\/backdrops\/v1-[a-f0-9]+\.jpg$/);
  assert.ok(cover.pub.has(r.showroom.background!));
  const side = deps({}, [{ ...OK, view: 'left' }]);
  const r2 = out(await runJob(side.d, job({ photo: { id: 'p1', shot_type: 'left', angle: 'left', original_path: 'x', processed_path: null, rebackground: true, is_public: false, file_base: 'cla-left' } }, { shot: 'left', guide: null }), budget));
  assert.equal(r2.r45.pass, true, JSON.stringify(r2.r45));
  assert.equal(r2.showroom.background, undefined);
  const green = deps({ angleAi: async () => ({ ok: true, bytes: encodeJpeg(keyedCar({ bg: [255, 0, 255] }), 95), contentType: 'image/jpeg', provider: 'ai', model: 'm' }) });
  const g = out(await runJob(green.d, job({}, { car: { ...CAR, colour: 'Olive Green' } }), budget));
  assert.equal(g.r45.pass, true, JSON.stringify(g.r45));
  assert.equal(g.r45.key, 'magenta');
});

test('r48.4 the gate runs first, free: a room instead of the key or a car cut off is refused before the paid check', async () => {
  const roomy = deps({ angleAi: async () => ({ ok: true, bytes: encodeJpeg(keyedCar({ bg: [60, 60, 64] }), 95), contentType: 'image/jpeg', provider: 'ai', model: 'm' }) });
  const r = out(await runJob(roomy.d, job(), budget));
  assert.equal(r.r45.pass, false);
  assert.ok(r.r45.reasons.includes('gate_key_background'), JSON.stringify(r.r45));
  assert.equal(roomy.checks.length, 0, 'no check paid for a render the gate refuses');
  assert.ok(!roomy.priv.has(PENDING));
  const cut = deps({ angleAi: async () => ({ ok: true, bytes: encodeJpeg(keyedCar({ x0: 0, x1: 0.9 }), 95), contentType: 'image/jpeg', provider: 'ai', model: 'm' }) });
  const r2 = out(await runJob(cut.d, job(), budget));
  assert.deepEqual(r2.r45.reasons, ['gate_key_cropped']);
  assert.equal(cut.checks.length, 0);
});

test('r48.4 a check that does not answer keeps the render: the next try checks it, Gemini is not paid twice', async () => {
  let up = false;
  const s = deps({ checkPhoto: async () => (up ? { data: OK, model: 'm' } : null) });
  const r = out(await runJob(s.d, job(), budget));
  assert.equal(r.r45.wait, 'retry');
  assert.ok(s.priv.has(PENDING), 'kept');
  up = true;
  const r2 = out(await runJob(s.d, job(), budget));
  assert.equal(r2.r45.pass, true, JSON.stringify(r2.r45));
  assert.equal(s.asked.length, 1, 'made once');
  assert.ok(!s.priv.has(PENDING));
});

test('r48 refuse: nothing published, the render dropped, the reasons returned (the database tries again with them)', async () => {
  const { d, pub, priv } = deps({}, [{ ...OK, looks_cgi: true, wrong_wheels: true }]);
  const before = pub.size;
  const r = out(await runJob(d, job(), budget));
  assert.equal(r.r45.pass, false);
  assert.deepEqual(r.r45.reasons.sort(), ['looks_cgi', 'wrong_wheels']);
  assert.equal(pub.size, before, 'nothing stored');
  assert.ok(!priv.has(PENDING), 'a new render next time, told why');
  const camera = deps({}, [{ ...OK, nose: 'camera' }]);
  assert.deepEqual(out(await runJob(camera.d, job(), budget)).r45.reasons, ['wrong_direction'], 'the words say MUST: the check refuses it, as the gate used to after both were paid');
});

test('r48 retry words; Gemini\'s limit and no key wait; nothing to make it from is refused without a call', async () => {
  const fb = deps();
  assert.equal(out(await runJob(fb.d, job({}, { feedback: ['looks_cgi'] }), budget)).r45.pass, true);
  assert.match(fb.asked[0]!.prompt, /AN EARLIER TRY WAS REFUSED because it looked like a render/);
  const lim = deps({ angleAi: async () => ({ ok: false, reason: 'limit', message: 'today' }) });
  assert.equal(out(await runJob(lim.d, job(), budget)).r45.wait, 'limit');
  const nokey = deps({ angleAi: null });
  assert.equal(out(await runJob(nokey.d, job(), budget)).r45.wait, 'no_key');
  const none = deps();
  const r2 = out(await runJob(none.d, job({}, { refs: [{ bucket: 'vehicle-originals', path: 'missing.jpg' }], stock: null }), budget));
  assert.equal(r2.r45.pass, false);
  assert.match(String(r2.r45.why), /could not be read/);
  assert.equal(none.asked.length, 0, 'no paid call');
  const blocked = deps({ angleAi: async () => ({ ok: false, reason: 'blocked', message: 'SAFETY' }) });
  assert.equal(out(await runJob(blocked.d, job(), budget)).r45.wait, undefined, 'a refusal of the content counts as a try');
});

test('r48.4 check-in photos: sent to Gemini when the car has no listing photo (5080), counted, never stored', async () => {
  const { d, pub, asked } = deps();
  const keys = new Set(pub.keys());
  const hand = [{ bucket: 'condition-photos', path: 'reports/r1/front_left.jpg', from: 'handover' as const }, { bucket: 'condition-photos', path: 'reports/r1/rear.jpg', from: 'handover' as const }];
  const r = out(await runJob(d, job({}, { refs: hand }), budget));
  assert.equal(r.r45.pass, true, JSON.stringify(r.r45));
  assert.equal(r.r45.handover_refs, 2);
  assert.equal(asked[0]!.images, 4, 'both check-in photos, the guide, the stock photo: as the words number them');
  assert.match(asked[0]!.prompt, /Images 1 to 2 are real photos of THIS car/);
  assert.ok([...pub.keys()].filter((k) => !keys.has(k)).every((k) => k.includes('-r48') || k.startsWith('site/r48/backdrops/')), 'only the made view, its sizes and the cover\'s empty room are stored');
  const odd = deps();
  assert.equal(out(await runJob(odd.d, job({}, { refs: [{ bucket: 'identity', path: 'x.jpg' }], stock: null }), budget)).r45.pass, false, 'a bucket the worker does not know is never read');
});

test('r48.4 a car with no photo: the stock photo is sent first, as the words say; no inside view is invented from it', async () => {
  const { d, asked, checks } = deps();
  const r = out(await runJob(d, job({}, { refs: [], tries: 2 }), budget));
  assert.equal(r.r45.pass, true, JSON.stringify(r.r45));
  assert.equal(r.r45.stock_only, true);
  assert.equal(asked[0]!.images, 2, 'the stock photo, then the guide');
  assert.match(asked[0]!.prompt, /Image 1 is a stock photo of this exact model.*Image 2 is a composition guide/);
  assert.equal(checks[0]!.images, 2, 'the render and the stock photo');
  const inside = deps();
  const r2 = out(await runJob(inside.d, job({ photo: { id: 'p9', shot_type: 'trunk', angle: 'trunk', original_path: 'x', processed_path: null, rebackground: false, is_public: false, file_base: 'cla-trunk' } },
    { shot: 'trunk', refs: [], guide: null }), budget));
  assert.equal(r2.r45.pass, false);
  assert.equal(inside.asked.length, 0);
});

test('r48 inside: nothing keyed, no stock photo, kept as made', async () => {
  const { d, asked } = deps({ angleAi: async (i) => { asked.push({ images: i.images.length, prompt: i.prompt }); return { ok: true, bytes: JPEG, contentType: 'image/jpeg', provider: 'ai', model: 'm' }; } },
    [{ ...OK, view: 'trunk', nose: 'none' }]);
  const r = out(await runJob(d, job({ photo: { id: 'p9', shot_type: 'trunk', angle: 'trunk', original_path: 'x', processed_path: null, rebackground: false, is_public: false, file_base: 'cla-trunk' } },
    { shot: 'trunk', guide: null }), budget));
  assert.equal(r.r45.pass, true, JSON.stringify(r.r45));
  assert.equal(asked[0]!.images, 2, 'the two real photos only');
  assert.equal(r.width, 1600);
});

test('r48.4 an extra photo: its one real photo, cut out on the key, put on the same dealership', async () => {
  const { d, asked, checks } = deps({}, [{ ...OK, view: 'right', nose: 'right', wrong_framing: true }]);
  const r = out(await runJob(d, job({ photo: { id: 'p7', shot_type: 'studio_extra', angle: 'studio_extra', original_path: 'x', processed_path: null, rebackground: true, is_public: false, file_base: 'cla-extra-1' } },
    { extra: true, shot: 'studio_extra', refs: [refs[0]], guide: null, stock: null }), budget));
  assert.equal(r.r45.pass, true, JSON.stringify(r.r45));
  assert.equal(asked[0]!.images, 1);
  assert.match(asked[0]!.prompt, /Keep the car exactly as it is in the photo/);
  assert.equal(checks[0]!.images, 2);
  assert.deepEqual(r.r45.gate!.measures.win, { x: 0, y: 0, w: 1, h: 1 });
});

// ---------------------------------------------------------------- 3040: a plate only where the car has one, never a large box
test('3040 the plate words: no plate at an end leaves that bumper untouched; a front view says so; never a blank plate', () => {
  const none = r48Prompt({ car: CAR, shot: 'front', refs: 2, guide: false, stock: false, plateEnd: 'no' });
  assert.match(none, /THIS CAR HAS NO FRONT PLATE/);
  assert.match(none, /no plate, holder, rectangle, blur or box/);
  assert.doesNotMatch(none, /blank plate holder/);
  const unknown = r48Prompt({ car: CAR, shot: 'front_left', refs: 2, guide: false, stock: false });
  assert.match(unknown, /This is a front view: if the real photos show no front plate, the front bumper stays bare and untouched/);
  assert.match(unknown, /many Ontario cars have no front plate/);
  const rear = r48Prompt({ car: CAR, shot: 'rear', refs: 2, guide: false, stock: false, plateEnd: 'yes' });
  assert.match(rear, /carries a rear plate: take it off cleanly so the bare rear bumper shows/);
  assert.match(plateRule('left'), /This view shows no plate/);
  assert.equal(plateEndOf('front_left'), 'front');
  assert.equal(plateEndOf('rear'), 'rear');
  assert.equal(plateEndOf('left'), null);
  const check = r48CheckPrompt({ car: CAR, shot: 'front', plateEnd: 'no' });
  for (const k of ['plate_present', 'plate_cover', 'real_plate']) assert.match(check, new RegExp(`"${k}"`));
  assert.match(check, /an empty plate recess or bracket is not a plate/);
});

test('3040 the check: a blur or box where no plate is, a large cover, or an added plate always refuse; no plate, no box', () => {
  // a front bumper with no plate, left alone: passes, nothing to blur
  const bare = judgeR48({ ...OK, view: 'front', plate_present: false, plate_cover: false, real_plate: 'no' }, { shot: 'front', plateEnd: 'no' });
  assert.equal(bare.pass, true);
  assert.deepEqual(bare.plates, []);
  // the check says no plate is there but still boxed the bumper: the box is dropped (the site never blurs a bare bumper)
  const phantomBox = judgeR48({ ...OK, view: 'front', plate_present: false, plates: [{ box_2d: [700, 420, 760, 560] }] }, { shot: 'front', plateEnd: 'no' });
  assert.equal(phantomBox.pass, true);
  assert.deepEqual(phantomBox.plates, []);
  // a blur, box or blank patch where a plate is or would be: refused, even on the last try
  for (const tries of [0, 2]) {
    const patch = judgeR48({ ...OK, view: 'front', plate_cover: true }, { shot: 'front', tries, plateEnd: 'no' });
    assert.equal(patch.pass, false);
    assert.ok(patch.reasons.includes('plate_patch'), String(tries));
  }
  // a plate drawn on an end of the car that has none: refused, even late
  const added = judgeR48({ ...OK, view: 'front', plate_present: true, plates: [{ box_2d: [700, 440, 740, 560] }] }, { shot: 'front', tries: 2, plateEnd: 'no' });
  assert.deepEqual(added.reasons, ['plate_added']);
  assert.ok(judgeR48({ ...OK, view: 'front', plate_present: true, real_plate: 'no', plates: [{ box_2d: [700, 440, 740, 560] }] }, { shot: 'front', tries: 2 }).reasons.includes('plate_added'));
  // a plate box far larger than a plate in that view: refused, never blurred
  const big = judgeR48({ ...OK, view: 'front_left', plate_present: true, plates: [{ box_2d: [600, 300, 900, 700] }] }, { shot: 'front_left', tries: 2 });
  assert.ok(big.reasons.includes('plate_oversized'));
  assert.deepEqual(big.plates, []);
  // interiors: never a plate box
  assert.deepEqual(judgeR48({ ...OK, view: 'dashboard', plates: [{ box_2d: [700, 440, 740, 560] }] }, { shot: 'dashboard' }).plates, []);
});

