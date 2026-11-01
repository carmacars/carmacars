// GT06 (Concox and its many Chinese clones), the binary TCP protocol most low-cost car trackers speak (migration 0400).
// The relay on the server (infra/vps/tracker-relay) reads frames with this, answers the device and posts the positions to
// /api/tracker/ingest in the generic JSON (ingest.ts). No imports: unit tested in Node (gt06.test.ts).
//
// Written from the public GT06 protocol document (V1.8): CarmaCars' own tracker's document is not in hand yet, so check
// these against it before the first device: the frame start (0x7878 short, 0x7979 long), the protocol numbers below, the
// time zone of the device clock (UTC expected), and whether ACC and the battery come in the location or the status frame.
//
// Frame: start (2) | length (1, or 2 for 0x7979) | protocol (1) | content | serial (2) | CRC-ITU (2) | 0x0D 0x0A.
// The CRC (CRC-16/X-25) covers length to serial.

export const LOGIN = 0x01, LOCATION = 0x12, STATUS = 0x13, STRING = 0x15, ALARM = 0x16, LOCATION_2 = 0x22, ALARM_2 = 0x26;

export interface Gt06Fix { at: string; lat: number; lng: number; speed: number; heading: number; positioned: boolean; satellites: number; ignition?: boolean | null; odometer?: number | null }
export interface Gt06Status { ignition: boolean; power: boolean; battery: number | null; armed: boolean; gsm: number | null }
export type Gt06Message =
  | { kind: 'login'; serial: number; imei: string; ack: Uint8Array }
  | { kind: 'location'; serial: number; protocol: number; fix: Gt06Fix; ack: Uint8Array | null }
  | { kind: 'status'; serial: number; status: Gt06Status; ack: Uint8Array }
  | { kind: 'alarm'; serial: number; fix: Gt06Fix; status: Gt06Status; alarm: number; ack: Uint8Array }
  | { kind: 'other'; serial: number; protocol: number; ack: Uint8Array | null };

/** CRC-16/X-25 (the protocol's CRC-ITU). */
export function crcItu(b: Uint8Array): number {
  let c = 0xffff;
  for (const x of b) { c ^= x; for (let i = 0; i < 8; i++) c = c & 1 ? (c >>> 1) ^ 0x8408 : c >>> 1; }
  return (c ^ 0xffff) & 0xffff;
}

/** The reply the device waits for (login, status, alarm): the same protocol number and serial. */
export function ack(protocol: number, serial: number): Uint8Array {
  const body = new Uint8Array([0x05, protocol, (serial >> 8) & 0xff, serial & 0xff]);
  const c = crcItu(body);
  return new Uint8Array([0x78, 0x78, ...body, (c >> 8) & 0xff, c & 0xff, 0x0d, 0x0a]);
}

/** A frame (the tests and the simulator build frames with it). */
export function frame(protocol: number, content: Uint8Array, serial: number): Uint8Array {
  const body = new Uint8Array([content.length + 5, protocol, ...content, (serial >> 8) & 0xff, serial & 0xff]);
  const c = crcItu(body);
  return new Uint8Array([0x78, 0x78, ...body, (c >> 8) & 0xff, c & 0xff, 0x0d, 0x0a]);
}

const u16 = (b: Uint8Array, i: number) => (b[i]! << 8) | b[i + 1]!;
const u32 = (b: Uint8Array, i: number) => ((b[i]! << 24) >>> 0) + (b[i + 1]! << 16) + (b[i + 2]! << 8) + b[i + 3]!;

/** The 8-byte BCD terminal ID: the IMEI (15 digits, the leading 0 dropped). */
export function imeiOf(b: Uint8Array): string {
  return [...b].map((x) => x.toString(16).padStart(2, '0')).join('').replace(/^0/, '');
}

/** Date and time (6 bytes, YY MM DD hh mm ss, the device clock in UTC), the GPS block and the course/status word. */
function fixAt(c: Uint8Array, i: number): Gt06Fix {
  const at = new Date(Date.UTC(2000 + c[i]!, c[i + 1]! - 1, c[i + 2]!, c[i + 3]!, c[i + 4]!, c[i + 5]!)).toISOString();
  const satellites = c[i + 6]! & 0x0f;
  let lat = u32(c, i + 7) / 1_800_000, lng = u32(c, i + 11) / 1_800_000;
  const speed = c[i + 15]!, cs = u16(c, i + 16);
  // course/status: bit 12 positioned, bit 11 west longitude, bit 10 north latitude, bits 0-9 the course
  if (!(cs & 0x0400)) lat = -lat;
  if (cs & 0x0800) lng = -lng;
  return { at, lat: Math.round(lat * 1e6) / 1e6, lng: Math.round(lng * 1e6) / 1e6, speed, heading: cs & 0x03ff, positioned: !!(cs & 0x1000), satellites };
}

/** Terminal information (1 byte), voltage level (0 to 6) and GSM signal (0 to 4). */
function statusOf(info: number, voltage: number | undefined, gsm: number | undefined): Gt06Status {
  return { armed: !!(info & 0x01), ignition: !!(info & 0x02), power: !!(info & 0x04), battery: voltage === undefined ? null : Math.round((Math.min(voltage, 6) / 6) * 100), gsm: gsm ?? null };
}

/** Decodes one frame (start to 0x0D 0x0A). Throws on a bad frame or CRC. */
export function decode(f: Uint8Array): Gt06Message {
  const long = f[0] === 0x79 && f[1] === 0x79;
  if (!long && !(f[0] === 0x78 && f[1] === 0x78)) throw new Error('not a GT06 frame');
  const lenAt = 2, len = long ? u16(f, 2) : f[2]!, start = long ? 4 : 3;
  const end = start + len; // index of the stop bytes
  if (f.length < end + 2 || f[end] !== 0x0d || f[end + 1] !== 0x0a) throw new Error('bad frame length');
  const crc = u16(f, end - 2);
  if (crcItu(f.subarray(lenAt, end - 2)) !== crc) throw new Error('bad CRC');
  const protocol = f[start]!, serial = u16(f, end - 4), c = f.subarray(start + 1, end - 4);
  switch (protocol) {
    case LOGIN: return { kind: 'login', serial, imei: imeiOf(c.subarray(0, 8)), ack: ack(protocol, serial) };
    case LOCATION: return { kind: 'location', serial, protocol, fix: fixAt(c, 0), ack: null };
    case LOCATION_2: {
      // GT06N and later: after the cell (MCC 2, MNC 1, LAC 2, cell 3) come ACC, the upload mode, real-time, then the mileage (4, metres) when present
      const fix = fixAt(c, 0), acc = c[26];
      return { kind: 'location', serial, protocol, fix: { ...fix, ignition: acc === undefined ? null : acc === 1, odometer: c.length >= 33 ? u32(c, 29) / 1000 : null }, ack: null };
    }
    case STATUS: return { kind: 'status', serial, status: statusOf(c[0]!, c[1], c[2]), ack: ack(protocol, serial) };
    case ALARM: case ALARM_2: {
      // GPS (18) then the LBS block (its length byte counts itself), then terminal info, voltage, GSM and the alarm
      const fix = fixAt(c, 0), lbs = c[18]!, s = 18 + lbs;
      return { kind: 'alarm', serial, fix, status: statusOf(c[s]!, c[s + 1], c[s + 2]), alarm: c[s + 3] ?? 0, ack: ack(protocol, serial) };
    }
    default: return { kind: 'other', serial, protocol, ack: protocol === STRING ? null : ack(protocol, serial) };
  }
}

/** Splits a TCP stream into frames: the frames found and what is left over for the next read. Junk before a start is dropped. */
export function split(buf: Uint8Array): { frames: Uint8Array[]; rest: Uint8Array } {
  const frames: Uint8Array[] = [];
  let i = 0;
  while (i + 5 <= buf.length) {
    const short = buf[i] === 0x78 && buf[i + 1] === 0x78, long = buf[i] === 0x79 && buf[i + 1] === 0x79;
    if (!short && !long) { i++; continue; }
    const total = short ? buf[i + 2]! + 5 : (buf.length >= i + 4 ? u16(buf, i + 2) : 0) + 6;
    if (long && buf.length < i + 4) break;
    if (buf.length < i + total) break;
    frames.push(buf.slice(i, i + total));
    i += total;
  }
  return { frames, rest: buf.slice(i) };
}
