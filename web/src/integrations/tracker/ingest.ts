// The tracker ingest (migration 0400): how a batch of positions reaches /api/tracker/ingest, and the adapters that turn a
// tracker's own format into it. No imports: it runs in the Worker, in Node (the simulator and the relay) and in the unit
// tests (ingest.test.ts).
//
// The wire format is CarmaCars' own generic JSON (docs/tracker-ingest.md):
//   POST /api/tracker/ingest
//   x-tracker-timestamp: <Unix seconds>
//   x-tracker-signature: v1=<hex HMAC-SHA256 of "<timestamp>.<raw body>" with the ingest key>
//   {"points": [{"device": "<IMEI or serial>", "at": "<ISO 8601 with offset, or Unix seconds>", "lat": 43.65, "lng": -79.38,
//                "speed": 54, "heading": 270, "ignition": true, "odometer": 12345.6, "battery": 87, "power": true, "fuel": 55}]}
// Only device, at, lat and lng are required; a field left out keeps its last value. The key comes from Admin > Cars > Fleet
// tracking > Settings (shown once); it is checked here, before the database is touched, and refused after 5 minutes.
//
// Adapters: the endpoint stays generic. A tracker that speaks GT06 or JT808 (binary TCP) reports to the small relay on the
// server (infra/vps/tracker-relay), which answers the device, decodes each frame (gt06.ts) and posts signed batches here.
// A vendor's HTTP push in its own JSON gets an adapter below (`adapters`) that maps its fields to a Point.

export const TOLERANCE_SECONDS = 300;
export const MAX_BODY_BYTES = 512_000;
export const MAX_POINTS = 5000;

export interface Point {
  device: string; at: string | number; lat: number; lng: number;
  speed?: number | null; heading?: number | null; ignition?: boolean | null; odometer?: number | null; battery?: number | null; power?: boolean | null; fuel?: number | null;
}
export interface Batch { points: Point[] }

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, '0')).join('');
function same(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

/** The hex HMAC-SHA256 of "<timestamp>.<raw body>". */
export async function sign(raw: string, key: string, ts: number): Promise<string> {
  const k = await crypto.subtle.importKey('raw', enc.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return hex(await crypto.subtle.sign('HMAC', k, enc.encode(`${ts}.${raw}`)));
}

/** The two headers a sender adds (the simulator, the relay and the tests). */
export async function signedHeaders(raw: string, key: string, ts = Math.floor(Date.now() / 1000)): Promise<Record<string, string>> {
  return { 'content-type': 'application/json', 'x-tracker-timestamp': String(ts), 'x-tracker-signature': `v1=${await sign(raw, key, ts)}` };
}

export type HeaderGet = (name: string) => string | null | undefined;
export interface Verified { ok: boolean; reason?: 'no key' | 'no signature' | 'timestamp' | 'signature' }

/** Checks a delivery. Fails closed: no key, no headers, a timestamp more than 5 minutes off or a wrong signature. */
export async function verify(raw: string, header: HeaderGet, key: string | null | undefined, nowSeconds = Math.floor(Date.now() / 1000)): Promise<Verified> {
  if (!key) return { ok: false, reason: 'no key' };
  const ts = header('x-tracker-timestamp'), sig = header('x-tracker-signature');
  if (!ts || !sig) return { ok: false, reason: 'no signature' };
  if (!/^\d{9,11}$/.test(ts) || Math.abs(nowSeconds - Number(ts)) > TOLERANCE_SECONDS) return { ok: false, reason: 'timestamp' };
  const want = await sign(raw, key, Number(ts));
  const given = sig.split(',').map((s) => s.trim()).filter((s) => s.startsWith('v1=')).map((s) => s.slice(3).toLowerCase());
  return given.some((g) => same(g, want)) ? { ok: true } : { ok: false, reason: 'signature' };
}

const num = (v: unknown): number | null => {
  const n = typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN;
  return Number.isFinite(n) ? n : null;
};
const bool = (v: unknown): boolean | null => (typeof v === 'boolean' ? v : v === 1 || v === '1' || v === 'on' || v === 'true' ? true : v === 0 || v === '0' || v === 'off' || v === 'false' ? false : null);

/** One point in the generic shape, or null when it is not usable (the database checks every field again). */
export function toPoint(x: unknown): Point | null {
  if (!x || typeof x !== 'object') return null;
  const o = x as Record<string, unknown>;
  const device = typeof o.device === 'string' ? o.device.trim() : typeof o.device === 'number' ? String(o.device) : '';
  const lat = num(o.lat ?? o.latitude), lng = num(o.lng ?? o.lon ?? o.longitude);
  const at = typeof o.at === 'string' || typeof o.at === 'number' ? o.at : typeof o.time === 'string' || typeof o.time === 'number' ? o.time : null;
  if (!/^[A-Za-z0-9._:-]{3,64}$/.test(device) || lat === null || lng === null || at === null || Math.abs(lat) > 90 || Math.abs(lng) > 180 || (lat === 0 && lng === 0)) return null;
  return { device, at, lat, lng, speed: num(o.speed), heading: num(o.heading ?? o.course), ignition: bool(o.ignition ?? o.acc), odometer: num(o.odometer),
    battery: num(o.battery), power: bool(o.power), fuel: num(o.fuel) };
}

export interface Adapter { readonly name: string; parse(body: unknown): Point[] }
/** The adapters by name (the request's ?format=, generic when absent). */
export const adapters: Record<string, Adapter> = {
  generic: {
    name: 'generic',
    parse(body) {
      const list = Array.isArray(body) ? body : body && typeof body === 'object' && Array.isArray((body as Batch).points) ? (body as Batch).points : [];
      return list.map(toPoint).filter((p): p is Point => !!p);
    }
  }
};

/** Reads a verified body: the points to store, how many were sent and how many were left out here. */
export function readBatch(raw: string, format = 'generic'): { ok: true; points: Point[]; sent: number } | { ok: false; error: string } {
  const a = adapters[format];
  if (!a) return { ok: false, error: `unknown format ${format}` };
  let body: unknown;
  try { body = JSON.parse(raw); } catch { return { ok: false, error: 'not JSON' }; }
  const sent = Array.isArray(body) ? body.length : Array.isArray((body as Batch | null)?.points) ? (body as Batch).points.length : 0;
  if (sent > MAX_POINTS) return { ok: false, error: `at most ${MAX_POINTS} points a batch` };
  return { ok: true, points: a.parse(body), sent };
}
