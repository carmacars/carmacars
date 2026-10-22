import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cleanBeacon, cleanBeat, isBeat, within } from './shared.ts';

const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148';
const base = { sid: '6f1c2a5e-1111-4a2b-8c3d-1234567890ab', vid: '6f1c2a5e-2222-4a2b-8c3d-1234567890ab', consent: 'analytics' };

test('0086 events pass with their listed details only', () => {
  const b = cleanBeacon({ ...base, ad: '1', events: [
    { k: 'quote_seen', slug: 'kia', d: { days: 3, total: '320', avail: '1', email: 'x@y.z' } },
    { k: 'help_open', d: { topic: 'deposit', question: 'typed text' } },
    { k: 'contact_click', d: { via: 'call', number: '4165550000' } },
    { k: 'keystroke', d: { key: 'a' } }
  ] }, UA)!;
  assert.equal(b.ad, '1');
  assert.deepEqual(b.events.map((e) => e.k), ['quote_seen', 'help_open', 'contact_click']);
  assert.deepEqual(b.events[0]!.d, { days: '3', total: '320', avail: '1' });
  assert.deepEqual(b.events[1]!.d, { topic: 'deposit' });
  assert.deepEqual(b.events[2]!.d, { via: 'call' });
});

test('dates keep working and no ad flag without one', () => {
  const b = cleanBeacon({ ...base, events: [{ k: 'search', d: { pickup: '2026-11-02', return: '2026-11-05' } }] }, UA)!;
  assert.equal(b.ad, undefined);
  assert.deepEqual(b.events[0]!.d, { pickup: '2026-11-02', return: '2026-11-05' });
});

// 0103: the heartbeat and the last batch of a page
test('a heartbeat carries the ids, the page without its query, and the end', () => {
  assert.equal(isBeat({ ...base, beat: 1 }), true);
  assert.equal(isBeat({ ...base, events: [] }), false);
  assert.deepEqual(cleanBeat({ ...base, beat: 1, path: '/cars/kia?from=2026-11-02', consent: 'analytics', extra: 'x' }), { sid: base.sid, vid: base.vid, path: '/cars/kia' });
  assert.deepEqual(cleanBeat({ ...base, beat: '1', end: '1' }), { sid: base.sid, vid: base.vid, end: '1' });
  assert.equal(cleanBeat({ ...base, beat: 1, path: 'https://elsewhere.example/x' })!.path, undefined);
  assert.equal(cleanBeat({ beat: 1, sid: 'nope', vid: base.vid }), null);
  assert.equal(cleanBeat({ ...base }), null);
});

test('the last batch of a page is marked to end the session', () => {
  assert.equal(cleanBeacon({ ...base, end: '1', events: [{ k: 'page_leave', path: '/', ms: 5000 }] }, UA)!.end, '1');
  assert.equal(cleanBeacon({ ...base, events: [] }, UA)!.end, undefined);
});

test('the beacon waits for the database only so long, and never fails because of it', async () => {
  assert.equal(await within(Promise.resolve('ok'), 50), 'ok');
  assert.equal(await within(new Promise((r) => setTimeout(() => r('late'), 200)), 20), undefined);
  assert.equal(await within(Promise.reject(new Error('down')), 50), undefined);
});
