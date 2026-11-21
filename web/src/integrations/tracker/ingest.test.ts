import { test } from 'node:test';
import assert from 'node:assert/strict';
import { BAD_PER_MINUTE, badSender, eventOf, readBatch, sign, signedHeaders, toPoint, verify } from './ingest.ts';

const KEY = 'trk_' + 'a'.repeat(64);
const body = JSON.stringify({ points: [{ device: '860000000000001', at: '2026-11-01T15:00:00Z', lat: 43.65, lng: -79.38, speed: 50 }] });
const get = (h: Record<string, string>) => (n: string) => h[n] ?? null;

test('a signed batch passes; a wrong key, an edited body, an old timestamp or no headers do not', async () => {
  const now = 1_793_545_200;
  const h = await signedHeaders(body, KEY, now);
  assert.match(h['x-tracker-signature']!, /^v1=[0-9a-f]{64}$/);
  // the signature that matched and its timestamp come back: the replay guard keeps the signature (3320)
  assert.deepEqual(await verify(body, get(h), KEY, now), { ok: true, sig: h['x-tracker-signature']!.slice(3), ts: now });
  assert.equal((await verify(body, get(h), 'trk_other', now)).reason, 'signature');
  assert.equal((await verify(body.replace('50', '90'), get(h), KEY, now)).reason, 'signature');
  assert.equal((await verify(body, get(h), KEY, now + 301)).reason, 'timestamp');
  assert.equal((await verify(body, get({}), KEY, now)).reason, 'no signature');
  assert.equal((await verify(body, get(h), null, now)).reason, 'no key');
  // the signature is HMAC-SHA256 of "<timestamp>.<body>", hex
  assert.equal(await sign('{}', 'k', 1), '3dd49b2593d0f9a349e9e71c4bde3e2b862c2be4003fe9b4ba81332029310158');
});

test('the generic JSON: aliases accepted, junk left out', () => {
  assert.deepEqual(toPoint({ device: 'SIM-0001', time: 1793545200, latitude: '43.7', longitude: -79.4, course: 90, acc: 1 }),
    { device: 'SIM-0001', at: 1793545200, lat: 43.7, lng: -79.4, speed: null, heading: 90, ignition: true, odometer: null, battery: null, power: null, fuel: null, event: null });
  assert.equal(toPoint({ device: 'x', at: 1, lat: 1, lng: 1 }), null);
  assert.equal(toPoint({ device: 'SIM-1', at: 1, lat: 0, lng: 0 }), null);
  assert.equal(toPoint({ device: 'SIM-1', lat: 43, lng: -79 }), null);
  const r = readBatch(JSON.stringify({ points: [{ device: 'SIM-1', at: 1, lat: 43, lng: -79 }, { nope: true }] }));
  assert.ok(r.ok && r.points.length === 1 && r.sent === 2);
  assert.deepEqual(readBatch('nope'), { ok: false, error: 'not JSON' });
  assert.deepEqual(readBatch('{}', 'jt808'), { ok: false, error: 'unknown format jt808' });
});

test('a reading may carry the tracker\'s own event; anything else is dropped (3320)', () => {
  const base = { device: 'SIM-0001', at: 1793545200, lat: 43.7, lng: -79.4 };
  assert.equal(toPoint({ ...base, event: 'harsh_brake' })?.event, 'harsh_brake');
  assert.equal(toPoint({ ...base, event: ' Harsh_Accel ' })?.event, 'harsh_accel');
  assert.equal(toPoint({ ...base, alarm: 'tamper' })?.event, 'tamper');
  assert.equal(toPoint({ ...base, event: 'case_open' })?.event, 'tamper');
  assert.equal(toPoint({ ...base, event: 'drop table' })?.event, null);
  assert.equal(toPoint({ ...base, event: 7 })?.event, null);
});

test('a sender that keeps failing the signature is refused for the rest of the minute, others are not (3320)', () => {
  const t0 = 1_793_545_200_000;
  assert.equal(badSender('203.0.113.9', false, t0), false);
  for (let i = 0; i < BAD_PER_MINUTE - 1; i++) assert.equal(badSender('203.0.113.9', true, t0 + i), false);
  assert.equal(badSender('203.0.113.9', true, t0 + 100), true);
  assert.equal(badSender('203.0.113.9', false, t0 + 200), true);
  assert.equal(badSender('203.0.113.10', false, t0 + 200), false);
  // the next minute starts clean
  assert.equal(badSender('203.0.113.9', false, t0 + 61_000), false);
});

test('an impact, a health warning and the trackers\' own words for events; the detail travels only with an event (3353)', () => {
  assert.equal(eventOf('Impact'), 'impact');
  assert.equal(eventOf('crash'), 'impact');
  assert.equal(eventOf('check engine'), 'health');
  assert.equal(eventOf('hard braking'), 'harsh_brake');
  assert.equal(eventOf('harsh_accel'), 'harsh_accel');
  assert.equal(eventOf('tampering'), 'tamper');
  assert.equal(eventOf('party'), null);
  assert.equal(eventOf(7), null);
  const p = toPoint({ device: 'SIM-0001', at: 1793545200, lat: 43.7, lng: -79.4, event: 'collision', detail: 'Front\nleft  ' + 'x'.repeat(300) })!;
  assert.equal(p.event, 'impact');
  assert.ok(p.detail!.startsWith('Front left') && p.detail!.length <= 200);
  const plain = toPoint({ device: 'SIM-0001', at: 1793545200, lat: 43.7, lng: -79.4, event: 'party', detail: 'ignored' })!;
  assert.equal(plain.event, null);
  assert.ok(!('detail' in plain));
});
