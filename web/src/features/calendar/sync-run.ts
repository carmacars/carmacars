// The calendar sync run (migration 0062): read each calendar link that is due, parse it (ical.ts) and hand the result
// to the database (app.calendar_feed_apply, or app.calendar_feed_failed with the reason in plain words). Used by the
// calendar-sync Edge Function (every link due; the deploy copies this file there as run.ts) and by the site's
// "Sync now" (one link), each with its own Store.
import { IcalError, parseIcal, type IcalEvent } from './ical.ts';

export interface DueFeed { id: string; url: string; platform: string; etag: string | null; last_modified: string | null }
export interface Store {
  due(limit: number): Promise<DueFeed[]>;
  ok(id: string, events: IcalEvent[] | null, meta: Record<string, unknown>): Promise<unknown>;
  failed(id: string, error: string): Promise<unknown>;
}
export type Fetch = (url: string, init: RequestInit) => Promise<Response>;

export const MAX_BYTES = 3_000_000;
export const TIMEOUT_MS = 20_000;
const UA = 'CarmaCars calendar sync (+https://carmacars.ca)';

/** The link a person pasted, ready to read (webcal:// is https://). */
export function normalizeUrl(url: string): string {
  return url.trim().replace(/^webcal:\/\//i, 'https://');
}

/** A host that must never be read from the server (the machine itself or a private network), unless allowed. */
export function privateHost(url: string): boolean {
  let h: string;
  try { h = new URL(url).hostname.toLowerCase().replace(/^\[|\]$/g, ''); } catch { return true; }
  return h === 'localhost' || h.endsWith('.localhost') || h.endsWith('.internal') || h.endsWith('.local') || h === '0.0.0.0' || h === '::1'
    || /^127\./.test(h) || /^10\./.test(h) || /^192\.168\./.test(h) || /^169\.254\./.test(h) || /^172\.(1[6-9]|2\d|3[01])\./.test(h) || /^f[cd][0-9a-f]{2}:/.test(h);
}

/** Why a read failed, in words a Fleet assistant can act on. */
export function httpReason(status: number): string {
  if (status === 401 || status === 403) return `The platform answered ${status} (not allowed): the link may have been reset. Copy it again from the platform.`;
  if (status === 404 || status === 410) return `The platform answered ${status} (not found): the link was removed or reset. Copy it again from the platform.`;
  if (status === 429) return 'The platform answered 429 (too many requests). It will be tried again.';
  if (status >= 500) return `The platform answered ${status} (its own error). It will be tried again.`;
  return `The platform answered ${status}.`;
}

export interface SyncOneResult { id: string; ok: boolean; events?: number; notModified?: boolean; error?: string; warnings?: string[]; result?: unknown }

export async function syncOne(feed: DueFeed, store: Store, fetchFn: Fetch, opts: { now?: Date; allowPrivate?: boolean } = {}): Promise<SyncOneResult> {
  const url = normalizeUrl(feed.url);
  const fail = async (error: string): Promise<SyncOneResult> => { const result = await store.failed(feed.id, error); return { id: feed.id, ok: false, error, result }; };
  if (!/^https?:\/\//i.test(url)) return fail('The link must start with https://.');
  if (!opts.allowPrivate && privateHost(url)) return fail('This address cannot be read from the server.');
  const headers: Record<string, string> = { Accept: 'text/calendar, text/plain;q=0.9, */*;q=0.5', 'User-Agent': UA };
  if (feed.etag) headers['If-None-Match'] = feed.etag;
  if (feed.last_modified) headers['If-Modified-Since'] = feed.last_modified;
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), TIMEOUT_MS);
  let res: Response;
  try {
    res = await fetchFn(url, { headers, redirect: 'follow', signal: ctl.signal });
  } catch (e) {
    clearTimeout(timer);
    return fail(ctl.signal.aborted ? `No answer within ${TIMEOUT_MS / 1000} seconds.` : `The link could not be reached (${e instanceof Error ? e.message.slice(0, 120) : 'network error'}).`);
  }
  try {
    const meta = { etag: res.headers.get('etag'), last_modified: res.headers.get('last-modified') };
    if (res.status === 304) {
      const result = await store.ok(feed.id, null, meta);
      return { id: feed.id, ok: true, notModified: true, result };
    }
    if (!res.ok) return await fail(httpReason(res.status));
    const len = Number(res.headers.get('content-length') ?? 0);
    if (len > MAX_BYTES) return await fail('The calendar is larger than 3 MB.');
    const text = await res.text();
    if (text.length > MAX_BYTES) return await fail('The calendar is larger than 3 MB.');
    let parsed;
    try { parsed = parseIcal(text, { now: opts.now }); } catch (e) {
      return await fail(e instanceof IcalError ? e.message : 'The calendar could not be read.');
    }
    const result = await store.ok(feed.id, parsed.events, { ...meta, calendar_name: parsed.calendar_name, warnings: parsed.warnings.slice(0, 5) });
    return { id: feed.id, ok: true, events: parsed.events.length, warnings: parsed.warnings, result };
  } finally {
    clearTimeout(timer);
  }
}

/** Every link that is due, a few at a time. */
export async function syncDue(store: Store, fetchFn: Fetch, opts: { limit?: number; parallel?: number; now?: Date } = {}) {
  const due = await store.due(opts.limit ?? 50);
  const out: SyncOneResult[] = [];
  const parallel = Math.max(1, opts.parallel ?? 4);
  for (let i = 0; i < due.length; i += parallel) {
    const batch = due.slice(i, i + parallel);
    out.push(...(await Promise.all(batch.map((f) => syncOne(f, store, fetchFn, { now: opts.now }).catch((e) => ({ id: f.id, ok: false, error: e instanceof Error ? e.message : 'failed' }))))));
  }
  return { feeds: due.length, ok: out.filter((r) => r.ok).length, failed: out.filter((r) => !r.ok).length, results: out.map(({ id, ok, events, notModified, error }) => ({ id, ok, events, notModified, error })) };
}
