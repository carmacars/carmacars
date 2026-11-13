import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MAX_REDIRECTS, privateHost, syncOne, type DueFeed, type Fetch, type Store } from './sync-run.ts';

const ICS = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//example.test//EN\r\nEND:VCALENDAR\r\n';
const feed = (url: string): DueFeed => ({ id: 'f1', url, platform: 'other', etag: null, last_modified: null });
function store() {
  const seen: { ok: number; failed: string[] } = { ok: 0, failed: [] };
  const s: Store = { async due() { return []; }, async ok() { seen.ok++; return null; }, async failed(_id, error) { seen.failed.push(error); return null; } };
  return { s, seen };
}

test('addresses only the server can reach are never read', () => {
  for (const u of ['http://localhost/a.ics', 'http://127.0.0.1/', 'http://127.1/', 'http://2130706433/', 'http://0x7f.0.0.1/', 'http://10.1.2.3/', 'http://172.16.0.9/', 'http://192.168.1.1/',
    'http://169.254.169.254/latest/meta-data/', 'http://100.64.0.1/', 'http://0.0.0.0/', 'http://[::1]/', 'http://[::ffff:127.0.0.1]/', 'http://[fd00::1]/', 'http://[fe80::1]/', 'http://[::]/',
    'http://kong:8000/', 'http://db/', 'https://kong./', 'https://meta.internal/', 'https://printer.local/', 'https://nas.lan/', 'not a url']) {
    assert.equal(privateHost(u), true, u);
  }
  for (const u of ['https://calendar.example.test/feed.ics', 'http://ical.example.test/x', 'https://8.8.8.8/x.ics', 'https://[2606:4700::1111]/x.ics', 'https://example.test./x.ics']) {
    assert.equal(privateHost(u), false, u);
  }
});

test('a redirect to a private address is refused, and nothing there is asked for', async () => {
  const asked: string[] = [];
  const f: Fetch = async (u) => { asked.push(u); return new Response(null, { status: 302, headers: { location: 'http://169.254.169.254/latest/' } }); };
  const { s, seen } = store();
  const r = await syncOne(feed('https://calendar.example.test/a.ics'), s, f);
  assert.equal(r.ok, false);
  assert.deepEqual(asked, ['https://calendar.example.test/a.ics']);
  assert.match(seen.failed[0]!, /cannot be read from the server/);
});

test('a redirect to a name without a dot, or to another scheme, is refused', async () => {
  for (const location of ['http://rest:3000/', 'file:///etc/hostname', '//db/x']) {
    const asked: string[] = [];
    const f: Fetch = async (u) => { asked.push(u); return new Response(null, { status: 301, headers: { location } }); };
    const { s } = store();
    const r = await syncOne(feed('https://calendar.example.test/a.ics'), s, f);
    assert.equal(r.ok, false, location);
    assert.equal(asked.length, 1, location);
  }
});

test('a public redirect is followed (relative ones too), each hop asked for without following on its own', async () => {
  const asked: Array<{ u: string; redirect: unknown }> = [];
  const f: Fetch = async (u, init) => {
    asked.push({ u, redirect: init.redirect });
    if (u === 'https://calendar.example.test/a.ics') return new Response(null, { status: 302, headers: { location: '/b.ics' } });
    if (u === 'https://calendar.example.test/b.ics') return new Response(null, { status: 307, headers: { location: 'https://cdn.example.test/c.ics' } });
    return new Response(ICS, { status: 200, headers: { 'content-type': 'text/calendar' } });
  };
  const { s, seen } = store();
  const r = await syncOne(feed('https://calendar.example.test/a.ics'), s, f);
  assert.equal(r.ok, true);
  assert.equal(seen.ok, 1);
  assert.deepEqual(asked.map((x) => x.u), ['https://calendar.example.test/a.ics', 'https://calendar.example.test/b.ics', 'https://cdn.example.test/c.ics']);
  assert.ok(asked.every((x) => x.redirect === 'manual'));
});

test('a redirect loop stops', async () => {
  let n = 0;
  const f: Fetch = async () => { n++; return new Response(null, { status: 302, headers: { location: 'https://calendar.example.test/a.ics' } }); };
  const { s, seen } = store();
  const r = await syncOne(feed('https://calendar.example.test/a.ics'), s, f);
  assert.equal(r.ok, false);
  assert.equal(n, MAX_REDIRECTS + 1);
  assert.match(seen.failed[0]!, /too many times/);
});

test('not modified is still an answer, and a private first address is refused unless allowed', async () => {
  const f: Fetch = async () => new Response(null, { status: 304 });
  const a = store();
  assert.equal((await syncOne(feed('https://calendar.example.test/a.ics'), a.s, f)).notModified, true);
  const b = store();
  assert.equal((await syncOne(feed('http://127.0.0.1:54321/a.ics'), b.s, f)).ok, false);
  const c = store();
  assert.equal((await syncOne(feed('http://127.0.0.1:54321/a.ics'), c.s, f, { allowPrivate: true })).notModified, true);
});
