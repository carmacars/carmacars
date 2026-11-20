import assert from 'node:assert/strict';
import { test } from 'node:test';
import vm from 'node:vm';
import { keptReferrer, nextSource, parseSource, SOURCE_SCRIPT, SRC_COOKIE, touchOf } from './source.ts';

const NOW = new Date('2026-11-20T15:00:00Z');

test('the referring page is kept as host and path, with the words searched when the address carries them', () => {
  assert.equal(keptReferrer('https://www.google.com/', 'https://carmacars.ca'), 'www.google.com/');
  assert.equal(keptReferrer('https://duckduckgo.com/?q=kill+switch+for+car&ia=web', 'https://carmacars.ca'), 'duckduckgo.com/?q=kill%20switch%20for%20car');
  assert.equal(keptReferrer('https://chatgpt.com/c/abc?model=x', 'https://carmacars.ca'), 'chatgpt.com/c/abc');
  assert.equal(keptReferrer('https://carmacars.ca/cars', 'https://carmacars.ca'), undefined);
  assert.equal(keptReferrer('android-app://com.google.android.gm/', 'https://carmacars.ca'), undefined);
});

test('a page view from outside or with a campaign tag is a touch; a page inside the site is not', () => {
  const a = touchOf('https://carmacars.ca/trackers?utm_source=chatgpt.com&gclid=G1', 'https://chatgpt.com/', NOW);
  assert.deepEqual(a.touch, { landing: '/trackers', at: NOW.toISOString(), ref: 'chatgpt.com/', utm: { source: 'chatgpt.com' }, click: { kind: 'gclid', id: 'G1' } });
  assert.equal(a.fresh, true);
  assert.equal(touchOf('https://carmacars.ca/cars', 'https://carmacars.ca/', NOW).fresh, false);
});

test('the first touch never changes; a later visit from outside is the last touch; a direct first visit keeps its landing page', () => {
  const first = nextSource(null, 'https://carmacars.ca/trackers/kill-switch-for-car', '', NOW)!;
  assert.deepEqual(first, { f: { landing: '/trackers/kill-switch-for-car', at: NOW.toISOString() } });
  assert.equal(nextSource(first, 'https://carmacars.ca/cars', 'https://carmacars.ca/trackers', NOW), null);
  const later = nextSource(first, 'https://carmacars.ca/cars?utm_source=newsletter', 'https://www.bing.com/search?q=car+rental+toronto', NOW)!;
  assert.equal(later.f.landing, '/trackers/kill-switch-for-car');
  assert.deepEqual(later.l, { ref: 'www.bing.com/search?q=car%20rental%20toronto', landing: '/cars' });
});

test('the server trusts only the known keys of the cookie, cut short', () => {
  assert.equal(parseSource(undefined), null);
  assert.equal(parseSource('not json'), null);
  assert.equal(parseSource(encodeURIComponent(JSON.stringify({ f: { landing: 'no-slash' } }))), null);
  const raw = encodeURIComponent(JSON.stringify({ f: { landing: '/cars', ref: 'x'.repeat(400), at: 'yesterday', utm: { source: 'google', evil: '1' }, click: { kind: 'nope', id: '1' }, extra: 1 }, l: { landing: '/faq', ref: 'bing.com/' }, z: 1 }));
  const p = parseSource(raw)!;
  assert.equal(p.f.ref!.length, 260);
  assert.deepEqual(p.f.utm, { source: 'google' });
  assert.equal(p.f.at, undefined);
  assert.equal(p.f.click, undefined);
  assert.deepEqual(p.l, { ref: 'bing.com/', landing: '/faq' });
  assert.equal(parseSource('x'.repeat(3000)), null);
});

test('the head script writes the same cookie as nextSource', () => {
  const run = (cookie: string, href: string, referrer: string) => {
    const u = new URL(href);
    const document = { cookie, referrer };
    const jar: string[] = [];
    Object.defineProperty(document, 'cookie', { get: () => cookie, set: (v: string) => { jar.push(v); } });
    vm.runInNewContext(SOURCE_SCRIPT, { document, location: { origin: u.origin, search: u.search, pathname: u.pathname, protocol: u.protocol }, URLSearchParams, URL, JSON, Date, encodeURIComponent, decodeURIComponent, Object });
    return jar[0] ? parseSource(jar[0].split(';')[0]!.slice(SRC_COOKIE.length + 1)) : null;
  };
  const first = run('', 'https://carmacars.ca/trackers?utm_source=chatgpt.com', 'https://chatgpt.com/')!;
  assert.equal(first.f.landing, '/trackers'); assert.equal(first.f.ref, 'chatgpt.com/'); assert.deepEqual(first.f.utm, { source: 'chatgpt.com' });
  const cookie = `${SRC_COOKIE}=${encodeURIComponent(JSON.stringify(first))}`;
  assert.equal(run(cookie, 'https://carmacars.ca/cars', 'https://carmacars.ca/trackers'), null);
  const later = run(cookie, 'https://carmacars.ca/faq?gclid=abc', '')!;
  assert.equal(later.f.landing, '/trackers'); assert.equal(later.l?.landing, '/faq');
});
