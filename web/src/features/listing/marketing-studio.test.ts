// Unit tests for the marketing set made from the studio set (marketing-studio.ts, worker.ts marketingFromStudio), with a fake
// Gemini: the same car moved into the scene, the website's own scene copied as is, lifestyle shots within the ad rules, a
// refused lifestyle shot skipped, a background that did not change refused.
//   node --test --experimental-strip-types src/features/listing/marketing-studio.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { LIFESTYLE_MAX, OUTFITS, PERSON_RULES, judgeStudioMove, lifestylePlan, studioMoveCheckPrompt, studioMovePrompt } from './marketing-studio.ts';
import { encodeJpeg } from './showroom.ts';
import { runJob, type JobContext, type JobResult, type WorkerDeps } from './worker.ts';
import { fakePhotos } from '../../integrations/photos/fake.ts';
import { fakeText } from '../../integrations/llm/fake.ts';
import type { Rgba } from './subject-frame.ts';

const plain = (W: number, H: number, v: number): Rgba => ({ width: W, height: H, data: new Uint8ClampedArray(W * H * 4).map((_, i) => (i % 4 === 3 ? 255 : v)) });

test('the move words: the same car, angle and direction; only the place changes; no people unless a lifestyle shot', () => {
  const p = studioMovePrompt({ place: 'the paved shoulder of an open highway', label: 'Highway', plate: false, reference: false, cover: false, scene: { code: 'highway' }, name: null });
  assert.match(p, /the same camera angle, the same direction/);
  assert.match(p, /paved shoulder of an open highway/);
  assert.match(p, /No people\./);
  assert.doesNotMatch(p, /CarmaCars sign/);
  const c = studioMovePrompt({ place: 'x', label: 'Dark', plate: true, reference: false, cover: true, scene: { code: 'showroom_dark' }, name: 'CLA' });
  assert.match(c, /model name "CLA"/);
  assert.match(c, /background plate/);
});

test('lifestyle: a glamorous adult, ad-appropriate always; at most three, each its own pose and outfit', () => {
  const p = studioMovePrompt({ place: 'x', label: 'Highway', plate: false, reference: false, cover: false, scene: { code: 'highway' }, name: null, pose: 'door', outfit: OUTFITS[1] });
  assert.match(p, /clearly an adult/);
  assert.match(p, /evening dress/);
  assert.match(p, /open driver door/);
  assert.match(p, /NEVER: lingerie, swimwear, nudity/);
  assert.ok(p.includes(PERSON_RULES));
  assert.doesNotMatch(p, /No people\./);
  const plan = lifestylePlan(5, ['front_left', 'left', 'rear']);
  assert.equal(plan.length, LIFESTYLE_MAX);
  assert.deepEqual(plan.map((x) => x.pose), ['beside', 'door', 'driver']);
  assert.equal(new Set(plan.map((x) => x.outfit)).size, 3);
  assert.deepEqual(lifestylePlan(2, ['rear']), [], 'no lifestyle shot without a front or side view');
  assert.match(studioMoveCheckPrompt({ lifestyle: true }), /clearly look like an adult/);
  assert.match(studioMoveCheckPrompt({ lifestyle: false }), /any person is in the photo/);
  assert.deepEqual(judgeStudioMove({ wrong_colour: false, person_not_ok: true }).reasons, ['person_not_ok']);
  assert.equal(judgeStudioMove(null).pass, false);
});

// ---------------------------------------------------------------- the worker
const SRC = encodeJpeg(plain(300, 200, 120), 85);
function deps(over: Partial<WorkerDeps> = {}, answer: unknown = { wrong_colour: false }, made = encodeJpeg(plain(300, 200, 20), 85)) {
  const pub = new Map<string, Uint8Array>([['vehicles/v1/cla-r48ab.jpg', SRC]]);
  const asked: Array<{ images: number; prompt: string }> = [];
  const d: WorkerDeps = {
    claim: async () => ({ jobs: [], budget: { ai_neurons_today: 0, ai_neurons_limit: 1, transformations_month: 0, transformations_free: 1 }, held: { photos: false, copy: false }, due: 0 }),
    report: async () => undefined, decodeVin: async () => ({ provider: 'x', result: { ok: false } }), text: fakeText(), photos: fakePhotos(async () => null),
    files: { privateUrl: async (p) => p, publicUrl: (p) => p, getPrivate: async () => null, putPrivate: async () => undefined,
      putPublic: async (p, b) => { pub.set(p, b); }, getPublic: async (p) => pub.get(p) ?? null },
    angleAi: async (i) => { asked.push({ images: i.images.length, prompt: i.prompt }); return { ok: true, bytes: made, contentType: 'image/jpeg', provider: 'ai', model: 'm' }; },
    checkPhoto: async () => ({ data: answer, model: 'gemini:x' }),
    ...over
  };
  return { d, pub, asked };
}
const job = (studio: Record<string, unknown>, scene = 'highway'): JobContext => ({ id: 'j1', kind: 'marketing_photo', intake_id: 'i1', vehicle_id: 'v1', attempts: 1, max_attempts: 4,
  input: { marketing: { id: 'm1', vehicle_id: 'v1', photo_id: 'p1', scene, label: 'Highway', made: 'photo', place: 'the paved shoulder of an open highway', mask: null, adjust: null, reference: null,
    studio: { path: 'vehicles/v1/cla-r48ab.jpg', shot: 'front_left', cover: true, model: 'CLA 250', plate: null, same: false, pose: null, outfit: null, ...studio } } } });
const mk = (r: JobResult) => (r.output as { marketing: { status: string; path?: string; note?: string | null } }).marketing;
const budget = { ai_neurons_today: 0, ai_neurons_limit: 1, transformations_month: 0, transformations_free: 1 };

test('worker: the studio view moved into the scene, checked and stored', async () => {
  const { d, pub, asked } = deps();
  const m = mk(await runJob(d, job({}), budget));
  assert.equal(m.status, 'made');
  assert.ok(pub.has(m.path!));
  assert.equal(asked[0]!.images, 1);
  assert.match(asked[0]!.prompt, /paved shoulder/);
});

test('worker: the website\'s own scene is the website photo itself (no image call)', async () => {
  const { d, asked } = deps();
  const m = mk(await runJob(d, job({ same: true }, 'showroom_dark'), budget));
  assert.equal(m.status, 'made');
  assert.equal(asked.length, 0);
});

test('worker: a background that did not change is refused; a lifestyle shot Gemini declines is skipped', async () => {
  const same = deps({}, { wrong_colour: false }, SRC);
  assert.match(String(mk(await runJob(same.d, job({}), budget)).note), /background did not change/);
  const declined = deps({ angleAi: async () => ({ ok: false, reason: 'blocked', message: 'SAFETY' }) });
  const m = mk(await runJob(declined.d, job({ pose: 'beside', outfit: OUTFITS[0] }), budget));
  assert.equal(m.status, 'failed');
  assert.match(String(m.note), /^Skipped/);
  const person = deps({}, { person_not_ok: true });
  assert.match(String(mk(await runJob(person.d, job({ pose: 'driver', outfit: OUTFITS[2] }), budget)).note), /^Skipped: person not ok/);
});
