import { test } from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs/promises';
import { WindowLimiter, geoCode, geoCookie, geoFromHeaders, keptCopies } from './node-edge.ts';

const from = (h: Record<string, string>) => (n: string) => h[n] ?? null;

test('geo: Cloudflare headers give country, region, city and a rounded position', () => {
  const g = geoFromHeaders(from({ 'cf-ipcountry': 'ca', 'cf-region-code': 'on', 'cf-ipcity': 'Toronto', 'cf-iplatitude': '43.65321', 'cf-iplongitude': '-79.38318' }));
  assert.deepEqual(g, { country: 'CA', region: 'ON', city: 'Toronto', lat: 43.65, lon: -79.38 });
  assert.equal(geoCode(g), 'CA-ON');
});

test('geo: no country header, Tor or unknown means nothing at all (a request that did not come through Cloudflare)', () => {
  for (const h of [{}, { 'cf-ipcountry': 'XX' }, { 'cf-ipcountry': 'T1' }, { 'cf-ipcity': 'Toronto', 'cf-region-code': 'ON' }, { 'cf-ipcountry': 'Canada' }]) {
    const g = geoFromHeaders(from(h as Record<string, string>));
    assert.deepEqual(g, { country: null, region: null, city: null, lat: null, lon: null });
    assert.equal(geoCode(g), null);
  }
});

test('geo: a city sent as UTF-8 bytes is read as text; a bad region or position is dropped', () => {
  const bytes = Array.from(new TextEncoder().encode('Montréal'), (b) => String.fromCharCode(b)).join('');
  const g = geoFromHeaders(from({ 'cf-ipcountry': 'CA', 'cf-ipcity': bytes, 'cf-region-code': 'not a code', 'cf-iplatitude': '900', 'cf-iplongitude': 'x' }));
  assert.equal(g.city, 'Montréal');
  assert.equal(g.region, null);
  assert.equal(g.lat, null);
  assert.equal(g.lon, null);
  assert.equal(geoCode(g), 'CA');
});

test('the cc_geo cookie is set once a day and not again while the browser has the same value', () => {
  const g = { country: 'CA', region: 'ON' };
  assert.equal(geoCookie(g, null, true), 'cc_geo=CA-ON; Path=/; Max-Age=86400; SameSite=Lax; Secure');
  assert.equal(geoCookie(g, 'a=1; cc_geo=CA-ON', true), null);
  assert.equal(geoCookie(g, 'cc_geo=CA-QC', false), 'cc_geo=CA-ON; Path=/; Max-Age=86400; SameSite=Lax');
  assert.equal(geoCookie({ country: null, region: null }, null, true), null);
});

test('the limiter lets 60 through in a minute, then refuses until the next minute', () => {
  const l = new WindowLimiter(60, 60_000);
  let ok = 0;
  for (let i = 0; i < 100; i++) if (l.take('bytespider', 1_000 + i)) ok++;
  assert.equal(ok, 60);
  assert.equal(l.take('other', 1_500), true);
  assert.equal(l.take('bytespider', 61_001), true);
});

test('last good copies: kept, read back, not rewritten while fresh, gone after a week, pruned to the cap', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'copies-'));
  try {
    const c = await keptCopies(dir, { maxFiles: 2 });
    const t0 = Date.parse('2026-11-12T12:00:00Z');
    assert.equal(await c.get('https://edge.stale/a', t0), null);
    await c.put('https://edge.stale/a', Buffer.from('<html>one</html>'), t0);
    assert.equal((await c.get('https://edge.stale/a', t0))?.body.toString(), '<html>one</html>');
    // fresh: the second write within ten minutes is skipped
    await c.put('https://edge.stale/a', Buffer.from('<html>two</html>'), t0 + 60_000);
    assert.equal((await c.get('https://edge.stale/a', t0 + 60_000))?.body.toString(), '<html>one</html>');
    await c.put('https://edge.stale/a', Buffer.from('<html>three</html>'), t0 + 11 * 60_000);
    assert.equal((await c.get('https://edge.stale/a', t0 + 11 * 60_000))?.body.toString(), '<html>three</html>');
    assert.equal(await c.get('https://edge.stale/a', t0 + 8 * 86_400_000), null);
    await c.put('https://edge.stale/b', Buffer.from('b'), t0 + 20 * 60_000);
    await c.put('https://edge.stale/c', Buffer.from('c'), t0 + 30 * 60_000);
    assert.equal(await c.prune(t0 + 40 * 60_000), 1);
    assert.equal(await c.get('https://edge.stale/a', t0 + 40 * 60_000), null);
    assert.equal((await c.get('https://edge.stale/c', t0 + 40 * 60_000))?.body.toString(), 'c');
    assert.equal(await c.prune(t0 + 9 * 86_400_000), 2);
  } finally { await fs.rm(dir, { recursive: true, force: true }); }
});
