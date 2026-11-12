// Release 42: what the Worker entry took from Cloudflare's request data and bindings, for the Node entry
// (scripts/vps-server.mjs; docs/hosting/off-cloudflare.md section 2.6):
//   - where the visitor is, from the headers Cloudflare's free proxy adds in front of the server (CF-IPCountry, and with
//     the free managed transform "Add visitor location headers": cf-region-code, cf-ipcity, cf-iplatitude,
//     cf-iplongitude). Caddy removes these headers from any request that did not come from Cloudflare's network
//     (infra/vps/web/site.caddy), so a visitor can never set them;
//   - Bytespider's pacing (the Worker's rate limiting binding: 60 pages a minute), as a counter in memory;
//   - the last good copy of the public pages, kept on the server's disk (KeptCopies).
// The disk part imports node:fs lazily, so the app can import the geo helpers.

type Get = (name: string) => string | null | undefined;

export interface VisitorGeo { country: string | null; region: string | null; city: string | null; lat: number | null; lon: number | null }

const num = (v: string | null | undefined, max: number): number | null => {
  const n = Number(v);
  return v != null && v !== '' && Number.isFinite(n) && Math.abs(n) <= max ? Math.round(n * 100) / 100 : null;
};

/** The visitor's approximate place from Cloudflare's headers (position rounded to 0.01 degree, about 1 km, as the Worker
 *  rounds it); every field null when the request did not come through Cloudflare. */
export function geoFromHeaders(get: Get): VisitorGeo {
  const c = (get('cf-ipcountry') ?? '').toUpperCase();
  const country = /^[A-Z]{2}$/.test(c) && c !== 'XX' && c !== 'T1' ? c : null;
  if (!country) return { country: null, region: null, city: null, lat: null, lon: null };
  const r = (get('cf-region-code') ?? '').toUpperCase();
  let city = (get('cf-ipcity') ?? '').trim().slice(0, 80);
  // Cloudflare sends the city as UTF-8 bytes in a header (Montréal): Node reads header bytes as Latin-1
  if (/[\u0080-ÿ]/.test(city)) { try { city = new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(city, (ch) => ch.charCodeAt(0))); } catch { /* already text */ } }
  return { country, region: /^[A-Z0-9]{1,3}$/.test(r) ? r : null, city: city || null, lat: num(get('cf-iplatitude'), 90), lon: num(get('cf-iplongitude'), 180) };
}

/** Country and region as the cookie notice reads them (CA-ON, or CA when the region is unknown); null when unknown. */
export function geoCode(g: Pick<VisitorGeo, 'country' | 'region'>): string | null {
  return g.country ? (g.region ? `${g.country}-${g.region}` : g.country) : null;
}

/** The cc_geo cookie to set on an HTML response (a day), or null when unknown or the browser already has this value. */
export function geoCookie(g: Pick<VisitorGeo, 'country' | 'region'>, cookieHeader: string | null | undefined, secure: boolean): string | null {
  const code = geoCode(g);
  if (!code || new RegExp(`(^|;\\s*)cc_geo=${code}(;|$)`).test(cookieHeader ?? '')) return null;
  return `cc_geo=${code}; Path=/; Max-Age=86400; SameSite=Lax${secure ? '; Secure' : ''}`;
}

/** At most `limit` in each `periodMs` for a key (the Worker's rate limiting binding, for the one server). */
export class WindowLimiter {
  private readonly seen = new Map<string, { start: number; n: number }>();
  private readonly limit: number;
  private readonly periodMs: number;
  constructor(limit: number, periodMs: number) { this.limit = limit; this.periodMs = periodMs; }
  /** True when this request is within the limit (and counts it). */
  take(key: string, now: number): boolean {
    const w = this.seen.get(key);
    if (!w || now - w.start >= this.periodMs) { this.seen.set(key, { start: now, n: 1 }); return true; }
    w.n++;
    return w.n <= this.limit;
  }
}

// ------------------------------------------------------------------ last good copies on disk
export const COPY_MAX_AGE_MS = 7 * 86_400_000;
/** A copy this fresh is not written again (a busy page is not rewritten on every request). */
export const COPY_REFRESH_MS = 10 * 60_000;
export const COPY_MAX_FILES = 20_000;

export interface KeptCopy { body: Buffer; storedAt: number }
export interface KeptCopies {
  /** The page's last good copy (HTML as the app sent it), or null: none, or older than a week. */
  get(key: string, now?: number): Promise<KeptCopy | null>;
  /** Keeps the page when it has no copy or its copy is older than COPY_REFRESH_MS. Never throws. */
  put(key: string, body: Buffer, now?: number): Promise<void>;
  /** Removes copies older than a week, then the oldest above COPY_MAX_FILES; the number removed. */
  prune(now?: number): Promise<number>;
}

/** Last good copies as gzip files in one folder (a Docker volume on the server: they outlive a deploy). */
export async function keptCopies(dir: string, o: { maxFiles?: number; maxAgeMs?: number; refreshMs?: number } = {}): Promise<KeptCopies> {
  const [fs, path, zlib, { createHash }, { promisify }] = await Promise.all([import('node:fs/promises'), import('node:path'), import('node:zlib'), import('node:crypto'), import('node:util')]);
  const gzip = promisify(zlib.gzip), gunzip = promisify(zlib.gunzip);
  const maxFiles = o.maxFiles ?? COPY_MAX_FILES, maxAge = o.maxAgeMs ?? COPY_MAX_AGE_MS, refresh = o.refreshMs ?? COPY_REFRESH_MS;
  await fs.mkdir(dir, { recursive: true });
  const file = (key: string) => path.join(dir, `${createHash('sha256').update(key).digest('hex').slice(0, 40)}.html.gz`);
  return {
    async get(key, now = Date.now()) {
      try {
        const f = file(key);
        const st = await fs.stat(f);
        if (now - st.mtimeMs > maxAge) return null;
        return { body: await gunzip(await fs.readFile(f)), storedAt: st.mtimeMs };
      } catch { return null; }
    },
    async put(key, body, now = Date.now()) {
      try {
        const f = file(key);
        const st = await fs.stat(f).catch(() => null);
        if (st && now - st.mtimeMs < refresh) return;
        const tmp = `${f}.${process.pid}.tmp`;
        await fs.writeFile(tmp, await gzip(body));
        await fs.utimes(tmp, new Date(now), new Date(now));
        await fs.rename(tmp, f);
      } catch { /* a full disk never fails a page */ }
    },
    async prune(now = Date.now()) {
      let removed = 0;
      try {
        const rows: Array<{ f: string; m: number }> = [];
        for (const name of await fs.readdir(dir)) {
          const f = path.join(dir, name);
          const st = await fs.stat(f).catch(() => null);
          if (!st || !st.isFile()) continue;
          if (now - st.mtimeMs > maxAge || name.endsWith('.tmp')) { await fs.rm(f, { force: true }); removed++; } else rows.push({ f, m: st.mtimeMs });
        }
        rows.sort((a, b) => b.m - a.m);
        for (const r of rows.slice(maxFiles)) { await fs.rm(r.f, { force: true }); removed++; }
      } catch { /* next hour */ }
      return removed;
    }
  };
}
