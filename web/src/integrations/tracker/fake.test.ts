import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FAKE_SCENARIOS, fakeScenario } from './fake.ts';
import { readBatch, toPoint } from './ingest.ts';

const END = Date.UTC(2026, 10, 21, 19, 0, 0);

test('every scenario is a batch the ingest reads whole, oldest reading first', () => {
  for (const s of FAKE_SCENARIOS) {
    const pts = fakeScenario('FAKE-0001', s, { end: END });
    const r = readBatch(JSON.stringify({ points: pts }));
    assert.ok(r.ok && r.points.length === pts.length && pts.length >= 2, s);
    const times = pts.map((p) => Date.parse(String(p.at)));
    assert.deepEqual([...times].sort((a, b) => a - b), times, s);
    assert.equal(times.at(-1), END, s);
    // coordinates as a tracker sends them: at most six decimals (the database refuses more than twelve)
    for (const q of pts) assert.ok(/^-?\d+(\.\d{1,6})?$/.test(String(q.lat)) && /^-?\d+(\.\d{1,6})?$/.test(String(q.lng)), s);
  }
});

test('the speeding scenarios pass their limit (and only theirs); the heads-up stays under 180', () => {
  const peak = (s: Parameters<typeof fakeScenario>[1]) => Math.max(...fakeScenario('F-1', s, { end: END }).map((p) => p.speed ?? 0));
  assert.ok(peak('speeding_180') > 180 && peak('speeding_180') <= 220);
  assert.ok(peak('speeding_220') > 220 && peak('speeding_220') <= 300);
  assert.ok(peak('speeding_300') > 300);
  assert.ok(peak('slow_down') > 140 && peak('slow_down') <= 180);
  // three readings in a row over the limit: the database makes one record of them
  assert.equal(fakeScenario('F-1', 'speeding_180', { end: END }).filter((p) => (p.speed ?? 0) > 180).length, 3);
});

test('harsh driving, tampering and unplugged carry what the database reads', () => {
  const harsh = fakeScenario('F-1', 'harsh_driving', { end: END });
  assert.deepEqual(harsh.map((p) => p.event ?? null).filter(Boolean), ['harsh_accel', 'harsh_brake']);
  // 70 km/h lost in 5 seconds between two readings: 14 km/h a second, the default level
  const i = harsh.findIndex((p) => p.speed === 10);
  assert.equal((harsh[i - 1]!.speed! - harsh[i]!.speed!) / ((Date.parse(String(harsh[i]!.at)) - Date.parse(String(harsh[i - 1]!.at))) / 1000), 14);
  assert.ok(fakeScenario('F-1', 'tamper', { end: END }).some((p) => toPoint(p)?.event === 'tamper'));
  assert.ok(fakeScenario('F-1', 'unplugged', { end: END }).some((p) => p.power === false));
});

test('the pound scenario parks at the lot for the minutes asked, ignition off', () => {
  const lot = { lat: 43.75, lng: -79.5 };
  const pts = fakeScenario('F-1', 'pound', { end: END, lot: { lat: 43.7500000004321, lng: -79.4999999995 }, parkedMinutes: 45 });
  const parked = pts.filter((p) => p.lat === lot.lat && p.lng === lot.lng);
  assert.equal(parked.length, 3);
  assert.ok(parked.every((p) => p.speed === 0 && p.ignition === false));
  assert.equal(END - Date.parse(String(parked[0]!.at)), 45 * 60_000);
});
