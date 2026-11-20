import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createClient, type SessionStore } from './client.ts';
import type { MobileSession } from '../shared.ts';

const T0 = 1_800_000_000_000;
const session = (n: number, expiresIn = 3600): MobileSession => ({ access_token: `access-${n}`, refresh_token: `refresh-${n}`, expires_at: T0 / 1000 + expiresIn, user: { id: 'u1', email: 'rita@example.test', phone: null } });
function store(initial: MobileSession | null): SessionStore & { value: MobileSession | null } {
  const s = { value: initial, async get() { return s.value; }, async set(v: MobileSession | null) { s.value = v; } };
  return s;
}
type Sent = { url: string; method: string; headers: Record<string, string>; body: unknown };
function server(answer: (r: Sent, n: number) => { status?: number; json?: unknown; text?: string } | Error | Promise<never>) {
  const sent: Sent[] = [];
  const f = (async (url: string, init: RequestInit) => {
    const r: Sent = { url, method: init.method ?? 'GET', headers: init.headers as Record<string, string>, body: typeof init.body === 'string' ? JSON.parse(init.body) : init.body };
    sent.push(r);
    const a = await answer(r, sent.length);
    if (a instanceof Error) throw a;
    return { status: a.status ?? 200, ok: (a.status ?? 200) < 400, json: async () => { if (a.text !== undefined) throw new Error('not json'); return a.json; } } as Response;
  }) as unknown as typeof fetch;
  return { fetch: f, sent };
}
const make = (s: SessionStore, srv: { fetch: typeof fetch }, extra: Partial<Parameters<typeof createClient>[0]> = {}) =>
  createClient({ baseUrl: 'https://carmacars.ca/', fetch: srv.fetch, session: s, appVersion: '1.0.0', platform: 'ios', now: () => T0, ...extra });

test('a call goes to the route with its parameters, the token and the app version; a GET sends no body', async () => {
  const srv = server(() => ({ json: { ok: true, data: { booking: { booking_number: 'CC-1042' } } } }));
  const api = make(store(session(1)), srv);
  const r = await api.call('trip', { params: { number: 'CC-1042' } });
  assert.equal(r.ok, true);
  assert.equal(srv.sent[0]!.url, 'https://carmacars.ca/api/m/v1/trips/CC-1042');
  assert.equal(srv.sent[0]!.method, 'GET');
  assert.equal(srv.sent[0]!.headers.authorization, 'Bearer access-1');
  assert.equal(srv.sent[0]!.headers['x-carmacars-app'], '1.0.0 ios');
  assert.equal(srv.sent[0]!.body, undefined);
});

test('a write sends its body as JSON; a query is encoded', async () => {
  const srv = server(() => ({ json: { ok: true, data: null } }));
  const api = make(store(session(1)), srv);
  await api.call('trip.message', { params: { number: 'CC-1042' }, body: { body: 'Running 10 min late' } });
  assert.deepEqual(srv.sent[0]!.body, { body: 'Running 10 min late' });
  assert.equal(srv.sent[0]!.headers['content-type'], 'application/json');
  await api.call('sales.leads', { query: { status: 'new', q: 'a b&c', mine: undefined } });
  assert.equal(srv.sent[1]!.url, 'https://carmacars.ca/api/m/v1/sales/leads?status=new&q=a%20b%26c');
});

test('a route that needs a session is not sent without one; a public route is', async () => {
  const srv = server(() => ({ json: { ok: true, data: { cars: [], classes: [] } } }));
  const api = make(store(null), srv);
  assert.deepEqual(await api.call('trips'), { ok: false, code: 'auth', message: 'Sign in first.' });
  assert.equal(srv.sent.length, 0);
  assert.equal((await api.call('cars')).ok, true);
  assert.equal(srv.sent[0]!.headers.authorization, undefined);
});

test('a token about to end is refreshed first, once, however many calls are waiting', async () => {
  const s = store(session(1, 30));
  const srv = server((r) => (r.url.endsWith('/auth/refresh') ? { json: { ok: true, data: session(2) } } : { json: { ok: true, data: [] } }));
  const api = make(s, srv);
  await Promise.all([api.call('trips'), api.call('notices'), api.call('me')]);
  assert.equal(srv.sent.filter((r) => r.url.endsWith('/auth/refresh')).length, 1);
  assert.deepEqual(srv.sent.find((r) => r.url.endsWith('/auth/refresh'))!.body, { refresh_token: 'refresh-1' });
  for (const r of srv.sent.filter((x) => !x.url.endsWith('/auth/refresh'))) assert.equal(r.headers.authorization, 'Bearer access-2');
  assert.equal(s.value!.access_token, 'access-2');
});

test('the server says the token ended: one refresh, then the same call once more', async () => {
  const s = store(session(1));
  const srv = server((r) => {
    if (r.url.endsWith('/auth/refresh')) return { json: { ok: true, data: session(2) } };
    return r.headers.authorization === 'Bearer access-1' ? { status: 401, json: { ok: false, code: 'expired', message: 'Sign in first.' } } : { json: { ok: true, data: [{ id: 't' }] } };
  });
  const r = await make(s, srv).call('trips');
  assert.deepEqual(r, { ok: true, data: [{ id: 't' }] });
  assert.equal(srv.sent.length, 3);
});

test('a refused refresh ends the session and says so once; a busy server keeps it', async () => {
  let out = 0;
  const s = store(session(1, 10));
  const refused = server((r) => (r.url.endsWith('/auth/refresh') ? { status: 401, json: { ok: false, code: 'expired', message: 'Sign in again.' } } : { json: { ok: true, data: [] } }));
  const r = await make(s, refused, { onSignedOut: () => { out += 1; } }).call('trips');
  assert.deepEqual(r, { ok: false, code: 'auth', message: 'Sign in again.' });
  assert.equal(s.value, null);
  assert.equal(out, 1);
  assert.equal(refused.sent.length, 1);

  const s2 = store(session(1, 10));
  const busy = server((r) => (r.url.endsWith('/auth/refresh') ? { status: 503, json: { ok: false, code: 'busy', message: 'Try again.' } } : { json: { ok: true, data: [] } }));
  assert.equal((await make(s2, busy).call('trips')).ok, true);
  assert.equal(s2.value!.access_token, 'access-1');
});

test('no connection is told apart from a refusal, and reported to the offline banner', async () => {
  const seen: boolean[] = [];
  const down = server(() => new TypeError('Network request failed'));
  const r = await make(store(session(1)), down, { onReachable: (x) => seen.push(x) }).call('trips');
  assert.equal(r.ok, false);
  assert.equal(!r.ok && r.code, 'offline');
  assert.deepEqual(seen, [false]);
  const refusal = server(() => ({ status: 403, json: { ok: false, code: 'forbidden', message: 'Only field staff may do this.' } }));
  const seen2: boolean[] = [];
  const r2 = await make(store(session(1)), refusal, { onReachable: (x) => seen2.push(x) }).call('field.today');
  assert.deepEqual(r2, { ok: false, code: 'forbidden', message: 'Only field staff may do this.' });
  assert.deepEqual(seen2, [true]);
});

test('an answer that is not the envelope (a gateway page) is a plain sentence, never shown raw', async () => {
  const html = server(() => ({ status: 502, text: '<html>Bad gateway</html>' }));
  const r = await make(store(session(1)), html).call('trips');
  assert.equal(!r.ok && r.code, 'busy');
  const odd = server(() => ({ json: { hello: 'world' } }));
  assert.equal((await make(store(session(1)), odd).call('trips')).ok, false);
});

test('a slow server times out with its own message', async () => {
  const slow = { fetch: ((_: string, init: RequestInit) => new Promise((_, no) => { init.signal!.addEventListener('abort', () => no(new Error('aborted'))); })) as unknown as typeof fetch };
  const r = await make(store(session(1)), slow, { timeoutMs: 20 }).call('trips');
  assert.equal(!r.ok && r.code, 'timeout');
});

test('a success that carries where the site would go next keeps it', async () => {
  const srv = server(() => ({ json: { ok: true, data: null, next: '/account/bookings/CC-1/checkout?signed=1#pay' } }));
  const r = await make(store(session(1)), srv).call('trip.sign', { params: { number: 'CC-1' }, body: { consents: ['a'], sha: 'ab'.repeat(32), typedName: 'Rita Renter', drawn: undefined, companionSha: undefined, session: undefined, drawnPath: undefined } });
  assert.equal(r.ok && r.next, '/account/bookings/CC-1/checkout?signed=1#pay');
});

test('sign out tells the server, then forgets the session even when the server cannot be reached', async () => {
  const s = store(session(1));
  const srv = server(() => new TypeError('Network request failed'));
  await make(s, srv).signOut();
  assert.equal(s.value, null);
  assert.ok(srv.sent[0]!.url.endsWith('/auth/sign-out'));
});
