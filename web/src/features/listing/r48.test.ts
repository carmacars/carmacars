// Unit tests for the r48 photo standard (features/listing/r48.ts) and the worker's r48 step (worker.ts makeR48), with a fake
// Gemini (no network): pass, refuse, retry with feedback, keep the real photo, the plate made once, check-in photos as
// references (read, never stored).
//   node --test --experimental-strip-types src/features/listing/r48.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PLATE_FAMILIES, R48_ANGLES, R48_SPEC, feedbackLine, guidePath, imageRoles, judgePlate, judgeR48, plateFamily, platePath, platePrompt, r48Angle, r48CheckPrompt, r48Prompt,
  REAL_PHOTO_RULE } from './r48.ts';
import { STANDARD_ANGLES } from './r45.ts';
import { encodeJpeg } from './showroom.ts';
import { runJob, type JobContext, type JobResult, type WorkerDeps } from './worker.ts';
import { fakePhotos } from '../../integrations/photos/fake.ts';
import { fakeText } from '../../integrations/llm/fake.ts';
import type { Rgba } from './subject-frame.ts';

const CAR = { year: 2022, make: 'Mercedes-Benz', model: 'CLA 250', trim: '4MATIC', colour: 'Polar White' };

test('the nine angles: the r45 standard set in its order, the front three-quarter first, each with its framing', () => {
  assert.equal(R48_SPEC, 'r48.1');
  assert.deepEqual(R48_ANGLES.map((a) => a.shot), STANDARD_ANGLES.map((a) => a.shot));
  assert.equal(R48_ANGLES[0]!.shot, 'front_left');
  for (const a of R48_ANGLES) {
    assert.match(a.framing, /mm full-frame lens look/, `${a.shot}: a focal length`);
    assert.match(a.framing, /height|level/, `${a.shot}: a camera height`);
  }
  assert.match(r48Angle('front_left')!.framing, /45 degrees/);
  assert.match(r48Angle('rear_left')!.framing, /45 degrees/);
  assert.match(r48Angle('left')!.framing, /90 degrees/);
  assert.match(r48Angle('front_left')!.framing, /centred/);
});

test('plate families: outside angles only; the guide of each angle per body type', () => {
  assert.deepEqual(['front_left', 'front', 'left', 'rear_left', 'rear', 'dashboard', 'trunk'].map(plateFamily), ['front', 'front', 'side', 'rear', 'rear', null, null]);
  assert.deepEqual(PLATE_FAMILIES, ['front', 'side', 'rear']);
  assert.equal(guidePath('suv', 'front_left'), 'site/r48/guides/suv-lead.jpg');
  assert.equal(guidePath(null, 'rear_left'), 'site/r48/guides/sedan-rear34.jpg');
  assert.equal(guidePath('../x', 'left'), 'site/r48/guides/sedan-side.jpg', 'a body key is never a path');
  assert.equal(guidePath('suv', 'trunk'), null);
  assert.equal(platePath('side'), 'site/r48/plates/side.jpg');
  assert.match(platePath('front', 'ab12'), /^site\/r48\/plates\/[a-z0-9-]+\.jpg$/);
});

test('the generation words: every reference named in order, the framing, identity, real-photo cues, plates blurred, no text or logo', () => {
  const p = r48Prompt({ car: CAR, shot: 'front_left', refs: 4, guide: true, stock: true, plate: true });
  assert.match(p, /Images 1 to 4 are real photos of THIS car/);
  assert.match(p, /Image 5 is a composition guide/);
  assert.match(p, /Image 6 is a stock photo of the same model/);
  assert.match(p, /Image 7, the last, is the background plate/);
  assert.match(p, /TARGET FRAMING: front three-quarter .*45 degrees/);
  assert.match(p, /2022 Mercedes-Benz CLA 250 4MATIC, Polar White/);
  assert.match(p, /same wheels/);
  assert.match(p, /damage-free/);
  assert.ok(p.includes(REAL_PHOTO_RULE));
  assert.match(p, /contact shadow/);
  assert.match(p, /not a 3D render or CGI/);
  assert.match(p, /blur its face strongly/);
  assert.match(p, /NO TEXT AND NO LOGOS/);
  assert.doesNotMatch(p, /CarmaCars logo/, 'no logo sign added any more');
  assert.doesNotMatch(p, /REFUSED/);
  // inside: no plate, no stock photo, no background swap
  const i = r48Prompt({ car: CAR, shot: 'dashboard', refs: 2, guide: true, stock: true, plate: true });
  assert.doesNotMatch(i, /background plate/);
  assert.doesNotMatch(i, /stock photo/);
  assert.match(i, /no background is swapped/);
  assert.deepEqual(imageRoles({ refs: 1, guide: false, stock: false, plate: false, shot: 'trunk' }).length, 1);
  // without a stored plate: the room in words
  assert.match(r48Prompt({ car: CAR, shot: 'left', refs: 1, guide: false, stock: false, plate: false }), /a real, empty, modern car dealership showroom/);
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
  const plated = judgeR48({ ...OK, plate_readable: true, plates: [{ box_2d: [700, 420, 760, 560] }] }, { shot: 'front_left', plate: true });
  assert.equal(plated.pass, true);
  assert.equal(plated.plates.length, 1);
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
    assert.match(w, /real photograph of an empty/);
    assert.match(w, /No text, no logos/);
    assert.match(w, /Not a 3D render/);
  }
  assert.match(platePrompt('side'), /square to the long back wall/);
  assert.deepEqual(judgePlate({ looks_real: true, has_text: false, has_logo: false, has_cars_or_people: false, free_floor: true }), { pass: true, reasons: [] });
  assert.deepEqual(judgePlate({ looks_real: false, has_text: true, has_logo: true, has_cars_or_people: true, free_floor: false }).reasons, ['not_real', 'text', 'logo', 'cars_or_people', 'no_free_floor']);
  assert.equal(judgePlate(null).pass, false);
});

// ---------------------------------------------------------------- the worker with a fake Gemini
const room = (W: number, H: number): Rgba => ({ width: W, height: H, data: new Uint8ClampedArray(W * H * 4).map((_, i) => (i % 4 === 3 ? 255 : 120)) });
const JPEG = encodeJpeg(room(64, 48), 80);
type Out = { r45: { pass: boolean; spec: string; reasons: string[]; wait?: string; generated?: boolean; refs?: number; handover_refs?: number; plate_made?: { family: string; path: string } };
  preset_version: string; processed_path: string; showroom: { mode: string } };
const out = (r: JobResult) => r.output as unknown as Out;
function deps(over: Partial<WorkerDeps> = {}, answers: unknown[] = [OK]) {
  const priv = new Map<string, Uint8Array>([['vehicles/v1/original/fl.jpg', JPEG], ['vehicles/v1/original/rear.jpg', JPEG]]);
  const cond = new Map<string, Uint8Array>([['reports/r1/front_left.jpg', JPEG], ['reports/r1/rear.jpg', JPEG]]);
  const pub = new Map<string, Uint8Array>([['site/r48/plates/front.jpg', JPEG], ['site/r48/guides/sedan-lead.jpg', JPEG], ['seo-photos/mercedes-benz/cla/2020-2024-1280.webp', JPEG]]);
  const asked: Array<{ images: number; prompt: string }> = [];
  const checks: Array<{ images: number; prompt: string }> = [];
  let k = 0;
  const d: WorkerDeps = {
    claim: async () => ({ jobs: [], budget: { ai_neurons_today: 0, ai_neurons_limit: 1, transformations_month: 0, transformations_free: 1 }, held: { photos: false, copy: false }, due: 0 }),
    report: async () => undefined, decodeVin: async () => ({ provider: 'x', result: { ok: false } }), text: fakeText(),
    photos: fakePhotos(async () => null),
    files: { privateUrl: async (p) => p, publicUrl: (p) => p, getPrivate: async (p) => priv.get(p) ?? null, putPrivate: async (p, b) => { priv.set(p, b); },
      putPublic: async (p, b) => { pub.set(p, b); }, getPublic: async (p) => pub.get(p) ?? null, getCondition: async (p) => cond.get(p) ?? null },
    angleAi: async (i) => { asked.push({ images: i.images.length, prompt: i.prompt }); return { ok: true, bytes: encodeJpeg(room(300, 200), 80), contentType: 'image/jpeg', provider: 'ai', model: 'gemini-2.5-flash-image' }; },
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
  assert.equal(o.r45.pass, true);
  assert.equal(o.r45.spec, 'r48.1');
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
  assert.equal(r.r45.wait, 'quota');
  const nokey = deps({ angleAi: null });
  assert.equal(out(await runJob(nokey.d, job(), budget)).r45.wait, 'no_key');
  const none = deps();
  const r2 = out(await runJob(none.d, job({}, { refs: [{ bucket: 'vehicle-originals', path: 'missing.jpg' }] }), budget));
  assert.equal(r2.r45.pass, false);
  assert.match(String((r2.r45 as { why?: string }).why), /could not be read/);
});

test('r48 plate: none stored, Gemini makes it once, the realism check passes, it is stored and reported for filing', async () => {
  const { d, pub, asked } = deps({}, [{ looks_real: true, has_text: false, has_logo: false, has_cars_or_people: false, free_floor: true, issues: [] }, OK]);
  pub.delete('site/r48/plates/front.jpg');
  const r = out(await runJob(d, job({}, { plate: null }), budget));
  assert.equal(r.r45.pass, true);
  assert.equal(r.r45.plate_made?.family, 'front');
  assert.ok(pub.has(r.r45.plate_made!.path));
  assert.match(asked[0]!.prompt, /real photograph of an empty, modern, high-end car dealership showroom/);
  assert.equal(asked[1]!.images, 5, 'the new plate goes with the photos');
  // a plate the check says looks fake is not used (the room in words then)
  const fake = deps({}, [{ looks_real: false, has_text: false, has_logo: false, has_cars_or_people: false, free_floor: true }, OK]);
  fake.pub.delete('site/r48/plates/front.jpg');
  const r2 = out(await runJob(fake.d, job({}, { plate: null }), budget));
  assert.equal(r2.r45.plate_made, undefined);
  assert.equal(fake.asked[1]!.images, 4);
  assert.match(fake.asked[1]!.prompt, /a real, empty, modern car dealership showroom/);
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
  const r2 = out(await runJob(odd.d, job({}, { refs: [{ bucket: 'identity', path: 'x.jpg' }] }), budget));
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
