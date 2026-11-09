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

test('paused (r35, 1050): only the cut-out waits; an interior and the size variants are made (locally in production)', async () => {
  const calls: string[] = [];
  const ok = async () => { calls.push('local'); return { ok: true as const, bytes: JPEG, contentType: 'image/jpeg', transformations: 0 }; };
  const d = { ...deps(calls), photos: { name: 'local', cutout: async () => { calls.push('cutout'); return { ok: false as const, reason: 'quota', message: 'x', retryable: true }; }, composite: ok, normalize: ok, resize: ok } as unknown as WorkerDeps['photos'] };
  const inside = await runJob(d, photo(false), paused);
  assert.equal(inside.output?.used_original, undefined, 'made, not the original');
  const v = await runJob(d, { ...photo(true), kind: 'resize' }, paused);
  assert.equal((v.output?.variants as unknown[]).length, 3);
  assert.ok(!calls.includes('cutout'), 'the cut-out is never asked while paused');
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

// 0320: the banner speaks in money; the email line says whether Cloudflare sends and links to the steps
import { bannerLine, bannerTone, cfEmailSentence, resendDay, CF_EMAIL_STEPS, emailBudgetLine } from './model.ts';
test('banner: red only when the database says so; the words name the projected cost', () => {
  const r = { service: 'workers_cpu', label: 'Website CPU time (Cloudflare Worker)', share_bps: 12300, level: 100 as const, used_text: '36,899,350 CPU ms', included_text: '30,000,000 CPU ms',
    overage_usd: 0.14, resets_at: null, tone: 'note' as const, projected_usd: 0.88 };
  assert.equal(bannerTone(r), 'note');
  assert.equal(bannerTone({ level: 100 }), 'red');
  assert.equal(bannerLine(r), 'Website CPU time at 123% (36,899,350 CPU ms of 30,000,000 CPU ms), about US$0.88 above the allowance projected for this month');
});
test('email: Cloudflare not set up says so, with the four steps; sending says nothing', () => {
  const c = { state: 'absent' as const, enabled: true, ok_at: null, failed_at: null, error: null, sent_month: 0, included: 3000 };
  // r35: the daily number is the setting's, never one written in the code
  assert.match(cfEmailSentence(c, 150)!, /not set up yet.*includes only 150 a day\. The one-time setup gives 3,000 a month/);
  assert.match(cfEmailSentence(c)!, /includes only your daily email limit/);
  assert.match(cfEmailSentence({ ...c, state: 'off' }, '250 emails')!, /Resend \(250 emails a day included\)/);
  assert.equal(resendDay(0), 'your daily email limit');
  assert.equal(cfEmailSentence({ ...c, state: 'ok' }), null);
  assert.equal(CF_EMAIL_STEPS.length, 4);
  assert.match(CF_EMAIL_STEPS[2], /CF_EMAIL_BINDING/);
});
test('the quiet note is short', async () => {
  const { noteLine } = await import('./model.ts');
  assert.equal(noteLine({ service: 'r2_storage', label: 'Photo and document storage (Cloudflare R2)', share_bps: 10300, level: 100, used_text: '', included_text: '', overage_usd: 0.005, resets_at: null, projected_usd: 0.01 }),
    'Photo and document storage 103% used, about US$0.01 this month');
});

// r35 (0900): the day's emails in one plain line, with why the cap is that number (the pace read's numbers only)
test('email budget: only Resend while Cloudflare is not set up, and what Cloudflare would add', () => {
  assert.equal(emailBudgetLine({ used: 98, cap: 100, cf_state: 'absent', cf_counted: false, cf_budget: 200, resend_budget: 100 }),
    '98 of 100 today: only Resend is sending (Cloudflare Email Service is not set up, which adds 200)');
  assert.equal(emailBudgetLine({ used: 13, cap: 300, cf_state: 'ok', cf_counted: true, cf_budget: 200, resend_budget: 100 }), '13 of 300 today (Cloudflare 200 + Resend 100)');
  assert.match(emailBudgetLine({ used: 5, cap: 80, cf_state: 'off', cf_counted: false, cf_budget: 150, resend_budget: 80 }), /turned off in Program settings, which adds 150\)$/);
  assert.match(emailBudgetLine({ used: 5, cap: 80, cf_state: 'failing', cf_counted: false, cf_budget: 150, resend_budget: 80 }), /refused the last emails/);
  assert.equal(emailBudgetLine({ used: 1, cap: 2 }), '1 of 2 today');
});
