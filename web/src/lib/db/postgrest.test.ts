// The PostgREST call against a mocked fetch: the headers for each role, the body, null for void, errors.
//   node --test --experimental-strip-types src/lib/db/postgrest.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { postgrestRpc, RpcError } from './postgrest.ts';

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
