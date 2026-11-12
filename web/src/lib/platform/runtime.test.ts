import { test } from 'node:test';
import assert from 'node:assert/strict';
import { aiBinding, cloudflareEnv, deploymentId, emailBinding, hostingTarget, internalUrl, restAi, selfFetcher, storageProviderFor } from './runtime.ts';
import { cronEnabled, jobsForTick } from './cron-plan.ts';
import type { JobsDue } from '../edge/cron-gate.ts';

const NODE = { HOSTING_TARGET: 'node' };
const worker = (bindings: Record<string, unknown>) => async () => bindings;
const noWorker = async (): Promise<never> => { throw new Error('not in a Worker'); };
const neverLoaded = async (): Promise<never> => { assert.fail('the Cloudflare context must not be asked for on Node'); };

test('the hosting target is Cloudflare unless HOSTING_TARGET=node', () => {
  assert.equal(hostingTarget({}), 'cloudflare');
  assert.equal(hostingTarget({ HOSTING_TARGET: 'cloudflare' }), 'cloudflare');
  assert.equal(hostingTarget({ HOSTING_TARGET: 'vercel' }), 'cloudflare');
  assert.equal(hostingTarget({ HOSTING_TARGET: ' Node ' }), 'node');
});

test('cloudflareEnv: the bindings in a Worker, null outside one, never asked for on Node', async () => {
  const env = { AI: { run: async () => 1 } };
  assert.equal(await cloudflareEnv({}, worker(env)), env);
  assert.equal(await cloudflareEnv({}, noWorker), null);
  assert.equal(await cloudflareEnv(NODE, neverLoaded), null);
});

test('aiBinding: the Worker binding on Cloudflare, even when REST keys are set', async () => {
  const AI = { run: async () => ({ response: 'from the binding' }) };
  const ai = await aiBinding({ CLOUDFLARE_ACCOUNT_ID: 'acc', WORKERS_AI_API_TOKEN: 't' }, worker({ AI }));
  assert.equal(ai, AI);
});

test('aiBinding: nothing without a Worker or without keys (the callers then use their fake)', async () => {
  assert.equal(await aiBinding({}, noWorker), null);
  // a local server without HOSTING_TARGET=node never calls Cloudflare, whatever keys the machine has
  assert.equal(await aiBinding({ CLOUDFLARE_ACCOUNT_ID: 'acc', WORKERS_AI_API_TOKEN: 't' }, noWorker), null);
  assert.equal(await aiBinding(NODE, neverLoaded), null);
  assert.equal(await aiBinding({ ...NODE, CLOUDFLARE_ACCOUNT_ID: 'acc' }, neverLoaded), null);
});

test('aiBinding on Node: Workers AI over REST, with the model in the address and the result unwrapped', async () => {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const f = (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    return new Response(JSON.stringify({ success: true, result: { response: '{"a":1}', usage: { prompt_tokens: 3, completion_tokens: 2 } } }), { status: 200 });
  }) as typeof fetch;
  const ai = await aiBinding({ ...NODE, CLOUDFLARE_ACCOUNT_ID: 'acc 1', WORKERS_AI_API_TOKEN: 'tok' }, neverLoaded, f);
  assert.ok(ai);
  const out = await ai.run('@cf/meta/llama-3.1-8b-instruct-fp8-fast', { messages: [{ role: 'user', content: 'hi' }], max_tokens: 5 });
  assert.deepEqual(out, { response: '{"a":1}', usage: { prompt_tokens: 3, completion_tokens: 2 } });
  assert.equal(calls[0]!.url, 'https://api.cloudflare.com/client/v4/accounts/acc%201/ai/run/@cf/meta/llama-3.1-8b-instruct-fp8-fast');
  const headers = calls[0]!.init.headers as Record<string, string>;
  assert.equal(headers.authorization, 'Bearer tok');
  assert.deepEqual(JSON.parse(String(calls[0]!.init.body)), { messages: [{ role: 'user', content: 'hi' }], max_tokens: 5 });
});

test('restAi: a refusal throws with Cloudflare\'s code, as the binding does (the callers read 4006 and 429)', async () => {
  const refused = (status: number, body: unknown) => (async () => new Response(typeof body === 'string' ? body : JSON.stringify(body), { status })) as typeof fetch;
  await assert.rejects(restAi('a', 't', refused(429, { success: false, errors: [{ code: 4006, message: 'you have used up your daily free allocation of 10,000 neurons' }] })).run('@cf/m', {}),
    (e: Error) => /4006/.test(e.message) && /neuron/.test(e.message) && /429/.test(e.message));
  await assert.rejects(restAi('a', 't', refused(502, '<html>bad gateway</html>')).run('@cf/m', {}), /Workers AI 502/);
  await assert.rejects(restAi('a', 't', refused(200, { success: false, errors: [{ code: 3036, message: 'rate limited' }] })).run('@cf/m', {}), /3036/);
});

test('internalUrl: the same path on the app\'s own port when INTERNAL_ORIGIN is set', () => {
  assert.equal(internalUrl('https://carmacars.example/api/jobs/pdf?x=1', { INTERNAL_ORIGIN: 'http://127.0.0.1:3100' }), 'http://127.0.0.1:3100/api/jobs/pdf?x=1');
  assert.equal(internalUrl('https://carmacars.example/api/jobs/pdf', {}), 'https://carmacars.example/api/jobs/pdf');
  assert.equal(internalUrl('https://carmacars.example/a', { INTERNAL_ORIGIN: 'not an address' }), 'https://carmacars.example/a');
});

test('selfFetcher: the service binding in the Worker, a plain request elsewhere (to the inner port on Node)', async () => {
  const seen: string[] = [];
  const binding = { fetch: async (r: Request) => { seen.push(`binding ${r.url}`); return new Response('ok'); } };
  const f = (async (r: string | URL | Request) => { seen.push(`fetch ${(r as Request).method} ${(r as Request).url} ${(r as Request).headers.get('authorization')}`); return new Response('ok'); }) as typeof fetch;
  const req = () => new Request('https://carmacars.example/api/jobs/pdf', { method: 'POST', headers: { authorization: 'Bearer x' }, body: '{}' });
  await (await selfFetcher({}, worker({ WORKER_SELF_REFERENCE: binding }), f)).fetch(req());
  await (await selfFetcher({}, noWorker, f)).fetch(req());
  await (await selfFetcher({ ...NODE, INTERNAL_ORIGIN: 'http://127.0.0.1:3100' }, neverLoaded, f)).fetch(req());
  assert.deepEqual(seen, [
    'binding https://carmacars.example/api/jobs/pdf',
    'fetch POST https://carmacars.example/api/jobs/pdf Bearer x',
    'fetch POST http://127.0.0.1:3100/api/jobs/pdf Bearer x'
  ]);
});

test('emailBinding and deploymentId: the Worker\'s, and on Node no binding and the image\'s commit', async () => {
  const EMAIL = { send: async () => ({ messageId: 'm' }) };
  assert.equal(await emailBinding({}, worker({ EMAIL })), EMAIL);
  assert.equal(await emailBinding({}, worker({ EMAIL: {} })), null);
  assert.equal(await emailBinding(NODE, neverLoaded), null);
  assert.equal(await deploymentId({}, worker({ CF_VERSION_METADATA: { id: 'v-123' } })), 'v-123');
  assert.equal(await deploymentId({ DEPLOY_VERSION: 'abc' }, noWorker), null);
  assert.equal(await deploymentId({ ...NODE, DEPLOY_VERSION: 'abc1234' }, neverLoaded), 'abc1234');
  assert.equal(await deploymentId(NODE, neverLoaded), null);
});

test('storageProviderFor: R2 bindings only in a Worker; on Node the S3 keys or a plain refusal', () => {
  assert.equal(storageProviderFor('r2-binding', {}), 'r2-binding');
  assert.equal(storageProviderFor('supabase', NODE), 'supabase');
  assert.equal(storageProviderFor('local', NODE), 'local');
  assert.equal(storageProviderFor('r2-binding', { ...NODE, R2_ACCOUNT_ID: 'a', R2_ACCESS_KEY_ID: 'k', R2_SECRET_ACCESS_KEY: 's' }), 'r2');
  assert.throws(() => storageProviderFor('r2-binding', NODE), /STORAGE_PROVIDER=supabase/);
});

const DUE: JobsDue = { listing: true, seo: false, pdf: true, phone: true, turo: false, agreements: true, reviews: false, crm: false, deposits: true, ads: false, checked: true };

test('jobsForTick: nothing between the five-minute ticks; the due jobs, the hourly ones on their tick', () => {
  assert.deepEqual(jobsForTick({ full: false, minute: 3 }, DUE, true), []);
  assert.deepEqual(jobsForTick({ full: true, minute: 0 }, DUE, true).map((j) => j.path), [
    '/api/jobs/listing', '/api/jobs/phone', '/api/jobs/push', '/api/jobs/public-rebuild', '/api/jobs/statements', '/api/jobs/pdf', '/api/jobs/agreements', '/api/jobs/deposits'
  ]);
  assert.deepEqual(jobsForTick({ full: true, minute: 5 }, DUE, false).map((j) => j.path), [
    '/api/jobs/listing', '/api/jobs/phone', '/api/jobs/public-rebuild', '/api/jobs/pdf', '/api/jobs/agreements', '/api/jobs/deposits', '/api/jobs/purge'
  ]);
  assert.ok(jobsForTick({ full: true, minute: 10 }, DUE, false).some((j) => j.path === '/api/jobs/usage'));
  assert.ok(!jobsForTick({ full: true, minute: 20 }, DUE, false).some((j) => /statements|purge|usage/.test(j.path)));
  assert.deepEqual(jobsForTick({ full: true, minute: 20 }, DUE, false).find((j) => j.path === '/api/jobs/public-rebuild'), { path: '/api/jobs/public-rebuild', body: '{"check":true}' });
});

test('jobsForTick: every job the Worker\'s cron runs when all are due', () => {
  const all: JobsDue = { ...DUE, seo: true, turo: true, reviews: true, crm: true, ads: true, meet: true, gsc: true, interviews: true, car_values: true };
  const paths = jobsForTick({ full: true, minute: 0 }, all, true).map((j) => j.path.replace('/api/jobs/', ''));
  assert.deepEqual(paths, ['listing', 'seo', 'phone', 'interviews', 'push', 'reviews', 'meet', 'gsc', 'ads', 'car-values', 'public-rebuild', 'statements', 'pdf', 'turo-rematch', 'agreements', 'partner-crm', 'deposits']);
});

test('cronEnabled: only when asked for, so the jobs never run twice while the Worker\'s cron still does', () => {
  assert.equal(cronEnabled({}), false);
  assert.equal(cronEnabled({ CRON_ENABLED: '0' }), false);
  assert.equal(cronEnabled({ CRON_ENABLED: '1' }), true);
  assert.equal(cronEnabled({ CRON_ENABLED: ' On ' }), true);
});
