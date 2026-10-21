// The edge copy of the public pages and the cron tick's question (src/lib/edge/page-cache.ts, cron-gate.ts).
//   node --test --experimental-strip-types src/lib/edge/page-cache.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EDGE_GEN_KEY, STORE_MARGIN_MS, bumpGeneration, deploymentOf, edgeKeep, edgeKey as keyOf, edgeMatch, edgeTtl, isProbe, readGeneration, tagsTouchPublic } from './page-cache.ts';
import { jobsToRun } from './cron-gate.ts';

const req = (url: string, h: Record<string, string> = {}, method = 'GET') => ({ method, url, headers: new Headers(h) });
const edgeKey = (r: ReturnType<typeof req>) => keyOf(r, 'v1');

test('only plain public GETs (and cached RSC answers by their segment) have a key', () => {
  assert.equal(edgeKey(req('https://carmacars.ca/cars/porsche-911')), 'https://edge.cache/v1/carmacars.ca/cars/porsche-911');
  assert.equal(edgeKey(req('https://carmacars.ca/cars/porsche-911/')), 'https://edge.cache/v1/carmacars.ca/cars/porsche-911');
  assert.equal(edgeKey(req('https://carmacars.ca/')), 'https://edge.cache/v1/carmacars.ca/');
  assert.equal(edgeKey(req('https://carmacars.ca/sitemap-cars.xml')), 'https://edge.cache/v1/carmacars.ca/sitemap-cars.xml');
  for (const u of ['/admin', '/admin/audit', '/account/bookings/1', '/owner', '/va', '/api/health', '/field', '/investor', '/files/x/y', '/_next/static/a.js', '/two-step', '/sign/driver/t'])
    assert.equal(edgeKey(req('https://carmacars.ca' + u)), null, u);
  assert.equal(edgeKey(req('https://carmacars.ca/cars', {}, 'POST')), null);
  assert.equal(edgeKey(req('https://carmacars.ca/cars', {}, 'HEAD')), null);
  assert.equal(edgeKey(req('https://carmacars.ca/cars?from=2026-11-01')), null, 'a query string goes to the app');
  assert.equal(edgeKey(req('https://carmacars.ca/cars?_rsc=abc')), null, '_rsc without the rsc header');
  assert.equal(edgeKey(req('https://carmacars.ca/cars', { 'next-action': 'x' })), null);
  assert.equal(edgeKey(req('https://carmacars.ca/cars', { 'x-prerender-revalidate': 'x' })), null);
  assert.equal(edgeKey(req('https://carmacars.ca/cars', { cookie: 'a=1; __prerender_bypass=1' })), null);
  assert.equal(edgeKey(req('https://carmacars.ca/cars?_rsc=abc', { rsc: '1' })), 'https://edge.cache/v1/carmacars.ca/cars?rsc=1&seg=');
  assert.equal(edgeKey(req('https://carmacars.ca/cars?_rsc=def', { rsc: '1', 'next-router-segment-prefetch': '/_tree', 'next-router-state-tree': '%5B%5D' })),
    'https://edge.cache/v1/carmacars.ca/cars?rsc=1&seg=%2F_tree');
  // a signed-in visitor gets the same public page (OpenNext serves the page cache whatever the cookies)
  assert.equal(edgeKey(req('https://carmacars.ca/cars', { cookie: 'sb-x-auth-token=abc' })), 'https://edge.cache/v1/carmacars.ca/cars');
});

test('a copy belongs to one deployment', () => {
  assert.equal(keyOf(req('https://carmacars.ca/cars'), 'a1b2'), 'https://edge.cache/a1b2/carmacars.ca/cars');
  assert.notEqual(keyOf(req('https://carmacars.ca/cars'), 'a1b2'), keyOf(req('https://carmacars.ca/cars'), 'c3d4'));
  assert.equal(deploymentOf({ CF_VERSION_METADATA: { id: 'ver-1', tag: '' } }), 'ver-1');
  assert.equal(deploymentOf({}), null, 'without the version id no copy is used');
  assert.equal(deploymentOf({ CF_VERSION_METADATA: { id: '' } }), null);
});

test('only a page cache HIT (or a sitemap) is kept, for the time OpenNext calls it fresh, at most a day', () => {
  const h = (o: Record<string, string>) => new Headers(o);
  assert.equal(edgeTtl('/cars', 200, h({ 'x-opennext-cache': 'HIT', 'cache-control': 's-maxage=2768, stale-while-revalidate=2592000' })), 2768);
  assert.equal(edgeTtl('/cars', 200, h({ 'x-opennext-cache': 'HIT', 'cache-control': 's-maxage=31536000, stale-while-revalidate=2592000' })), 86400);
  assert.equal(edgeTtl('/cars', 200, h({ 'x-opennext-cache': 'HIT', 'cache-control': 's-maxage=5, stale-while-revalidate=2592000' })), 0, 'about to go stale');
  assert.equal(edgeTtl('/cars', 200, h({ 'x-opennext-cache': 'STALE', 'cache-control': 's-maxage=1, stale-while-revalidate=2592000' })), 0);
  assert.equal(edgeTtl('/cars', 200, h({ 'x-opennext-cache': 'MISS', 'cache-control': 's-maxage=3600' })), 0);
  assert.equal(edgeTtl('/cars', 200, h({ 'cache-control': 's-maxage=3600' })), 0, 'a render, not a cache answer');
  assert.equal(edgeTtl('/cars', 404, h({ 'x-opennext-cache': 'HIT', 'cache-control': 's-maxage=3600' })), 0);
  assert.equal(edgeTtl('/cars', 200, h({ 'x-opennext-cache': 'HIT', 'cache-control': 's-maxage=3600', 'set-cookie': 'a=1' })), 0);
  assert.equal(edgeTtl('/cars', 200, h({ 'x-opennext-cache': 'HIT', 'cache-control': 'private, no-cache, no-store, max-age=0, must-revalidate' })), 0);
  assert.equal(edgeTtl('/sitemap.xml', 200, h({ 'cache-control': 'public, max-age=0, s-maxage=3600' })), 3600);
  assert.equal(edgeTtl('/robots.txt', 200, h({ 'cache-control': 'public, max-age=0, s-maxage=3600' })), 3600);
  assert.equal(edgeTtl('/sitemap.xml', 500, h({ 'cache-control': 'public, max-age=0, s-maxage=3600' })), 0);
});

test('a rebuild of a public page moves the generation; a portal rebuild does not', () => {
  assert.equal(tagsTouchPublic(['_N_T_/layout']), true);
  assert.equal(tagsTouchPublic(['_N_T_/cars/porsche-911']), true);
  assert.equal(tagsTouchPublic([{ tag: '_N_T_/cars/[slug]/page' }]), true);
  assert.equal(tagsTouchPublic(['_N_T_/']), true);
  assert.equal(tagsTouchPublic(['custom-tag']), true);
  assert.equal(tagsTouchPublic(['_N_T_/admin/settings/layout', '_N_T_/account/notifications', '_N_T_/owner', '_N_T_/va/addons']), false);
  assert.equal(tagsTouchPublic(['_N_T_/admin/settings/site', '_N_T_/sitemap.xml']), true);
});

function fakeCache() {
  const m = new Map<string, Response>();
  return { m, cache: async () => ({ match: async (k: string) => m.get(k)?.clone(), put: async (k: string, r: Response) => { m.set(k, new Response(await r.arrayBuffer(), r)); } }) };
}
function fakeKv(init?: string) {
  const m = new Map<string, string>(init ? [[EDGE_GEN_KEY, init]] : []);
  return { m, kv: { get: async (k: string) => m.get(k) ?? null, put: async (k: string, v: string) => { m.set(k, v); } } };
}
const page = (body = '<html>car</html>') => new Response(body, { status: 200, headers: { 'content-type': 'text/html; charset=utf-8', 'x-opennext-cache': 'HIT', 'cache-control': 's-maxage=2000, stale-while-revalidate=2592000', etag: '"e"', vary: 'RSC, Next-Url' } });

test('kept, served again with the original headers, and not after a rebuild', async () => {
  const c = fakeCache(); const k = fakeKv(); let now = 1_000_000_000;
  const waits: Promise<unknown>[] = [];
  const d = { cache: c.cache, env: { NEXT_TAG_CACHE_KV: k.kv }, now: () => now, waitUntil: (p: Promise<unknown>) => { waits.push(p); } };
  const key = 'https://edge.cache/v1/carmacars.ca/cars/porsche-911';
  assert.equal(await edgeMatch(key, d), null);
  const out = edgeKeep(key, '/cars/porsche-911', page(), d);
  assert.equal(await out.text(), '<html>car</html>', 'the visitor still gets the body');
  await Promise.all(waits);
  const stored = c.m.get(key)!;
  assert.equal(stored.headers.get('cache-control'), 'public, max-age=2000');
  assert.equal(stored.headers.get('x-edge-stored'), String(now - STORE_MARGIN_MS));
  assert.equal(stored.headers.get('vary'), null, 'the stored copy has no Vary');
  const hit = await edgeMatch(key, d);
  assert.ok(hit);
  assert.equal(await hit!.text(), '<html>car</html>');
  assert.equal(hit!.headers.get('cache-control'), 's-maxage=2000, stale-while-revalidate=2592000', 'the original cache-control');
  assert.equal(hit!.headers.get('x-edge-cache'), 'HIT');
  assert.equal(hit!.headers.get('x-opennext-cache'), 'HIT');
  assert.equal(hit!.headers.get('x-edge-stored'), null);
  assert.equal(hit!.headers.get('vary'), 'RSC, Next-Url', 'the browser gets the Vary back');
  // a rebuild a moment ago (inside the tag store's minute): not served
  now += 10_000;
  await bumpGeneration(d.env, now - 5_000);
  assert.equal(await edgeMatch(key, d), null);
  // kept again after it: served
  edgeKeep(key, '/cars/porsche-911', page('<html>new</html>'), { ...d, now: () => now + STORE_MARGIN_MS + 1 });
  await Promise.all(waits);
  assert.equal(await (await edgeMatch(key, d))!.text(), '<html>new</html>');
});

test('a render, a STALE answer or Set-Cookie is not kept; an unreadable generation serves nothing', async () => {
  const c = fakeCache(); const waits: Promise<unknown>[] = [];
  const d = { cache: c.cache, env: { NEXT_TAG_CACHE_KV: fakeKv().kv }, waitUntil: (p: Promise<unknown>) => { waits.push(p); } };
  edgeKeep('k1', '/cars', new Response('x', { headers: { 'cache-control': 's-maxage=3600' } }), d);
  edgeKeep('k2', '/cars', new Response('x', { headers: { 'x-opennext-cache': 'STALE', 'cache-control': 's-maxage=1' } }), d);
  edgeKeep('k3', '/cars', new Response('x', { headers: { 'x-opennext-cache': 'HIT', 'cache-control': 's-maxage=3600', 'set-cookie': 'a=b' } }), d);
  await Promise.all(waits);
  assert.equal(c.m.size, 0);
  edgeKeep('k4', '/cars', page(), d); await Promise.all(waits);
  const broken = { ...d, env: { NEXT_TAG_CACHE_KV: { get: async () => { throw new Error('kv down'); }, put: async () => {} } } };
  assert.equal(await edgeMatch('k4', broken), null);
  assert.ok(await edgeMatch('k4', { ...d, env: {} }), 'no tag store (pages served as built): served');
});

test('the generation in D1 when there is no KV', async () => {
  const rows = new Map<string, number>(); let created = false;
  const db = { prepare: (q: string) => {
    const run = async (...v: unknown[]) => { if (/CREATE TABLE/.test(q)) created = true; else if (/INSERT/.test(q)) rows.set(String(v[0]), Number(v[1])); return {}; };
    const first = async (...v: unknown[]) => { if (!created) throw new Error('D1_ERROR: no such table: edge_generation'); return rows.has(String(v[0])) ? { v: rows.get(String(v[0])) } : null; };
    return { bind: (...v: unknown[]) => ({ run: () => run(...v), first: () => first(...v) }), run: () => run(), first: () => first() };
  } };
  assert.equal(await readGeneration({ NEXT_TAG_CACHE_D1: db }), 0, 'before the first bump');
  await bumpGeneration({ NEXT_TAG_CACHE_D1: db }, 123);
  assert.equal(await readGeneration({ NEXT_TAG_CACHE_D1: db }), 123);
});

test('scanners are answered without the app; real pages are not', () => {
  for (const p of ['/wp-login.php', '/wp-admin/setup-config.php', '/.env', '/.git/config', '/xmlrpc.php', '/index.php', '/cgi-bin/x', '/backup.sql', '/a/b.aspx', '/vendor/phpunit/x'])
    assert.equal(isProbe(p), true, p);
  for (const p of ['/', '/cars', '/cars/porsche-911', '/sitemap.xml', '/robots.txt', '/.well-known/security.txt', '/guides/environment', '/rent/php-car'])
    assert.equal(isProbe(p), false, p);
});

test('cron tick: asks the database once; runs everything when it cannot tell', async () => {
  const env = { DATA_BACKEND: 'supabase', NEXT_PUBLIC_SUPABASE_URL: 'https://p.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'svc' };
  const calls: string[] = [];
  const f = (body: string, status = 200) => (async (url: string | URL | Request, init?: RequestInit) => { calls.push(String(url) + ' ' + (init?.headers as Record<string, string>).authorization); return new Response(body, { status }); }) as typeof fetch;
  assert.deepEqual(await jobsToRun(env, f('{"listing":false,"seo":false}')), { listing: false, seo: false, checked: true });
  assert.equal(calls[0], 'https://p.supabase.co/rest/v1/rpc/server_jobs_due Bearer svc');
  assert.deepEqual(await jobsToRun(env, f('{"listing":true,"seo":false}')), { listing: true, seo: false, checked: true });
  assert.deepEqual(await jobsToRun(env, f('{"message":"function not found"}', 404)), { listing: true, seo: true, checked: false });
  assert.deepEqual(await jobsToRun(env, (async () => { throw new TypeError('fetch failed'); }) as typeof fetch), { listing: true, seo: true, checked: false });
  assert.deepEqual(await jobsToRun({ ...env, SUPABASE_SERVICE_ROLE_KEY: undefined }, f('{}')), { listing: true, seo: true, checked: false });
  assert.deepEqual(await jobsToRun({ ...env, DATA_BACKEND: 'local' }, f('{}')), { listing: true, seo: true, checked: false });
});
