// Unit tests for the r48 photo standard (features/listing/r48.ts) and the worker's r48 step (worker.ts makeR48), with a fake
// Gemini (no network): pass, refuse, retry with feedback, keep the real photo, the plate made once, check-in photos as
// references (read, never stored).
//   node --test --experimental-strip-types src/features/listing/r48.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { BACKGROUND_SAME, DEFAULT_SCENE, HARD_REASONS, borderDiff } from './r48.ts';
import { plateEndOf, plateRule, PLATE_FAMILIES, R48_ANGLES, R48_SPEC, feedbackLine, guidePath, imageRoles, judgePlate, judgeR48, plateFamily, platePath, platePrompt, r48Angle, r48CheckPrompt, r48Prompt,
  REAL_PHOTO_RULE } from './r48.ts';
import { STANDARD_ANGLES } from './r45.ts';
import { encodeJpeg } from './showroom.ts';
import { FRAME_ASK, STUDIO_FRAME } from './studio-gate.ts';
import { runJob, type JobContext, type JobResult, type WorkerDeps } from './worker.ts';
import { fakePhotos } from '../../integrations/photos/fake.ts';
import { fakeText } from '../../integrations/llm/fake.ts';
import type { Rgba } from './subject-frame.ts';

const CAR = { year: 2022, make: 'Mercedes-Benz', model: 'CLA 250', trim: '4MATIC', colour: 'Polar White' };

test('the nine angles: the r45 standard set in its order, the front three-quarter first, each with its framing', () => {
  assert.equal(R48_SPEC, 'r48.3');
  assert.deepEqual(R48_ANGLES.map((a) => a.shot), STANDARD_ANGLES.map((a) => a.shot));
  assert.equal(R48_ANGLES[0]!.shot, 'front_left');
  for (const a of R48_ANGLES) {
    assert.match(a.framing, /mm full-frame lens look/, `${a.shot}: a focal length`);
    assert.match(a.framing, /height|level/, `${a.shot}: a camera height`);
  }
  assert.match(r48Angle('front_left')!.framing, /nose points to the LEFT edge of the frame/, 'the sample covers\' direction');
  assert.match(r48Angle('rear_left')!.framing, /45 degrees/);
  assert.match(r48Angle('left')!.framing, /90 degrees/);
  assert.match(r48Angle('front_left')!.framing, /centred/);
});

test('plate families: outside angles only; the guide of each angle per body type', () => {
  assert.deepEqual(['front_left', 'front', 'left', 'rear_left', 'rear', 'dashboard', 'trunk'].map(plateFamily), ['side', 'side', 'side', 'side', 'side', null, null]);
  assert.deepEqual(PLATE_FAMILIES, ['front', 'side', 'rear']);
  assert.equal(guidePath('suv', 'front_left'), 'site/r48/guides/suv-lead.jpg');
  assert.equal(guidePath(null, 'rear_left'), 'site/r48/guides/sedan-rear34.jpg');
  assert.equal(guidePath('../x', 'left'), 'site/r48/guides/sedan-side.jpg', 'a body key is never a path');
  assert.equal(guidePath('suv', 'trunk'), null);
  assert.equal(platePath('side'), 'site/r48/plates/side.jpg');
  assert.match(platePath('front', 'ab12'), /^site\/r48\/plates\/[a-z0-9-]+\.jpg$/);
});

test('the generation words: every reference named in order, the framing, identity, real-photo cues, plates removed, only the sign', () => {
  const p = r48Prompt({ car: CAR, shot: 'front_left', refs: 4, guide: true, stock: true, plate: true });
  assert.match(p, /Images 1 to 4 are real photos of THIS car/);
  assert.match(p, /Image 5 is a composition guide/);
  assert.match(p, /Image 6 is a stock photo of the same model/);
  assert.match(p, /Image 7, the last, is the background plate/);
  assert.match(p, /TARGET FRAMING: front three-quarter .*30 degrees/);
  assert.match(p, /nose MUST point to the LEFT of the frame/);
  assert.match(p, /2022 Mercedes-Benz CLA 250 4MATIC, Polar White/);
  assert.match(p, /same wheels/);
  assert.match(p, /damage-free/);
  assert.ok(p.includes(REAL_PHOTO_RULE));
  assert.match(p, /contact shadow/);
  assert.match(p, /not a 3D render or CGI/);
  assert.match(p, /removed cleanly/);
  assert.doesNotMatch(p, /blur its face/);
  assert.match(p, /NO OTHER TEXT/);
  assert.match(p, /CarmaCars sign/, 'the dealership keeps its sign');
  assert.doesNotMatch(p, /REFUSED/);
  // inside: no plate, no stock photo, no background swap
  const i = r48Prompt({ car: CAR, shot: 'dashboard', refs: 2, guide: true, stock: true, plate: true });
  assert.doesNotMatch(i, /background plate/);
  assert.doesNotMatch(i, /stock photo/);
  assert.match(i, /no background is swapped/);
  assert.deepEqual(imageRoles({ refs: 1, guide: false, stock: false, plate: false, shot: 'trunk' }).length, 1);
  // without a stored plate: the room in words
  assert.match(r48Prompt({ car: CAR, shot: 'left', refs: 1, guide: false, stock: false, plate: false }), /dark car dealership showroom/);
});

test('a retry is told why the last try was refused', () => {
  const p = r48Prompt({ car: CAR, shot: 'rear', refs: 2, guide: false, stock: false, plate: true, feedback: ['wrong_wheels', 'looks_cgi', 'wrong_wheels'] });
  assert.match(p, /AN EARLIER TRY WAS REFUSED because the wheels were not the car's wheels; it looked like a render, not a photograph\. Fix exactly that/);
  assert.equal(feedbackLine([]), '');
  assert.equal(feedbackLine(['unknown']), '');
});

const OK = { wrong_colour: false, wrong_model: false, wrong_wheels: false, parts_changed: false, warped: false, looks_cgi: false, wrong_framing: false, background_wrong: false,
  text_elsewhere: false, plate_readable: false, blurry: false, clutter: false, view: 'front_left', plates: [] as unknown[] };
test('the check: each problem refuses; the plate is blurred by the site; the view must be the asked one', () => {
  assert.equal(judgeR48(OK, { shot: 'front_left', plate: true }).pass, true);
  assert.deepEqual(judgeR48(null, { shot: 'front_left', plate: true }).reasons, ['no_answer']);
  for (const k of ['wrong_colour', 'wrong_model', 'wrong_wheels', 'parts_changed', 'warped', 'looks_cgi', 'wrong_framing', 'text_elsewhere', 'blurry'] as const) {
    assert.deepEqual(judgeR48({ ...OK, [k]: true }, { shot: 'front_left', plate: true }).reasons, [k], k);
  }
  assert.deepEqual(judgeR48({ ...OK, background_wrong: true }, { shot: 'front_left', plate: true }).reasons, ['background_wrong']);
  assert.equal(judgeR48({ ...OK, background_wrong: true, view: 'dashboard' }, { shot: 'dashboard', plate: false }).pass, true, 'no plate inside');
  assert.deepEqual(judgeR48({ ...OK, view: 'rear' }, { shot: 'front_left', plate: true }).reasons, ['wrong_view']);
  assert.equal(judgeR48({ ...OK, view: 'front_right' }, { shot: 'front_left', plate: true }).pass, true, 'a three-quarter from the other side');
  // 3040: a plate left on the car refuses the first tries (it must be taken off cleanly), then is blurred by the site
  const plated = judgeR48({ ...OK, plate_readable: true, plates: [{ box_2d: [700, 420, 760, 560] }] }, { shot: 'front_left', plate: true });
  assert.deepEqual(plated.reasons, ['plate_left']);
  const late = judgeR48({ ...OK, plate_readable: true, plates: [{ box_2d: [700, 420, 760, 560] }] }, { shot: 'front_left', plate: true, tries: 2 });
  assert.equal(late.pass, true);
  assert.equal(late.plates.length, 1);
  assert.deepEqual(judgeR48({ ...OK, plate_readable: true }, { shot: 'front_left', plate: true }).reasons, ['plate_readable']);
  assert.ok(judgeR48({ ...OK, plates: [{ box_2d: [50, 100, 120, 900] }] }, { shot: 'front_left', plate: true }).reasons.includes('plate_off_car'));
  assert.deepEqual(judgeR48({ ...OK, clutter: true, view: 'trunk' }, { shot: 'trunk', plate: false }).reasons, ['clutter']);
  const words = r48CheckPrompt({ car: CAR, shot: 'left', plate: true });
  assert.match(words, /90 degrees/);
  assert.match(words, /looks_cgi/);
  assert.match(words, /the last one is the background plate/);
});

test('the plates: words for a real, empty showroom; used only when the check says it looks real', () => {
  for (const f of PLATE_FAMILIES) {
    const w = platePrompt(f);
    assert.match(w, /A real photograph of a modern, minimal, dark car dealership/);
    assert.match(w, /CarmaCars sign exactly as drawn/);
    assert.match(w, /Not a 3D render/);
    const h = platePrompt(f, { code: 'highway', place: 'the paved shoulder of an open highway' });
    assert.match(h, /paved shoulder of an open highway, empty/);
    assert.match(h, /No text, no logos/);
  }
  assert.match(platePrompt('side'), /square to the background/);
  assert.deepEqual(judgePlate({ looks_real: true, has_text: false, has_logo: false, has_cars_or_people: false, free_floor: true }), { pass: true, reasons: [] });
  assert.deepEqual(judgePlate({ looks_real: false, has_text: true, has_logo: true, has_cars_or_people: true, free_floor: false }).reasons, ['not_real', 'text', 'logo', 'cars_or_people', 'no_free_floor']);
  assert.equal(judgePlate(null).pass, false);
});

// ---------------------------------------------------------------- the worker with a fake Gemini
const room = (W: number, H: number): Rgba => ({ width: W, height: H, data: new Uint8ClampedArray(W * H * 4).map((_, i) => (i % 4 === 3 ? 255 : 120)) });
const JPEG = encodeJpeg(room(64, 48), 80);
// r50 (3701): the plate is a two-tone studio; Gemini's fake result is that studio with a car (and its contact shadow) placed
// a little smaller than the front three-quarter's target, as the words ask; the check reports the car's box
const T = STUDIO_FRAME.front_left!;
const CAR_BOX = { x: T.cx - (T.width * FRAME_ASK) / 2, y: T.bottom - 0.32, w: T.width * FRAME_ASK, h: 0.32 };
function studioRoom(car: boolean): Rgba {
  const W = 300, H = 200, d = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const fx = x / W, fy = y / H, i = (y * W + x) * 4;
    let c = fy < 0.6 ? [40, 40, 44] : [22, 22, 24];
    if (car && fx >= CAR_BOX.x && fx <= CAR_BOX.x + CAR_BOX.w && fy >= CAR_BOX.y && fy <= CAR_BOX.y + CAR_BOX.h) c = [200, 200, 205];
    if (car && fx >= CAR_BOX.x + CAR_BOX.w * 0.1 && fx <= CAR_BOX.x + CAR_BOX.w * 0.9 && fy >= CAR_BOX.y + CAR_BOX.h - 0.015 && fy <= CAR_BOX.y + CAR_BOX.h + 0.015) c = [3, 3, 3];
    d[i] = c[0]!; d[i + 1] = c[1]!; d[i + 2] = c[2]!; d[i + 3] = 255;
  }
  return { width: W, height: H, data: d };
}
const PLATE_JPEG = encodeJpeg(studioRoom(false), 95);
const box1000 = [CAR_BOX.y, CAR_BOX.x, CAR_BOX.y + CAR_BOX.h, CAR_BOX.x + CAR_BOX.w].map((n) => Math.round(n * 1000));
const WOK = { ...OK, nose: 'left', car_box: box1000 };
type Out = { r45: { pass: boolean; spec: string; reasons: string[]; wait?: string; generated?: boolean; refs?: number; handover_refs?: number; plate_made?: { family: string; path: string } };
  preset_version: string; processed_path: string; showroom: { mode: string } };
const out = (r: JobResult) => r.output as unknown as Out;
function deps(over: Partial<WorkerDeps> = {}, answers: unknown[] = [WOK]) {
  const priv = new Map<string, Uint8Array>([['vehicles/v1/original/fl.jpg', JPEG], ['vehicles/v1/original/rear.jpg', JPEG]]);
  const cond = new Map<string, Uint8Array>([['reports/r1/front_left.jpg', JPEG], ['reports/r1/rear.jpg', JPEG]]);
  const pub = new Map<string, Uint8Array>([['site/r48/plates/front.jpg', PLATE_JPEG], ['site/r48/guides/sedan-lead.jpg', JPEG], ['seo-photos/mercedes-benz/cla/2020-2024-1280.webp', JPEG]]);
  const asked: Array<{ images: number; prompt: string }> = [];
  const checks: Array<{ images: number; prompt: string }> = [];
  let k = 0;
  const d: WorkerDeps = {
    claim: async () => ({ jobs: [], budget: { ai_neurons_today: 0, ai_neurons_limit: 1, transformations_month: 0, transformations_free: 1 }, held: { photos: false, copy: false }, due: 0 }),
    report: async () => undefined, decodeVin: async () => ({ provider: 'x', result: { ok: false } }), text: fakeText(),
    photos: fakePhotos(async () => null),
    files: { privateUrl: async (p) => p, publicUrl: (p) => p, getPrivate: async (p) => priv.get(p) ?? null, putPrivate: async (p, b) => { priv.set(p, b); },
      putPublic: async (p, b) => { pub.set(p, b); }, getPublic: async (p) => pub.get(p) ?? null, getCondition: async (p) => cond.get(p) ?? null },
    angleAi: async (i) => { asked.push({ images: i.images.length, prompt: i.prompt }); return { ok: true, bytes: encodeJpeg(studioRoom(true), 95), contentType: 'image/jpeg', provider: 'ai', model: 'gemini-2.5-flash-image' }; },
    checkPhoto: async (i) => { checks.push({ images: i.images.length, prompt: i.prompt }); const a = answers[Math.min(k++, answers.length - 1)]; return { data: a, model: 'gemini:gemini-2.5-flash' }; },
    ...over
  };
  return { d, pub, priv, asked, checks };
}
const refs = [{ bucket: 'vehicle-originals', path: 'vehicles/v1/original/fl.jpg', from: 'listing' as const }, { bucket: 'vehicle-originals', path: 'vehicles/v1/original/rear.jpg', from: 'listing' as const }];
const job = (over: Partial<JobContext> = {}, inp: Record<string, unknown> = {}): JobContext => ({ id: 'abcdef12-0000', kind: 'photo_r45', intake_id: 'i1', vehicle_id: 'v1', attempts: 1, max_attempts: 4,
  input: { r45: { mode: 'r48', car: CAR, shot: 'front_left', refs, family: 'front', plate: 'site/r48/plates/front.jpg', guide: 'site/r48/guides/sedan-lead.jpg',
    stock: 'seo-photos/mercedes-benz/cla/2020-2024-1280.webp', body: 'sedan', ...inp } },
  photo: { id: 'p1', shot_type: 'front_left', angle: 'front_left', original_path: 'vehicles/v1/original/fl.jpg', processed_path: null, rebackground: true, is_public: false, file_base: 'cla-r48-front-left' }, ...over });
const budget = { ai_neurons_today: 0, ai_neurons_limit: 1, transformations_month: 0, transformations_free: 1 };

test('r48 pass: the real photos, the guide, the stock photo and the plate go to Gemini; the check passes; stored as r48', async () => {
  const { d, pub, asked, checks } = deps();
  const r = await runJob(d, job(), budget);
  assert.equal(r.ok, true);
  const o = out(r);
  assert.equal(o.r45.pass, true, JSON.stringify(o.r45));
  assert.equal(o.r45.spec, 'r48.3');
  assert.equal(o.r45.generated, true);
  assert.equal(o.preset_version, 'gemini_r48');
  assert.equal(o.showroom.mode, 'r48');
  assert.ok(pub.has(o.processed_path) && o.processed_path.includes('-r48'));
  assert.equal(asked.length, 1);
  assert.equal(asked[0]!.images, 5, 'two real photos, the guide, the stock photo, the plate');
  assert.match(asked[0]!.prompt, /Image 5, the last, is the background plate/);
  assert.equal(checks[0]!.images, 4, 'the result, the two real photos and the plate');
  assert.equal(o.r45.plate_made, undefined, 'the stored plate was used');
});

test('3701 check in place: a render made before r48.3 goes through the gate as it is, no image generated; refused, the database makes it again', async () => {
  const { d, pub, asked, checks } = deps();
  pub.set('vehicles/v1/old-r48.jpg', encodeJpeg(studioRoom(true), 95));
  const old = job({ photo: { id: 'p1', shot_type: 'front_left', angle: 'front_left', original_path: 'vehicles/v1/original/fl.jpg', processed_path: 'vehicles/v1/old-r48.jpg', rebackground: true, is_public: true, file_base: 'cla-r48-front-left' } }, { regate: true });
  const r = out(await runJob(d, old, budget));
  assert.equal(asked.length, 0, 'no new render');
  assert.equal(checks.length, 1, 'one check');
  assert.equal(r.r45.pass, true, JSON.stringify(r.r45));
  assert.equal((r.r45 as unknown as { regate?: boolean }).regate, true);
  assert.ok(pub.has(r.processed_path) && r.processed_path !== 'vehicles/v1/old-r48.jpg', 'kept, on its target, as a new file');
  const no = deps({}, [{ ...WOK, looks_cgi: true }]);
  no.pub.set('vehicles/v1/old-r48.jpg', encodeJpeg(studioRoom(true), 95));
  const r2 = out(await runJob(no.d, old, budget));
  assert.equal(no.asked.length, 0);
  assert.equal(r2.r45.pass, false);
  assert.equal((r2.r45 as unknown as { regate?: boolean }).regate, true, 'the database knows it was a check in place');
  const gone = deps();
  const r3 = out(await runJob(gone.d, old, budget));
  assert.equal(r3.r45.pass, false, 'an unreadable render is refused, never made here');
  assert.equal(gone.asked.length, 0);
});

test('r48 refuse: nothing stored, the reasons returned (the database tries again with them as feedback)', async () => {
  const { d, pub } = deps({}, [{ ...OK, looks_cgi: true, wrong_wheels: true }]);
  const before = pub.size;
  const r = await runJob(d, job(), budget);
  assert.equal(out(r).r45.pass, false);
  assert.deepEqual(out(r).r45.reasons.sort(), ['looks_cgi', 'wrong_wheels']);
  assert.equal(pub.size, before, 'nothing stored');
});

test('r48 retry: the feedback of the last refusal is in the words; a pass then', async () => {
  const { d, asked } = deps();
  const r = await runJob(d, job({}, { feedback: ['looks_cgi'] }), budget);
  assert.equal(out(r).r45.pass, true);
  assert.match(asked[0]!.prompt, /AN EARLIER TRY WAS REFUSED because it looked like a render/);
});

test('r48 keep real: Gemini\'s limit waits, the check not answering is a refusal, no key waits; never a stored file', async () => {
  const lim = deps({ angleAi: async () => ({ ok: false, reason: 'limit', message: 'today' }) });
  assert.equal(out(await runJob(lim.d, job(), budget)).r45.wait, 'limit');
  const silent = deps({ checkPhoto: async () => null });
  const r = out(await runJob(silent.d, job(), budget));
  assert.equal(r.r45.pass, false);
  assert.equal(r.r45.wait, 'retry', 'the check not answering is a growing wait (3030), never a try');
  const nokey = deps({ angleAi: null });
  assert.equal(out(await runJob(nokey.d, job(), budget)).r45.wait, 'no_key');
  const none = deps();
  const r2 = out(await runJob(none.d, job({}, { refs: [{ bucket: 'vehicle-originals', path: 'missing.jpg' }], stock: null }), budget));
  assert.equal(r2.r45.pass, false);
  assert.match(String((r2.r45 as { why?: string }).why), /could not be read/);
});

test('r48 plate: none stored, Gemini makes it once, the realism check passes, it is stored and reported for filing', async () => {
  // the plate Gemini makes is the empty studio; the view is the studio with the car
  const plateFirst: Partial<WorkerDeps> = { angleAi: async (i) => { made.push({ images: i.images.length, prompt: i.prompt }); return { ok: true, bytes: encodeJpeg(studioRoom(!/A real photograph of/.test(i.prompt)), 95), contentType: 'image/jpeg', provider: 'ai', model: 'm' }; } };
  const made: Array<{ images: number; prompt: string }> = [];
  const { d, pub } = deps(plateFirst, [{ looks_real: true, has_text: false, has_logo: false, has_cars_or_people: false, free_floor: true, issues: [] }, WOK]);
  const asked = made;
  pub.delete('site/r48/plates/front.jpg');
  const r = out(await runJob(d, job({}, { plate: null }), budget));
  assert.equal(r.r45.pass, true);
  assert.equal(r.r45.plate_made?.family, 'front');
  assert.ok(pub.has(r.r45.plate_made!.path));
  assert.match(asked[0]!.prompt, /A real photograph of a modern, minimal, dark car dealership showroom/);
  assert.equal(asked[1]!.images, 5, 'the new plate goes with the photos');
  // a plate the check says looks fake is not used (the room in words then)
  const fake = deps({}, [{ looks_real: false, has_text: false, has_logo: false, has_cars_or_people: false, free_floor: true }, WOK]);
  fake.pub.delete('site/r48/plates/front.jpg');
  const r2 = out(await runJob(fake.d, job({}, { plate: null }), budget));
  assert.equal(r2.r45.plate_made, undefined);
  assert.equal(r2.r45.pass, false, 'r50: no plate, no studio gate pass');
  assert.ok(r2.r45.reasons.includes('gate_no_plate'));
  assert.equal(fake.asked[1]!.images, 4);
  assert.match(fake.asked[1]!.prompt, /THE PLACE: a modern, minimal, dark car dealership showroom/);
});

test('r48 check-in photos: read from their own bucket as references, never stored or published', async () => {
  const { d, pub, asked } = deps();
  const keys = new Set(pub.keys());
  const hand = [{ bucket: 'condition-photos', path: 'reports/r1/front_left.jpg', from: 'handover' as const }, { bucket: 'condition-photos', path: 'reports/r1/rear.jpg', from: 'handover' as const }];
  const r = out(await runJob(d, job({}, { refs: hand }), budget));
  assert.equal(r.r45.pass, true);
  assert.equal(r.r45.handover_refs, 2);
  assert.equal(asked[0]!.images, 5);
  const added = [...pub.keys()].filter((k) => !keys.has(k));
  assert.ok(added.every((k) => k.includes('-r48')), 'only the generated view and its sizes are stored');
  // a bucket the worker does not know is never read
  const odd = deps();
  const r2 = out(await runJob(odd.d, job({}, { refs: [{ bucket: 'identity', path: 'x.jpg' }], stock: null }), budget));
  assert.equal(r2.r45.pass, false);
});

test('r48 inside: no plate, no stock photo; the trunk has no guide', async () => {
  const { d, asked } = deps({}, [{ ...OK, view: 'trunk' }]);
  const r = out(await runJob(d, job({ photo: { id: 'p9', shot_type: 'trunk', angle: 'trunk', original_path: 'x', processed_path: null, rebackground: false, is_public: false, file_base: 'cla-trunk' } },
    { shot: 'trunk', family: null, plate: null, guide: null }), budget));
  assert.equal(r.r45.pass, true);
  assert.equal(asked[0]!.images, 2, 'the two real photos only');
  assert.match(asked[0]!.prompt, /open trunk/);
});

// ---------------------------------------------------------------- r48.2 (3030)
test('r48.2 the scene: the dealership by default with the model name on the cover only; another scene in its words, no sign', () => {
  const cover = r48Prompt({ car: CAR, shot: 'front_left', refs: 2, guide: true, stock: false, plate: true, name: 'CLA' });
  assert.match(cover, /THE MODEL NAME: the word "CLA"/);
  assert.match(cover, /spelled exactly "CLA"/);
  assert.doesNotMatch(r48Prompt({ car: CAR, shot: 'left', refs: 2, guide: true, stock: false, plate: true, name: 'CLA' }), /THE MODEL NAME/, 'only the cover');
  const hw = r48Prompt({ car: CAR, shot: 'front_left', refs: 2, guide: true, stock: false, plate: false, name: 'CLA', scene: { code: 'highway', place: 'the paved shoulder of an open highway' } });
  assert.match(hw, /THE PLACE: the paved shoulder of an open highway/);
  assert.doesNotMatch(hw, /THE MODEL NAME|CarmaCars sign/);
  assert.match(hw, /NO TEXT AND NO LOGOS/);
  assert.match(r48Prompt({ car: CAR, shot: 'rear_left', refs: 1, guide: true, stock: false, plate: true }), /nose MUST point to the RIGHT/);
});

test('r48.2 a car with no photo: the stock photo is the car, in the colour named', () => {
  const p = r48Prompt({ car: CAR, shot: 'front_left', refs: 0, guide: true, stock: true, plate: true, stockOnly: true });
  assert.match(p, /Image 1 is a stock photo of this exact model/);
  assert.match(p, /Image 2 is a composition guide/);
  assert.doesNotMatch(p, /Image 3 is a stock photo/);
  assert.match(p, /in exactly the colour named here/);
});

test('r48.2 the check: direction, the old background, the sign and name; looks refuse only the first two tries', () => {
  const o = { shot: 'front_left', plate: true };
  assert.deepEqual(judgeR48({ ...OK, nose: 'right' }, o).reasons, ['wrong_direction']);
  assert.equal(judgeR48({ ...OK, nose: 'left' }, o).pass, true);
  assert.equal(judgeR48({ ...OK, nose: 'camera' }, o).pass, true, 'a direction the check cannot place is not a refusal');
  assert.deepEqual(judgeR48({ ...OK, view: 'rear_left', nose: 'right' }, { shot: 'rear_left', plate: true }).reasons, []);
  assert.deepEqual(judgeR48({ ...OK, original_background: true }, o).reasons, ['original_background']);
  assert.deepEqual(judgeR48({ ...OK, name_wrong: true }, { ...o, name: 'CLA' }).reasons, ['name_wrong']);
  assert.equal(judgeR48({ ...OK, name_wrong: true, view: 'left' }, { shot: 'left', plate: true, name: 'CLA' }).pass, true, 'no name off the cover');
  assert.deepEqual(judgeR48({ ...OK, logo_wrong: true }, o).reasons, ['logo_wrong']);
  assert.equal(judgeR48({ ...OK, logo_wrong: true }, { ...o, scene: { code: 'highway' } }).pass, true, 'no sign in another scene');
  // the third try: looks alone pass (kept as soft), identity still refuses
  const late = judgeR48({ ...OK, parts_changed: true, looks_cgi: true, wrong_framing: true }, { ...o, tries: 2 });
  assert.equal(late.pass, true);
  assert.deepEqual(late.soft?.sort(), ['looks_cgi', 'parts_changed', 'wrong_framing']);
  assert.equal(judgeR48({ ...OK, wrong_colour: true, parts_changed: true }, { ...o, tries: 2 }).pass, false);
  assert.deepEqual(judgeR48({ ...OK, parts_changed: true }, { ...o, tries: 1 }).reasons, ['parts_changed']);
  const words = r48CheckPrompt({ car: CAR, shot: 'front_left', plate: true, name: 'CLA' });
  assert.match(words, /"nose"/);
  assert.match(words, /does not read exactly "CLA"/);
  assert.match(words, /never for a part the real photos do not show/);
});

test('r48.2 borderDiff: the same photo is 0, a new background is far, the car alone changing stays close', () => {
  const a = room(120, 80);
  assert.equal(borderDiff(a, a), 0);
  const b: Rgba = { width: 120, height: 80, data: new Uint8ClampedArray(120 * 80 * 4).map((_, i) => (i % 4 === 3 ? 255 : 20)) };
  assert.ok(borderDiff(a, b) > BACKGROUND_SAME);
  const c: Rgba = { width: 120, height: 80, data: new Uint8ClampedArray(a.data) };
  for (let y = 40; y < 80; y++) for (let x = 20; x < 100; x++) { const i = (y * 120 + x) * 4; c.data[i] = 0; c.data[i + 1] = 0; c.data[i + 2] = 0; }
  assert.ok(borderDiff(a, c) < BACKGROUND_SAME, 'only the middle changed');
  assert.equal(DEFAULT_SCENE, 'showroom_dark');
  assert.ok(HARD_REASONS.includes('wrong_direction') && !HARD_REASONS.includes('looks_cgi'));
});

test('r48.2 worker: the old background still there is refused; a location refusal and the check failing wait to retry', async () => {
  // the same-angle real photo is the result itself: its place is still there, so its wall is not the plate's (r50: the gate)
  const same = deps({ angleAi: async () => ({ ok: true, bytes: JPEG, contentType: 'image/jpeg', provider: 'ai', model: 'm' }) });
  const r = out(await runJob(same.d, job({}, { refs: [{ bucket: 'vehicle-originals', path: 'vehicles/v1/original/fl.jpg', from: 'listing', shot: 'front_left' }] }), budget));
  assert.equal(r.r45.pass, false);
  assert.ok(r.r45.reasons.includes('gate_wall_mismatch'));
  const loc = deps({ angleAi: async () => ({ ok: false, reason: 'location', message: 'User location is not supported for the API use.' }) });
  assert.equal(out(await runJob(loc.d, job(), budget)).r45.wait, 'retry');
  const blocked = deps({ angleAi: async () => ({ ok: false, reason: 'blocked', message: 'SAFETY' }) });
  assert.equal(out(await runJob(blocked.d, job(), budget)).r45.wait, undefined, 'a refusal of the content counts as a try');
});

test('r48.2 worker: a car with no photo is made from the stock photo; the scene and the tries reach the words and the check', async () => {
  const { d, asked, checks } = deps({}, [WOK]);
  const r = out(await runJob(d, job({}, { refs: [], tries: 2, scene: { code: 'highway', label: 'Highway', place: 'the paved shoulder of an open highway' } }), budget));
  assert.equal(r.r45.pass, true);
  assert.equal((r.r45 as { stock_only?: boolean }).stock_only, true);
  assert.equal(asked[0]!.images, 3, 'the stock photo, the guide, the plate');
  assert.match(asked[0]!.prompt, /Image 1 is a stock photo of this exact model/);
  assert.match(asked[0]!.prompt, /THE PLACE: the background plate/);
  assert.equal(checks[0]!.images, 3, 'the result, the stock photo, the plate');
  const inside = deps();
  const r2 = out(await runJob(inside.d, job({ photo: { id: 'p9', shot_type: 'trunk', angle: 'trunk', original_path: 'x', processed_path: null, rebackground: false, is_public: false, file_base: 'cla-trunk' } },
    { shot: 'trunk', refs: [], family: null, plate: null, guide: null }), budget));
  assert.equal(r2.r45.pass, false, 'no inside view is invented from a stock photo');
});

// ---------------------------------------------------------------- 3040: a plate only where the car has one, never a large box
test('3040 the plate words: no plate at an end leaves that bumper untouched; a front view says so; never a blank plate', () => {
  const none = r48Prompt({ car: CAR, shot: 'front', refs: 2, guide: false, stock: false, plate: true, plateEnd: 'no' });
  assert.match(none, /THIS CAR HAS NO FRONT PLATE/);
  assert.match(none, /no plate, holder, rectangle, blur or box/);
  assert.doesNotMatch(none, /blank plate holder/);
  const unknown = r48Prompt({ car: CAR, shot: 'front_left', refs: 2, guide: false, stock: false, plate: true });
  assert.match(unknown, /This is a front view: if the real photos show no front plate, the front bumper stays bare and untouched/);
  assert.match(unknown, /many Ontario cars have no front plate/);
  const rear = r48Prompt({ car: CAR, shot: 'rear', refs: 2, guide: false, stock: false, plate: true, plateEnd: 'yes' });
  assert.match(rear, /carries a rear plate: take it off cleanly so the bare rear bumper shows/);
  assert.match(plateRule('left'), /This view shows no plate/);
  assert.equal(plateEndOf('front_left'), 'front');
  assert.equal(plateEndOf('rear'), 'rear');
  assert.equal(plateEndOf('left'), null);
  const check = r48CheckPrompt({ car: CAR, shot: 'front', plate: true, plateEnd: 'no' });
  for (const k of ['plate_present', 'plate_cover', 'real_plate']) assert.match(check, new RegExp(`"${k}"`));
  assert.match(check, /an empty plate recess or bracket is not a plate/);
});

test('3040 the check: a blur or box where no plate is, a large cover, or an added plate always refuse; no plate, no box', () => {
  // a front bumper with no plate, left alone: passes, nothing to blur
  const bare = judgeR48({ ...OK, view: 'front', plate_present: false, plate_cover: false, real_plate: 'no' }, { shot: 'front', plate: true, plateEnd: 'no' });
  assert.equal(bare.pass, true);
  assert.deepEqual(bare.plates, []);
  // the check says no plate is there but still boxed the bumper: the box is dropped (the site never blurs a bare bumper)
  const phantomBox = judgeR48({ ...OK, view: 'front', plate_present: false, plates: [{ box_2d: [700, 420, 760, 560] }] }, { shot: 'front', plate: true, plateEnd: 'no' });
  assert.equal(phantomBox.pass, true);
  assert.deepEqual(phantomBox.plates, []);
  // a blur, box or blank patch where a plate is or would be: refused, even on the last try
  for (const tries of [0, 2]) {
    const patch = judgeR48({ ...OK, view: 'front', plate_cover: true }, { shot: 'front', plate: true, tries, plateEnd: 'no' });
    assert.equal(patch.pass, false);
    assert.ok(patch.reasons.includes('plate_patch'), String(tries));
  }
  // a plate drawn on an end of the car that has none: refused, even late
  const added = judgeR48({ ...OK, view: 'front', plate_present: true, plates: [{ box_2d: [700, 440, 740, 560] }] }, { shot: 'front', plate: true, tries: 2, plateEnd: 'no' });
  assert.deepEqual(added.reasons, ['plate_added']);
  assert.ok(judgeR48({ ...OK, view: 'front', plate_present: true, real_plate: 'no', plates: [{ box_2d: [700, 440, 740, 560] }] }, { shot: 'front', plate: true, tries: 2 }).reasons.includes('plate_added'));
  // a plate box far larger than a plate in that view: refused, never blurred
  const big = judgeR48({ ...OK, view: 'front_left', plate_present: true, plates: [{ box_2d: [600, 300, 900, 700] }] }, { shot: 'front_left', plate: true, tries: 2 });
  assert.ok(big.reasons.includes('plate_oversized'));
  assert.deepEqual(big.plates, []);
  // interiors: never a plate box
  assert.deepEqual(judgeR48({ ...OK, view: 'dashboard', plates: [{ box_2d: [700, 440, 740, 560] }] }, { shot: 'dashboard', plate: false }).plates, []);
});

