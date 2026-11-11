// Release 37 (2340): what a bug report carries from the browser, made safe to keep. Pure functions (no DOM), shared by
// the browser's ring buffer (install.ts) and the server, which cleans everything again before it is stored.

export type LogKind = 'error' | 'warn' | 'fetch' | 'crash' | 'rejection';
export type LogEntry = { at: string; kind: LogKind; msg: string; url?: string; status?: number; method?: string; ray?: string };

export const RING_SIZE = 50;
export const MSG_MAX = 300;
export const MIN_HAPPENED = 30;
export const MAX_SHOT_BYTES = 5 * 1024 * 1024;
export const MAX_SHOTS = 6;
export const SEVERITIES = [['blocks_work', 'Blocks my work'], ['annoying', 'Annoying'], ['cosmetic', 'Cosmetic']] as const;
export type Severity = (typeof SEVERITIES)[number][0];

// query keys that never carry a person or a secret; every other one is dropped
const SAFE_KEYS = new Set(['tab', 'view', 'page', 'status', 'sort', 'step', 'section', 'mode']);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** A URL as a path that is safe to keep: same-site paths only, no hash, only harmless query keys, and long tokens in
 *  the path (sign, pay and reset links) replaced. Another site keeps only its host. */
export function stripUrl(raw: string, origin = 'https://carmacars.ca'): string {
  let u: URL;
  try { u = new URL(raw, origin); } catch { return '[bad url]'; }
  const base = new URL(origin);
  if (u.host !== base.host) return `${u.protocol}//${u.host}/…`;
  const path = u.pathname.split('/').map((s) => (s.length >= 20 && !UUID.test(s) && /^[A-Za-z0-9_.~%-]+$/.test(s) ? ':token' : s)).join('/');
  const q = [...u.searchParams.entries()].filter(([k, v]) => SAFE_KEYS.has(k) && v.length <= 40 && /^[\w-]*$/.test(v)).map(([k, v]) => `${k}=${v}`);
  return (path || '/') + (q.length ? `?${q.join('&')}` : '');
}

/** A page path for the report: the path alone (the database refuses a query string). */
export const pagePath = (raw: string, origin?: string) => (stripUrl(raw, origin).split('?')[0] ?? '').slice(0, 500) || '/';

/** Text with personal data and secrets masked, capped. */
export function redact(s: unknown, max = MSG_MAX): string {
  const t = typeof s === 'string' ? s : s instanceof Error ? `${s.name}: ${s.message}` : (() => { try { return JSON.stringify(s) ?? String(s); } catch { return String(s); } })();
  return t
    .replace(/https?:\/\/[^\s"'<>)]+/g, (m) => stripUrl(m, typeof window === 'undefined' ? undefined : window.location.origin))
    .replace(/\beyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]*/g, '[jwt]')
    .replace(/\b(cc_live|sk_live|sk_test|pk_live|rk_live|whsec)_[\w]+/g, '[key]')
    .replace(/\b(bearer|token|password|secret|apikey|api_key|authorization)(["':=\s]+)[^\s"',;&]+/gi, '$1$2[redacted]')
    .replace(/[\w.+-]+@[\w-]+\.[\w.-]+/g, '[email]')
    .replace(/\b[0-9a-f]{32,}\b/gi, '[hash]')
    .replace(/\+?\d[\d ().-]{8,}\d/g, (m) => (m.replace(/\D/g, '').length >= 9 ? '[number]' : m))
    .slice(0, max);
}

/** The last RING_SIZE entries, oldest first. */
export class Ring {
  private items: LogEntry[] = [];
  private size: number;
  constructor(size = RING_SIZE) { this.size = size; }
  push(e: Omit<LogEntry, 'at' | 'msg'> & { msg: unknown; at?: string }) {
    const entry: LogEntry = { at: e.at ?? new Date().toISOString(), kind: e.kind, msg: redact(e.msg) };
    if (e.url) entry.url = stripUrl(e.url, typeof window === 'undefined' ? undefined : window.location.origin).slice(0, 300);
    if (typeof e.status === 'number') entry.status = e.status;
    if (e.method) entry.method = e.method.toUpperCase().slice(0, 8);
    if (e.ray) entry.ray = e.ray.slice(0, 40);
    this.items.push(entry);
    if (this.items.length > this.size) this.items.splice(0, this.items.length - this.size);
  }
  list(): LogEntry[] { return this.items.slice(); }
}

/** Entries from the browser, cleaned again on the server (never trust what arrives). */
export function cleanLogs(v: unknown, origin?: string): LogEntry[] {
  if (!Array.isArray(v)) return [];
  const kinds = new Set<LogKind>(['error', 'warn', 'fetch', 'crash', 'rejection']);
  return v.slice(-RING_SIZE).flatMap((x) => {
    if (!x || typeof x !== 'object') return [];
    const o = x as Record<string, unknown>;
    if (!kinds.has(o.kind as LogKind)) return [];
    const at = typeof o.at === 'string' && !Number.isNaN(Date.parse(o.at)) ? new Date(o.at).toISOString() : new Date().toISOString();
    const e: LogEntry = { at, kind: o.kind as LogKind, msg: redact(String(o.msg ?? '')) };
    if (typeof o.url === 'string') e.url = stripUrl(o.url, origin).slice(0, 300);
    if (typeof o.status === 'number' && Number.isFinite(o.status)) e.status = Math.trunc(o.status);
    if (typeof o.method === 'string') e.method = o.method.toUpperCase().replace(/[^A-Z]/g, '').slice(0, 8);
    if (typeof o.ray === 'string') e.ray = o.ray.replace(/[^\w-]/g, '').slice(0, 40);
    return [e];
  });
}

/** The browser's facts, kept to known keys and short strings. */
export function cleanContext(v: unknown): Record<string, string | number | boolean> {
  const out: Record<string, string | number | boolean> = {};
  if (!v || typeof v !== 'object') return out;
  const keys = ['viewport', 'screen', 'dpr', 'device', 'browser', 'platform', 'language', 'timezone', 'online', 'build', 'schema', 'tab', 'title', 'capture'];
  for (const k of keys) {
    const x = (v as Record<string, unknown>)[k];
    if (typeof x === 'string') out[k] = redact(x, 200);
    else if (typeof x === 'number' && Number.isFinite(x)) out[k] = x;
    else if (typeof x === 'boolean') out[k] = x;
  }
  return out;
}

/** The kind of an image by its first bytes (PNG, JPEG or WebP), or null. */
export function imageKind(b: Uint8Array): { ext: 'png' | 'jpg' | 'webp'; mime: string } | null {
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return { ext: 'png', mime: 'image/png' };
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return { ext: 'jpg', mime: 'image/jpeg' };
  if (b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 && b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) return { ext: 'webp', mime: 'image/webp' };
  return null;
}

/** Whether a form field must never show in a screenshot. */
export function isSensitiveField(f: { type?: string; name?: string; autocomplete?: string; sensitive?: boolean }): boolean {
  if (f.sensitive) return true;
  if ((f.type ?? '').toLowerCase() === 'password') return true;
  if (/^cc-|one-time-code|new-password|current-password/i.test(f.autocomplete ?? '')) return true;
  return /pass|card|cvc|cvv|sin\b|ssn|token|secret|iban|account_?number|routing|transit/i.test(f.name ?? '');
}
