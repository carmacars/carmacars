// The PostgREST call against a mocked fetch: the headers for each role, the body, null for void, errors.
//   node --test --experimental-strip-types src/lib/db/postgrest.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { postgrestRpc, RpcError, withBuildRetry } from './postgrest.ts';

const T = { url: 'https://p.supabase.co/', anonKey: 'anon', serviceKey: 'service' };
function mock(status: number, body: string) {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const f = (async (url: string | URL | Request, init?: RequestInit) => { calls.push({ url: String(url), init: init ?? {} }); return new Response(status === 204 ? null : body, { status }); }) as typeof fetch;
  return { f, calls };
}
const h = (init: RequestInit) => init.headers as Record<string, string>;

test('anonymous call: anon key in both headers, args as the JSON body', async () => {
  const m = mock(200, '{"a":1}');
  assert.deepEqual(await postgrestRpc(m.f, T, 'car_page', { p_slug: 'x' }, { role: 'anon' }), { a: 1 });
  assert.equal(m.calls[0]!.url, 'https://p.supabase.co/rest/v1/rpc/car_page');
  assert.equal(m.calls[0]!.init.method, 'POST');
  assert.equal(h(m.calls[0]!.init).apikey, 'anon');
  assert.equal(h(m.calls[0]!.init).Authorization, 'Bearer anon');
  assert.equal(m.calls[0]!.init.body, '{"p_slug":"x"}');
  assert.equal(m.calls[0]!.init.cache, undefined);
});
test('signed-in call carries the session token; service role its key', async () => {
  const m = mock(200, 'null');
  await postgrestRpc(m.f, T, 'my_notifications', {}, { role: 'authenticated', accessToken: 'jwt' });
  await postgrestRpc(m.f, T, 'door', {}, { role: 'service_role' });
  assert.equal(h(m.calls[0]!.init).Authorization, 'Bearer jwt');
  assert.equal(h(m.calls[0]!.init).apikey, 'anon');
  assert.equal(h(m.calls[1]!.init).Authorization, 'Bearer service');
  assert.equal(h(m.calls[1]!.init).apikey, 'service');
});
test('null and void results', async () => {
  assert.equal(await postgrestRpc(mock(200, 'null').f, T, 'f', {}, { role: 'anon' }), null);
  assert.equal(await postgrestRpc(mock(204, '').f, T, 'f', {}, { role: 'anon' }), null);
});
test('a database error keeps its message, code and hint', async () => {
  const m = mock(401, '{"code":"42501","details":null,"hint":"x","message":"permission denied for function admin_gate"}');
  await assert.rejects(postgrestRpc(m.f, T, 'admin_gate', {}, { role: 'anon' }), (e: unknown) => e instanceof RpcError && e.code === '42501' && e.hint === 'x' && /permission denied/.test(e.message));
});
test('service role without its key is refused before any request', async () => {
  const m = mock(200, '1');
  await assert.rejects(postgrestRpc(m.f, { url: T.url, anonKey: 'a' }, 'door', {}, { role: 'service_role' }));
  assert.equal(m.calls.length, 0);
});

test('build: a statement timeout (57014) is tried again with a growing wait; at run time it is not', async () => {
  let n = 0;
  const waits: number[] = [];
  const flaky = async () => { n++; if (n < 3) throw new RpcError('canceling statement due to statement timeout', '57014', undefined, 500); return 'hub'; };
  assert.equal(await withBuildRetry(flaky, { building: true, sleep: async (ms) => { waits.push(ms); } }), 'hub');
  assert.equal(n, 3);
  assert.deepEqual(waits, [1500, 3000]);
  n = 0;
  await assert.rejects(withBuildRetry(flaky, { building: false, sleep: async () => {} }), /statement timeout/);
  assert.equal(n, 1);
});
test('build: a refusal (42501) or a missing row is never tried again; five timeouts in a row still fail', async () => {
  let n = 0;
  await assert.rejects(withBuildRetry(async () => { n++; throw new RpcError('permission denied', '42501', undefined, 403); }, { building: true, sleep: async () => {} }), /permission/);
  assert.equal(n, 1);
  n = 0;
  await assert.rejects(withBuildRetry(async () => { n++; throw new RpcError('timeout', '57014', undefined, 500); }, { building: true, sleep: async () => {} }), /timeout/);
  assert.equal(n, 5);
});

test('run time: an error from before the statement ran (schema cache reload, no connection) is tried twice more, quickly', async () => {
  for (const code of ['PGRST002', 'PGRST001', '53300', '08006']) {
    let n = 0; const waits: number[] = [];
    const flaky = async () => { n++; if (n < 3) throw new RpcError('Could not query the database for the schema cache. Retrying.', code, undefined, 503); return 'car'; };
    assert.equal(await withBuildRetry(flaky, { building: false, sleep: async (ms) => { waits.push(ms); } }), 'car');
    assert.equal(n, 3);
    assert.deepEqual(waits, [300, 600]);
  }
  let n = 0;
  const down = async () => { n++; throw new RpcError('schema cache', 'PGRST002', undefined, 503); };
  await assert.rejects(withBuildRetry(down, { building: false, sleep: async () => {} }), /schema cache/);
  assert.equal(n, 3);
});
test('run time: a timeout, a refusal or a network error is not repeated', async () => {
  for (const e of [new RpcError('timeout', '57014', undefined, 500), new RpcError('denied', '42501', undefined, 401), new TypeError('fetch failed'), new RpcError('bad gateway', undefined, undefined, 502)]) {
    let n = 0;
    await assert.rejects(withBuildRetry(async () => { n++; throw e; }, { building: false, sleep: async () => {} }));
    assert.equal(n, 1);
  }
});

test('0106: a deadline gives up on a hanging call with the statement-timeout code, and it is not tried again at run time', async () => {
  const { DEADLINE_CODE, didNotRun } = await import('./postgrest.ts');
  let calls = 0;
  const hang = (async (_u: string | URL | Request, init?: RequestInit) => {
    calls++;
    return new Promise<Response>((_r, reject) => { init?.signal?.addEventListener('abort', () => reject(new DOMException('The operation was aborted', 'TimeoutError'))); });
  }) as typeof fetch;
  const t0 = Date.now();
  // (AbortSignal.timeout's timer does not hold Node's event loop; the app's own call runs inside a request)
  const ac = new AbortController(); setTimeout(() => ac.abort(new DOMException('timeout', 'TimeoutError')), 50);
  const signal = ac.signal;
  const run = () => postgrestRpc(hang, T, 'car_page', {}, { role: 'anon' }, signal);
  await assert.rejects(withBuildRetry(run, { building: false, sleep: async () => {} }), (e: unknown) => e instanceof RpcError && e.code === DEADLINE_CODE && /busy/.test(e.message));
  assert.ok(Date.now() - t0 < 1000, 'gave up fast');
  assert.equal(calls, 1, 'not repeated');
  assert.equal(didNotRun(new RpcError('x', DEADLINE_CODE)), false);
  // an already spent deadline does not even send the call
  await assert.rejects(postgrestRpc(hang, T, 'car_page', {}, { role: 'anon' }, signal), (e: unknown) => e instanceof RpcError && e.code === DEADLINE_CODE);
  assert.equal(calls, 1);
  // without a deadline the call is as before
  assert.deepEqual(await postgrestRpc(mock(200, '{"a":1}').f, T, 'car_page', {}, { role: 'anon' }), { a: 1 });
});
