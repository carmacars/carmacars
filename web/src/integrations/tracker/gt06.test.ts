import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ALARM, LOCATION, LOCATION_2, LOGIN, STATUS, ack, crcItu, decode, frame, split } from './gt06.ts';

const hex = (s: string) => Uint8Array.from(Buffer.from(s.replace(/\s+/g, ''), 'hex'));
const toHex = (b: Uint8Array) => Buffer.from(b).toString('hex').toUpperCase();

test('the login frame of the protocol document: CRC 8CDD, the IMEI, and the reply the device waits for', () => {
  const f = hex('78 78 0D 01 01 23 45 67 89 01 23 45 00 01 8C DD 0D 0A');
  assert.equal(crcItu(f.subarray(2, 14)), 0x8cdd);
  const m = decode(f);
  assert.equal(m.kind, 'login');
  if (m.kind !== 'login') return;
  assert.equal(m.imei, '123456789012345');
  assert.equal(m.serial, 1);
  assert.equal(toHex(m.ack), toHex(ack(LOGIN, 1)));
  assert.equal(toHex(m.ack).slice(0, 12), '787805010001');
});

// the document's example position: 23.111668 N, 114.409285 E, course 143, positioned (built here with a fresh CRC)
const gps = '0B081D112E10 CC 027AC7EB 0C465849 00 148F';
test('a location frame: time, position, course, and north/east from the status bits', () => {
  const m = decode(frame(LOCATION, hex(gps + ' 01CC 00 287D 001FB8'), 3));
  assert.equal(m.kind, 'location');
  if (m.kind !== 'location') return;
  assert.equal(m.fix.at, '2011-08-29T17:46:16.000Z');
  assert.equal(m.fix.lat, 23.111668);
  assert.equal(m.fix.lng, 114.409285);
  assert.equal(m.fix.heading, 143);
  assert.equal(m.fix.positioned, true);
  assert.equal(m.fix.satellites, 12);
  assert.equal(m.ack, null);
});

test('the GT06N location (0x22): ACC on and the mileage; west longitude for Toronto', () => {
  // 43.653200 N, 79.383200 W: degrees x 1,800,000; status 0x1C00 = positioned, west, north; course 0
  const lat = Math.round(43.6532 * 1_800_000).toString(16).padStart(8, '0'), lng = Math.round(79.3832 * 1_800_000).toString(16).padStart(8, '0');
  const m = decode(frame(LOCATION_2, hex(`1A0B010F0000 C9 ${lat} ${lng} 3C 1C5A 0136 01 1234 00ABCD 01 00 01 0001E240`), 9));
  if (m.kind !== 'location') return assert.fail(m.kind);
  assert.equal(m.fix.lat, 43.6532);
  assert.equal(m.fix.lng, -79.3832);
  assert.equal(m.fix.speed, 60);
  assert.equal(m.fix.heading, 90);
  assert.equal(m.fix.ignition, true);
  assert.equal(m.fix.odometer, 123.456);
});

test('status (heartbeat): ignition, power connected, battery level; an alarm carries both', () => {
  const s = decode(frame(STATUS, hex('06 04 04 0002'), 7));
  if (s.kind !== 'status') return assert.fail(s.kind);
  assert.deepEqual(s.status, { armed: false, ignition: true, power: true, battery: 67, gsm: 4 });
  const a = decode(frame(ALARM, hex(gps + ' 09 01CC 00 287D 001FB8 00 06 03 02 0002'), 8));
  if (a.kind !== 'alarm') return assert.fail(a.kind);
  assert.equal(a.status.power, false);
  assert.equal(a.status.battery, 100);
  assert.equal(a.alarm, 2);
});

test('a TCP stream: frames split, junk skipped, half a frame kept for the next read; a bad CRC throws', () => {
  const a = frame(STATUS, hex('06 04 04 0002'), 1), b = hex('78 78 0D 01 01 23 45 67 89 01 23 45 00 01 8C DD 0D 0A');
  const stream = new Uint8Array([0x00, 0x11, ...a, ...b, ...b.subarray(0, 6)]);
  const r = split(stream);
  assert.equal(r.frames.length, 2);
  assert.equal(r.rest.length, 6);
  const bad = b.slice(); bad[15] = 0x00;
  assert.throws(() => decode(bad), /CRC/);
});
