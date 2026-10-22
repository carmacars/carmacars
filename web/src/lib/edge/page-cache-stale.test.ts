// The last good copy of the public pages (0106, src/lib/edge/page-cache.ts serveEdge): served when OpenNext answers 5xx
// or is slow, the busy page when no copy is kept, never for a session or a portal.
//   node --test --experimental-strip-types src/lib/edge/page-cache-stale.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { REFRESH_EVERY_MS, STALE_HEADER, busyPage, hasSession, refreshDue, serveEdge, staleKey, staleWorthy, type ServeDeps } from './page-cache.ts';

const req = (url: string, h: Record<string, string> = {}, method = 'GET') => ({ method, url, headers: new Headers(h) });
const html = (body: string, status = 200, x: Record<string, string> = {}) =>
  new Response(body, { status, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'private, no-cache, no-store, max-age=0, must-revalidate', ...x } });

function fakeCache() {
  const m = new Map<string, Response>();
  return { m, cache: async () => ({ match: async (k: string) => m.get(k)?.clone(), put: async (k: string, r: Response) => { m.set(k, new Response(await r.arrayBuffer(), r)); } }) };
}
/** timers the test fires by hand */
function timers() {
  const pending: Array<{ ms: number; fire: () => void; cancelled: boolean }> = [];
  const timer = (ms: number) => {
    let fire!: () => void;
    const done = new Promise<void>((r) => { fire = r; });
    const t = { ms, fire, cancelled: false };
    pending.push(t);
    return { done, cancel: () => { t.cancelled = true; } };
  };
  return { pending, timer, fire: (ms: number) => { for (const t of pending) if (t.ms === ms && !t.cancelled) t.fire(); } };
}
const tick = () => new Promise((r) => setTimeout(r, 5));

function setup(version = 'v2') {
  const c = fakeCache(); const t = timers(); const waits: Promise<unknown>[] = [];
  let answer: () => Promise<Response> = async () => html('<html>car</html>');
  let calls = 0;
  const d: ServeDeps = { cache: c.cache, env: {}, version, timer: t.timer, waitMs: 4000, giveUpMs: 25_000, refreshAfterMs: 5000,
    waitUntil: (p) => { waits.push(p); }, origin: () => { calls++; return answer(); } };
  return { c, t, d, waits, set: (f: () => Promise<Response>) => { answer = f; }, calls: () => calls, settle: async () => { await tick(); await Promise.all(waits); } };
}
const car = 'https://carmacars.ca/cars/vw-jetta-2020';

test('the stale key: public GETs without a session, no deployment in it', () => {
  assert.equal(staleKey(req(car)), 'https://edge.stale/carmacars.ca/cars/vw-jetta-2020');
  assert.equal(staleKey(req(car, { cookie: 'cc_geo=CA-ON; cc_consent=1' })), 'https://edge.stale/carmacars.ca/cars/vw-jetta-2020', 'the site\'s own cookies are not a session');
  assert.equal(staleKey(req(car, { cookie: 'cc_geo=CA-ON; sb-abcd-auth-token=base64-x' })), null, 'signed in');
  assert.equal(staleKey(req(car, { cookie: 'sb-abcd-auth-token.0=base64-x' })), null, 'signed in (chunked cookie)');
  assert.equal(staleKey(req(car, { cookie: 'cc-view-as=u1' })), null, 'an Admin viewing as someone');
  for (const u of ['/admin', '/account/bookings', '/owner', '/va', '/api/rpc/fleet', '/auth/callback', '/field'])
    assert.equal(staleKey(req('https://carmacars.ca' + u)), null, u);
  assert.equal(staleKey(req(car, {}, 'POST')), null);
  assert.equal(staleKey(req(car + '?from=2026-11-01')), null);
  assert.equal(staleKey(req(car + '?_rsc=1', { rsc: '1' })), 'https://edge.stale/carmacars.ca/cars/vw-jetta-2020?rsc=1&seg=');
  assert.equal(hasSession('a=1; sb-x-auth-token=y'), true);
  assert.equal(hasSession('a=1; sb-x-auth-token-code-verifier=y'), false);
  assert.equal(hasSession(null), false);
});

test('what counts as a good answer', () => {
  const h = (o: Record<string, string>) => new Headers(o);
  assert.equal(staleWorthy(200, h({ 'content-type': 'text/html' })), true);
  assert.equal(staleWorthy(200, h({ 'content-type': 'text/x-component' })), true);
  assert.equal(staleWorthy(200, h({ 'content-type': 'application/xml' })), true);
  assert.equal(staleWorthy(200, h({ 'content-type': 'text/plain' })), true, 'robots.txt');
  assert.equal(staleWorthy(500, h({ 'content-type': 'text/html' })), false);
  assert.equal(staleWorthy(404, h({ 'content-type': 'text/html' })), false);
  assert.equal(staleWorthy(307, h({ 'content-type': 'text/html' })), false);
  assert.equal(staleWorthy(200, h({ 'content-type': 'text/html', 'set-cookie': 'a=1' })), false);
  assert.equal(staleWorthy(200, h({ 'content-type': 'application/json' })), false);
  assert.equal(staleWorthy(200, h({ 'content-type': 'text/html', [STALE_HEADER]: 'busy' })), false, 'never a copy of a copy');
});

test('a 500 after a good answer: the last good copy, marked, and the page asked for again later', async () => {
  const s = setup(); const k = staleKey(req(car))!;
  const first = await serveEdge(req(car), null, k, '/cars/vw-jetta-2020', s.d);
  assert.equal(await first.text(), '<html>car</html>');
  await s.settle();
  assert.ok(s.c.m.has(k), 'kept');
  assert.equal(s.c.m.get(k)!.headers.get('cache-control'), 'public, max-age=604800', 'kept a week');

  s.set(async () => html('<html>Internal Server Error</html>', 500));
  const r = await serveEdge(req(car), null, k, '/cars/vw-jetta-2020', s.d);
  assert.equal(r.status, 200);
  assert.equal(await r.text(), '<html>car</html>');
  assert.match(r.headers.get(STALE_HEADER)!, /^error 500; age=\d+$/);
  assert.equal(r.headers.get('x-edge-cache'), 'STALE');
  assert.equal(r.headers.get('cache-control'), 'no-cache', 'never kept by the browser');
  // the refresh: five seconds later, once; the site answers again and the copy is replaced
  assert.equal(s.calls(), 2);
  s.set(async () => html('<html>car, new price</html>'));
  s.t.fire(5000);
  await s.settle();
  assert.equal(s.calls(), 3);
  assert.equal(await s.c.m.get(k)!.clone().text(), '<html>car, new price</html>');
  // another 500 within the minute: the copy, but no second refresh
  s.set(async () => html('x', 502));
  const r2 = await serveEdge(req(car), null, k, '/cars/vw-jetta-2020', s.d);
  assert.equal(await r2.text(), '<html>car, new price</html>');
  s.t.fire(5000); await s.settle();
  assert.equal(s.calls(), 4, 'no refresh queued twice in a minute');
});

test('an error thrown by OpenNext counts as a 5xx', async () => {
  const s = setup(); const k = staleKey(req(car))!;
  await (await serveEdge(req(car), null, k, '/cars/vw-jetta-2020', s.d)).text(); await s.settle();
  s.set(async () => { throw new Error('Worker exceeded CPU'); });
  const r = await serveEdge(req('https://carmacars.ca/cars/vw-jetta-2020'), null, k, '/cars/vw-jetta-2020', { ...s.d, now: () => Date.now() + 10 * REFRESH_EVERY_MS });
  assert.match(r.headers.get(STALE_HEADER)!, /^error 502/);
  assert.equal(await r.text(), '<html>car</html>');
});

test('slow (no answer in 4 s): the copy at once; the late answer is kept when it comes', async () => {
  const s = setup(); const k = staleKey(req(car))!;
  await (await serveEdge(req(car), null, k, '/cars/vw-jetta-2020', s.d)).text(); await s.settle();
  let finish!: (r: Response) => void;
  s.set(() => new Promise<Response>((r) => { finish = r; }));
  const p = serveEdge(req(car), null, k, '/cars/vw-jetta-2020', s.d);
  await tick();
  s.t.fire(4000);
  const r = await p;
  assert.match(r.headers.get(STALE_HEADER)!, /^slow; age=/);
  assert.equal(await r.text(), '<html>car</html>');
  finish(html('<html>car, late</html>'));
  await s.settle();
  assert.equal(await s.c.m.get(k)!.clone().text(), '<html>car, late</html>');
});

test('a fast good answer is served as is (no timer left behind)', async () => {
  const s = setup(); const k = staleKey(req(car))!;
  const r = await serveEdge(req(car), null, k, '/cars/vw-jetta-2020', s.d);
  assert.equal(r.headers.get(STALE_HEADER), null);
  assert.ok(s.t.pending.every((t) => t.cancelled), 'the 4 s timer is cancelled');
  // a 404 is an answer, not an error
  s.set(async () => html('<html>not found</html>', 404));
  const nf = await serveEdge(req('https://carmacars.ca/cars/gone'), null, staleKey(req('https://carmacars.ca/cars/gone')), '/cars/gone', s.d);
  assert.equal(nf.status, 404);
});

test('first visit, nothing kept: a 5xx becomes the busy page that retries; an RSC or a sitemap keeps its error', async () => {
  const s = setup();
  s.set(async () => html('boom', 500));
  const r = await serveEdge(req(car), null, staleKey(req(car)), '/cars/vw-jetta-2020', s.d);
  assert.equal(r.status, 503);
  assert.equal(r.headers.get('retry-after'), '5');
  assert.equal(r.headers.get('cache-control'), 'no-store');
  const body = await r.text();
  assert.match(body, /Busy for a moment, retrying/);
  assert.match(body, /location\.reload\(\)/);
  assert.doesNotMatch(body, /Internal server error/i);
  assert.doesNotMatch(body, /\u2014/, 'no em dash');
  assert.equal(s.c.m.size, 0, 'the busy page is never kept');
  const rr = req(car + '?_rsc=x', { rsc: '1' });
  assert.equal((await serveEdge(rr, null, staleKey(rr), '/cars/vw-jetta-2020', s.d)).status, 500);
  const sm = req('https://carmacars.ca/sitemap.xml');
  assert.equal((await serveEdge(sm, null, staleKey(sm), '/sitemap.xml', s.d)).status, 500);
});

test('first visit, nothing kept, slow: waits, then the answer; past the limit the busy page, and the answer is still kept', async () => {
  const s = setup(); const k = staleKey(req(car))!;
  let finish!: (r: Response) => void;
  s.set(() => new Promise<Response>((r) => { finish = r; }));
  const p = serveEdge(req(car), null, k, '/cars/vw-jetta-2020', s.d);
  await tick(); s.t.fire(4000); await tick();
  finish(html('<html>car</html>'));
  const r = await p;
  assert.equal(r.headers.get(STALE_HEADER), null, 'the real answer, after the wait');
  assert.equal(await r.text(), '<html>car</html>');

  const s2 = setup(); let finish2!: (r: Response) => void;
  s2.set(() => new Promise<Response>((r) => { finish2 = r; }));
  const p2 = serveEdge(req(car), null, k, '/cars/vw-jetta-2020', s2.d);
  await tick(); s2.t.fire(4000); await tick(); s2.t.fire(21_000);
  const busy = await p2;
  assert.equal(busy.status, 503);
  finish2(html('<html>car at last</html>'));
  await s2.settle();
  assert.equal(await s2.c.m.get(k)!.clone().text(), '<html>car at last</html>', 'kept for the next visitor');
});

test('a session, a portal or no stale key: OpenNext\'s answer as it is, never a copy', async () => {
  const s = setup(); const k = staleKey(req(car))!;
  await (await serveEdge(req(car), null, k, '/cars/vw-jetta-2020', s.d)).text(); await s.settle();
  s.set(async () => html('boom', 500));
  const signedIn = req(car, { cookie: 'sb-abcd-auth-token=base64-x' });
  const r = await serveEdge(signedIn, null, staleKey(signedIn), '/cars/vw-jetta-2020', s.d);
  assert.equal(r.status, 500);
  const admin = req('https://carmacars.ca/admin');
  assert.equal((await serveEdge(admin, null, staleKey(admin), '/admin', s.d)).status, 500);
});

test('a copy from the previous deploy: the page yes (marked), its RSC payload no', async () => {
  const s = setup('v1'); const k = staleKey(req(car))!;
  await (await serveEdge(req(car), null, k, '/cars/vw-jetta-2020', s.d)).text();
  const rr = req(car + '?_rsc=x', { rsc: '1' }); const rk = staleKey(rr)!;
  s.set(async () => new Response('0:rsc', { headers: { 'content-type': 'text/x-component' } }));
  await (await serveEdge(rr, null, rk, '/cars/vw-jetta-2020', s.d)).text();
  await s.settle();
  const next = { ...s.d, version: 'v2', now: () => Date.now() + 10 * REFRESH_EVERY_MS };
  s.set(async () => html('boom', 500));
  const page = await serveEdge(req(car), null, k, '/cars/vw-jetta-2020', next);
  assert.equal(page.status, 200);
  assert.match(page.headers.get(STALE_HEADER)!, /deploy=previous/);
  assert.equal((await serveEdge(rr, null, rk, '/cars/vw-jetta-2020', next)).status, 500);
  // the same deploy's RSC payload is served
  assert.equal(await (await serveEdge(rr, null, rk, '/cars/vw-jetta-2020', { ...s.d, now: next.now })).text(), '0:rsc');
});

test('the fresh edge copy still answers first; its keep and the stale keep share one body', async () => {
  const s = setup(); const key = 'https://edge.cache/v2/carmacars.ca/cars'; const k = staleKey(req('https://carmacars.ca/cars'))!;
  s.set(async () => new Response('<html>fleet</html>', { headers: { 'content-type': 'text/html', 'x-opennext-cache': 'HIT', 'cache-control': 's-maxage=3600' } }));
  assert.equal(await (await serveEdge(req('https://carmacars.ca/cars'), key, k, '/cars', s.d)).text(), '<html>fleet</html>');
  await s.settle();
  assert.ok(s.c.m.has(key) && s.c.m.has(k));
  s.set(async () => html('boom', 500));
  const hit = await serveEdge(req('https://carmacars.ca/cars'), key, k, '/cars', s.d);
  assert.equal(hit.headers.get('x-edge-cache'), 'HIT');
  assert.equal(s.calls(), 1, 'OpenNext not asked');
});

test('refreshDue: once a minute per page', () => {
  assert.equal(refreshDue('a', 1000), true);
  assert.equal(refreshDue('a', 1000 + REFRESH_EVERY_MS - 1), false);
  assert.equal(refreshDue('b', 1000), true);
  assert.equal(refreshDue('a', 1000 + REFRESH_EVERY_MS), true);
  assert.equal(busyPage().headers.get(STALE_HEADER), 'busy');
});
