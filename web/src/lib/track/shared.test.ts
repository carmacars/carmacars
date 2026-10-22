import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cleanBeacon } from './shared.ts';

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
