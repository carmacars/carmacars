import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readBatch, sign, signedHeaders, toPoint, verify } from './ingest.ts';

const KEY = 'trk_' + 'a'.repeat(64);
const body = JSON.stringify({ points: [{ device: '860000000000001', at: '2026-11-01T15:00:00Z', lat: 43.65, lng: -79.38, speed: 50 }] });
const get = (h: Record<string, string>) => (n: string) => h[n] ?? null;

test('a signed batch passes; a wrong key, an edited body, an old timestamp or no headers do not', async () => {
  const now = 1_793_545_200;
  const h = await signedHeaders(body, KEY, now);
  assert.match(h['x-tracker-signature']!, /^v1=[0-9a-f]{64}$/);
  assert.deepEqual(await verify(body, get(h), KEY, now), { ok: true });
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
    { device: 'SIM-0001', at: 1793545200, lat: 43.7, lng: -79.4, speed: null, heading: 90, ignition: true, odometer: null, battery: null, power: null, fuel: null });
  assert.equal(toPoint({ device: 'x', at: 1, lat: 1, lng: 1 }), null);
  assert.equal(toPoint({ device: 'SIM-1', at: 1, lat: 0, lng: 0 }), null);
  assert.equal(toPoint({ device: 'SIM-1', lat: 43, lng: -79 }), null);
  const r = readBatch(JSON.stringify({ points: [{ device: 'SIM-1', at: 1, lat: 43, lng: -79 }, { nope: true }] }));
  assert.ok(r.ok && r.points.length === 1 && r.sent === 2);
  assert.deepEqual(readBatch('nope'), { ok: false, error: 'not JSON' });
  assert.deepEqual(readBatch('{}', 'jt808'), { ok: false, error: 'unknown format jt808' });
});
