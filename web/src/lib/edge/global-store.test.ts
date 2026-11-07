// The place pages' global copy (r32, src/lib/edge/global-store.ts): kept in R2 and the data centre's mirror after a
// render, served 30 days to crawlers and 7 to people, never for a session, a query string or an RSC request.
//   node --test --experimental-strip-types src/lib/edge/global-store.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { GLOBAL_PREFIX, GLOBAL_TTL_S, PEOPLE_MAX_S, globalKeep, globalKey, globalMatch, globalWorthy, type R2Like } from './global-store.ts';
import { serveEdge, type ServeDeps } from './page-cache.ts';

const req = (url: string, h: Record<string, string> = {}, method = 'GET') => ({ method, url, headers: new Headers(h) });
const page = (body: string, x: Record<string, string> = {}) => new Response(body, { status: 200, headers: { 'content-type': 'text/html; charset=utf-8', vary: 'rsc', ...x } });

function fakes() {
  const r2 = new Map<string, { buf: ArrayBuffer; meta: Record<string, string> }>();
  const dc = new Map<string, Response>();
  const counts = { r2get: 0, r2put: 0 };
  const bucket: R2Like = {
    get: async (k) => { counts.r2get++; const o = r2.get(k); return o ? { body: new Response(o.buf).body!, customMetadata: o.meta } : null; },
    put: async (k, v, o) => { counts.r2put++; r2.set(k, { buf: v, meta: o?.customMetadata ?? {} }); }
  };
  const cache = async () => ({ match: async (k: string) => dc.get(k)?.clone(), put: async (k: string, r: Response) => { dc.set(k, new Response(await r.arrayBuffer(), r)); } });
  const waits: Promise<unknown>[] = [];
  return { r2, dc, counts, bucket, cache, waits, waitUntil: (p: Promise<unknown>) => { waits.push(p); }, settle: () => Promise.all(waits.splice(0)) };
}

test('the key: place pages only, plain GETs without a session', () => {
  assert.equal(globalKey(req('https://carmacars.ca/car-rental/austin-tx')), 'carmacars.ca/car-rental/austin-tx');
  assert.equal(globalKey(req('https://carmacars.ca/car-rental/suv-rental/austin-tx/')), 'carmacars.ca/car-rental/suv-rental/austin-tx');
  assert.equal(globalKey(req('https://carmacars.ca/detailing/ceramic-coating/austin-tx')), 'carmacars.ca/detailing/ceramic-coating/austin-tx');
  assert.equal(globalKey(req('https://carmacars.ca/body-shop/dent-repair/austin-tx')), 'carmacars.ca/body-shop/dent-repair/austin-tx');
  assert.equal(globalKey(req('https://carmacars.ca/buy/suv/austin-tx')), 'carmacars.ca/buy/suv/austin-tx');
  for (const u of ['https://carmacars.ca/', 'https://carmacars.ca/cars/some-car', 'https://carmacars.ca/car-rental/a/b/c', 'https://carmacars.ca/car-rental/austin-tx?x=1', 'https://carmacars.ca/admin/x'])
    assert.equal(globalKey(req(u)), null, u);
  assert.equal(globalKey(req('https://carmacars.ca/car-rental/austin-tx', { rsc: '1' })), null, 'RSC');
  assert.equal(globalKey(req('https://carmacars.ca/car-rental/austin-tx', {}, 'POST')), null, 'POST');
  assert.equal(globalKey(req('https://carmacars.ca/car-rental/austin-tx', { cookie: 'sb-abc-auth-token=x' })), null, 'session');
  assert.equal(globalKey(req('https://carmacars.ca/car-rental/austin-tx', { cookie: 'cc-view-as=1' })), null, 'view as');
  assert.equal(globalKey(req('https://carmacars.ca/car-rental/austin-tx', { cookie: 'cc_geo=CA-ON' })), 'carmacars.ca/car-rental/austin-tx', 'other cookies');
});

test('only a real render is kept', () => {
  const h = (x: Record<string, string>) => new Headers({ 'content-type': 'text/html', ...x });
  assert.equal(globalWorthy(200, h({})), true);
  assert.equal(globalWorthy(404, h({})), false);
  assert.equal(globalWorthy(200, h({ 'set-cookie': 'a=b' })), false);
  assert.equal(globalWorthy(200, h({ 'x-edge-stale': 'slow' })), false);
  assert.equal(globalWorthy(200, h({ 'x-edge-cache': 'HIT' })), false);
  assert.equal(globalWorthy(200, new Headers({ 'content-type': 'text/x-component' })), false);
});

test('kept after a render, gzipped in R2, then served from the mirror and from R2', async () => {
  const f = fakes();
  let t = 1_000_000_000_000;
  const key = 'carmacars.ca/car-rental/austin-tx';
  const body = '<html><script>1</script>' + 'x'.repeat(20_000) + '</html>';
  const out = globalKeep(key, page(body, { 'set-cookie-not': '' }), { bucket: f.bucket, cache: f.cache, waitUntil: f.waitUntil, now: () => t });
  assert.equal(await out.text(), body);
  await f.settle();
  const stored = f.r2.get(GLOBAL_PREFIX + key)!;
  assert.ok(stored.buf.byteLength < 2_000, `gzipped (${stored.buf.byteLength} bytes)`);
  assert.equal(stored.meta.s, String(t));
  assert.equal(JSON.parse(stored.meta.h!).vary, 'rsc');
  t += 3600_000;
  const m = await globalMatch(key, { bucket: f.bucket, cache: f.cache, waitUntil: f.waitUntil, crawler: false, now: () => t });
  assert.equal(m!.headers.get('x-edge-cache'), 'GLOBAL-DC');
  assert.equal(await m!.text(), body);
  assert.equal(f.counts.r2get, 0, 'the mirror answers without an R2 read');
  assert.equal(m!.headers.get('cache-control'), 'public, max-age=300');
  // another data centre: no mirror, R2 answers and fills its mirror
  f.dc.clear();
  const r = await globalMatch(key, { bucket: f.bucket, cache: f.cache, waitUntil: f.waitUntil, crawler: true, now: () => t });
  assert.equal(r!.headers.get('x-edge-cache'), 'GLOBAL');
  assert.equal(await r!.text(), body);
  await f.settle();
  assert.equal(f.dc.size, 1, 'the mirror is filled');
});

test('30 days for crawlers, 7 for people; a crawler asking "changed since?" gets 304', async () => {
  const f = fakes();
  const t0 = 1_000_000_000_000;
  const key = 'carmacars.ca/car-rental/austin-tx';
  globalKeep(key, page('<html>a</html>'), { bucket: f.bucket, cache: f.cache, waitUntil: f.waitUntil, now: () => t0 });
  await f.settle();
  const at = (days: number, crawler: boolean, ims?: string) => globalMatch(key, { bucket: f.bucket, cache: f.cache, waitUntil: f.waitUntil, crawler, ifModifiedSince: ims, now: () => t0 + days * 86_400_000 });
  assert.ok(await at(PEOPLE_MAX_S / 86_400 - 0.1, false));
  assert.equal(await at(PEOPLE_MAX_S / 86_400 + 0.1, false), null, 'a person: a render after 7 days');
  assert.ok(await at(GLOBAL_TTL_S / 86_400 - 0.1, true));
  assert.equal(await at(GLOBAL_TTL_S / 86_400 + 0.1, true), null, 'a crawler: a render after 30 days');
  const nm = await at(2, true, new Date(t0 + 1000).toUTCString());
  assert.equal(nm!.status, 304);
});

test('serveEdge: the global copy first, a render kept in it, never for a session', async () => {
  const f = fakes();
  const key = 'carmacars.ca/car-rental/austin-tx';
  let renders = 0;
  const deps = (crawler: boolean): ServeDeps => ({ cache: f.cache, env: {}, version: 'v1', waitUntil: f.waitUntil, origin: async () => { renders++; return page('<html>r</html>'); },
    timer: () => ({ done: new Promise(() => undefined), cancel: () => undefined }),
    global: { match: () => globalMatch(key, { bucket: f.bucket, cache: f.cache, waitUntil: f.waitUntil, crawler }), keep: (r) => globalKeep(key, r, { bucket: f.bucket, cache: f.cache, waitUntil: f.waitUntil }) } });
  const rq = req('https://carmacars.ca/car-rental/austin-tx');
  const first = await serveEdge(rq, null, null, '/car-rental/austin-tx', deps(true));
  assert.equal(await first.text(), '<html>r</html>');
  await f.settle();
  assert.equal(renders, 1);
  assert.equal(f.counts.r2put, 1);
  f.dc.clear(); // a deploy and another data centre: the global copy still answers
  const second = await serveEdge(rq, null, null, '/car-rental/austin-tx', deps(true));
  assert.equal(second.headers.get('x-edge-cache'), 'GLOBAL');
  assert.equal(await second.text(), '<html>r</html>');
  assert.equal(renders, 1, 'no second render');
  assert.equal(f.counts.r2put, 1, 'a copy served is not written again');
});
