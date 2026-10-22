// The usage guard (migration 0080): the photo studio while the month's included image transformations are used (the
// original photo goes on the site, no transformation is spent, the database retries later), and the Cloudflare figures.
//   node --test --experimental-strip-types src/features/usage/usage.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runJob, USAGE_PAUSED, type JobContext, type WorkerDeps } from '../listing/worker.ts';
import { fakeText } from '../../integrations/llm/fake.ts';
import { cloudflareUsage, monthDays, torontoMidnight } from './cloudflare.ts';

const JPEG = new Uint8Array([0xff, 0xd8, 0xff, ...new Array(2000).fill(7)]);
const photo = (rebackground: boolean): JobContext => ({ id: 'j1', kind: 'process_photo', intake_id: 'i1', vehicle_id: 'v1', attempts: 1, max_attempts: 4, input: {},
  photo: { id: 'p1', shot_type: 'front_left', angle: 'front_left', original_path: 'vehicles/v1/original/fl.jpg', processed_path: 'vehicles/v1/x.jpg', rebackground, is_public: true, file_base: 'car-front-left' } });
function deps(calls: string[]): WorkerDeps {
  const pub = new Map<string, Uint8Array>();
  const no = async () => { calls.push('transform'); return { ok: false as const, reason: 'unavailable', message: 'not expected', retryable: false }; };
  return {
    claim: async () => ({ jobs: [], budget: { ai_neurons_today: 0, ai_neurons_limit: 9000, transformations_month: 5000, transformations_free: 5000 }, held: { photos: false, copy: false }, due: 0 }),
    report: async () => ({}), decodeVin: async () => ({ provider: 'fake', result: { ok: true } }), text: fakeText(),
    photos: { name: 'fake', cutout: no, composite: no, normalize: no, resize: no } as unknown as WorkerDeps['photos'],
    files: { privateUrl: async (p) => `priv:${p}`, publicUrl: (p) => `pub:${p}`, getPrivate: async () => JPEG, putPrivate: async () => undefined, putPublic: async (p, b) => { pub.set(p, b); } }
  };
}
const paused = { ai_neurons_today: 0, ai_neurons_limit: 9000, transformations_month: 5000, transformations_free: 5000, images_paused: true };

test('paused: a studio photo keeps its original on the site, spends no transformation and is marked for the retry', async () => {
  const calls: string[] = [];
  const r = await runJob(deps(calls), photo(true), paused);
  assert.equal(r.ok, true);
  assert.deepEqual(calls, []);
  assert.equal(r.units, 0);
  assert.equal(r.output?.used_original, true);
  assert.match(String(r.output?.fallback_reason), new RegExp(`^${USAGE_PAUSED}`));
  assert.deepEqual(r.output?.flags, ['background_not_replaced']);
});

test('paused: an interior keeps its original too, and the size variants wait (the site uses the master file)', async () => {
  const calls: string[] = [];
  assert.equal((await runJob(deps(calls), photo(false), paused)).output?.used_original, true);
  const v = await runJob(deps(calls), { ...photo(true), kind: 'resize' }, paused);
  assert.deepEqual(v.output?.variants, []);
  assert.deepEqual(calls, []);
});

test('Toronto days: midnight in Toronto as an instant, and the month so far', () => {
  assert.equal(torontoMidnight('2026-10-21').toISOString(), '2026-10-21T04:00:00.000Z');
  assert.equal(torontoMidnight('2026-12-01').toISOString(), '2026-12-01T05:00:00.000Z');
  assert.deepEqual(monthDays(new Date('2026-11-03T15:00:00Z')), ['2026-11-01', '2026-11-02', '2026-11-03']);
});

test('Cloudflare figures: requests and CPU of every Worker, neurons, R2; a part the token cannot read is reported, not fatal', async () => {
  const seen: string[] = [];
  const f = async (_u: string, i: { body: string }) => {
    const q = (JSON.parse(i.body) as { query: string }).query;
    seen.push(q.includes('workersInvocations') ? 'w' : q.includes('aiInference') ? 'ai' : 'r2');
    if (q.includes('aiInference')) return { json: async () => ({ errors: [{ message: 'not authorized for this dataset' }] }) };
    if (q.includes('r2Storage')) return { json: async () => ({ data: { viewer: { accounts: [{ r2: [{ max: { payloadSize: 1000, metadataSize: 24 }, dimensions: { bucketName: 'a' } }, { max: { payloadSize: 500, metadataSize: 0 }, dimensions: { bucketName: 'b' } }] }] } } }) };
    return { json: async () => ({ data: { viewer: { accounts: [{ w: [{ sum: { requests: 1200, cpuTimeUs: 4_500_000 } }, { sum: { requests: 300, cpuTimeUs: 500_000 } }] }] } } }) };
  };
  const u = await cloudflareUsage({ token: 't', account: 'a', now: new Date('2026-10-02T16:00:00Z'), fetch: f });
  assert.deepEqual(u.days.map((d) => d.day), ['2026-10-01', '2026-10-02']);
  assert.deepEqual(u.days[0]!.values, { workers_requests: 1500, workers_cpu: 5000 });
  assert.deepEqual(u.days[1]!.values, { workers_requests: 1500, workers_cpu: 5000, r2_storage: 1524 });
  assert.match(u.unavailable.workers_ai!, /not authorized/);
  assert.equal(seen.filter((x) => x === 'ai').length, 1, 'a refused part is asked once');
});
