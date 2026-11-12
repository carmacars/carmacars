// The site's own Search Console sync (release 42, migration 2640; docs/changes/2026-11-12-r42-search-console.md).
// Once a day the job (src/server/gsc/google.ts, /api/jobs/gsc) reads Search Analytics for the last 28 days by page and
// by page and query, submits the sitemap, inspects a few written pages Google shows nowhere, and names the pages the
// writer should write again: a page ranking just under the first results, or shown a lot and clicked little.
// Pure: fetch, the database calls and the clock are passed in, so it runs in the Worker, in Node and in the unit test.
import { coverageBucket } from './coverage.ts';

type Fetch = typeof fetch;
const API = 'https://www.googleapis.com/webmasters/v3';
const INSPECT = 'https://searchconsole.googleapis.com/v1/urlInspection/index:inspect';
export const GSC_SCOPE = 'https://www.googleapis.com/auth/webmasters';

/** The selection rule (the owner's): average position 8 to 20, or at least 50 impressions with a click rate under 1%. */
export const RULE = { minPosition: 8, maxPosition: 20, minImpressions: 50, maxCtr: 0.01, topQueries: 8 } as const;

export interface GscRow { keys: string[]; clicks: number; impressions: number; ctr: number; position: number }
export interface PageStat { path: string; clicks: number; impressions: number; ctr: number; position: number }
export interface PageQuery extends PageStat { query: string }
export interface QueryStat { query: string; clicks: number; impressions: number; position: number }
export interface Candidate { path: string; reason: 'position' | 'low_ctr'; clicks: number; impressions: number; ctr: number; position: number; queries: QueryStat[] }
export interface Inspected { path: string; state: string; bucket: string; sitemap: string | null; last_crawl: string | null }

const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : 0);

/** Search Analytics' answer as rows: anything that is not a row with its keys is left out, figures are never negative. */
export function parseAnalytics(json: unknown, dimensions: number): GscRow[] {
  const rows = (json as { rows?: unknown } | null)?.rows;
  if (!Array.isArray(rows)) return [];
  const out: GscRow[] = [];
  for (const r of rows as Array<Record<string, unknown>>) {
    const keys = Array.isArray(r?.keys) ? (r.keys as unknown[]).map((k) => (typeof k === 'string' ? k : '')) : [];
    if (keys.length !== dimensions || keys.some((k) => !k)) continue;
    const clicks = Math.round(num(r.clicks)), impressions = Math.round(num(r.impressions));
    out.push({ keys, clicks, impressions, ctr: impressions > 0 ? Math.min(1, num(r.ctr) || clicks / impressions) : 0, position: num(r.position) });
  }
  return out;
}

/** The site's path of a page address Search Console reports; null for another host or an address with a query. */
export function pathOf(url: string, host: string): string | null {
  try {
    const u = new URL(url);
    const bare = (h: string) => h.toLowerCase().replace(/^www\./, '');
    if (bare(u.hostname) !== bare(host) || u.search || u.hash) return null;
    const p = u.pathname.length > 1 ? u.pathname.replace(/\/+$/, '') : '/';
    return p.length <= 500 && /^\/[^\s]*$/.test(p) ? p : null;
  } catch { return null; }
}

/** A search as the writer may read it: lower case, letters, digits and plain punctuation only, at most 80 characters.
 *  A search is typed by anyone, so nothing else of it reaches the prompt. */
export function cleanQuery(q: string): string {
  return q.toLowerCase().normalize('NFKC').replace(/[^\p{L}\p{N} '&.+-]/gu, ' ').replace(/\s+/g, ' ').trim().slice(0, 80);
}

/** The property to read: the domain property when the account has it, else the https one; null when it has neither. */
export function pickProperty(json: unknown, host: string): string | null {
  const bare = host.toLowerCase().replace(/^www\./, '');
  const sites = ((json as { siteEntry?: Array<{ siteUrl?: string; permissionLevel?: string }> } | null)?.siteEntry ?? [])
    .filter((s) => typeof s?.siteUrl === 'string' && s.permissionLevel !== 'siteUnverifiedUser').map((s) => s.siteUrl as string);
  return [`sc-domain:${bare}`, `https://${bare}/`, `https://www.${bare}/`].find((want) => sites.includes(want)) ?? null;
}

/** Why a page is written again, or null: the rule above. Position first (a page close to the first results). */
export function rewriteReason(p: { impressions: number; ctr: number; position: number }): Candidate['reason'] | null {
  if (p.impressions > 0 && p.position >= RULE.minPosition && p.position <= RULE.maxPosition) return 'position';
  if (p.impressions >= RULE.minImpressions && p.ctr < RULE.maxCtr) return 'low_ctr';
  return null;
}

/** The pages to write again, the most shown first, each with its best searches (by impressions) for the writer. Only
 *  the pages the writer writes are named (`writable`: landing pages and guides); the database applies the day's limit. */
export function rewriteCandidates(pages: PageStat[], rows: PageQuery[], o: { writable?: (path: string) => boolean; max?: number } = {}): Candidate[] {
  const writable = o.writable ?? isWritten;
  const by = new Map<string, PageQuery[]>();
  for (const r of rows) { const l = by.get(r.path); if (l) l.push(r); else by.set(r.path, [r]); }
  const out: Candidate[] = [];
  for (const p of [...pages].sort((a, b) => b.impressions - a.impressions || a.path.localeCompare(b.path))) {
    const reason = writable(p.path) ? rewriteReason(p) : null;
    if (!reason) continue;
    const seen = new Set<string>();
    const queries: QueryStat[] = [];
    for (const q of (by.get(p.path) ?? []).sort((a, b) => b.impressions - a.impressions || b.clicks - a.clicks)) {
      const query = cleanQuery(q.query);
      if (query.length < 3 || seen.has(query)) continue;
      seen.add(query);
      queries.push({ query, clicks: q.clicks, impressions: q.impressions, position: Math.round(q.position * 10) / 10 });
      if (queries.length >= RULE.topQueries) break;
    }
    out.push({ path: p.path, reason, clicks: p.clicks, impressions: p.impressions, ctr: p.ctr, position: Math.round(p.position * 10) / 10, queries });
    if (out.length >= (o.max ?? 50)) break;
  }
  return out;
}

/** The pages the site's writer writes: a landing page or a guide. */
export const isWritten = (path: string) => /^\/(car-rental|guides)\/[a-z0-9]+(-[a-z0-9]+)*$/.test(path);

/** One URL Inspection answer as a row of app.gsc_url_inspection. */
export function inspectionRow(path: string, json: unknown): Inspected {
  const st = ((json as { inspectionResult?: { indexStatusResult?: Record<string, unknown> } } | null)?.inspectionResult?.indexStatusResult ?? {}) as
    { coverageState?: string; verdict?: string; sitemap?: string[]; lastCrawlTime?: string };
  const state = typeof st.coverageState === 'string' && st.coverageState ? st.coverageState : 'Unknown';
  let sitemap: string | null = null;
  try { const m = Array.isArray(st.sitemap) ? st.sitemap[0] : null; sitemap = m ? new URL(m).pathname.slice(1) : null; } catch { sitemap = null; }
  return { path, state, bucket: coverageBucket(state, st.verdict ?? null), sitemap, last_crawl: typeof st.lastCrawlTime === 'string' ? st.lastCrawlTime : null };
}

/** The 28 days Search Console has settled figures for: they end three days ago. */
export function windowOf(now: number): { start: string; end: string } {
  const day = (d: number) => new Date(now - d * 86_400_000).toISOString().slice(0, 10);
  return { start: day(30), end: day(3) };
}

export interface Begin { due: boolean; connected?: boolean; refresh_token?: string | null; property?: string | null; inspect_max?: number; rewrite_on?: boolean; pages?: string[] }
export interface GscDeps {
  begin(): Promise<Begin>;
  finish(p: Record<string, unknown>): Promise<unknown>;
  /** A fresh access token from the refresh token; throws with `reconnect` when Google no longer accepts the connection. */
  token(refresh: string): Promise<string>;
  fetch: Fetch;
  /** The site's address (https://carmacars.ca). */
  base: string;
  now?(): number;
  /** The most inspections this run may make (the runtime's room for outgoing requests), under the database's daily cap. */
  inspectRoom?: number;
  deadlineMs?: number;
}
// (no parameter property: the unit test runs this file with Node's type stripping)
export class GscError extends Error {
  readonly reconnect: boolean;
  constructor(message: string, reconnect = false) { super(message); this.reconnect = reconnect; }
}
export interface GscSummary { status: 'not_due' | 'synced' | 'error'; property?: string; pages?: number; rows?: number; candidates?: number; inspected?: number; sitemap?: boolean; error?: string; warnings?: string[] }

async function call<T>(f: Fetch, url: string, token: string, init: { method?: string; body?: unknown } = {}): Promise<T> {
  const r = await f(url, { method: init.method ?? (init.body ? 'POST' : 'GET'), headers: { authorization: `Bearer ${token}`, ...(init.body ? { 'content-type': 'application/json' } : {}) },
    body: init.body ? JSON.stringify(init.body) : undefined, signal: AbortSignal.timeout(30_000) });
  const text = await r.text().catch(() => '');
  let d: unknown = null;
  try { d = text ? JSON.parse(text) : null; } catch { d = null; }
  if (!r.ok) {
    const msg = (d as { error?: { message?: string } } | null)?.error?.message ?? `HTTP ${r.status}`;
    throw new GscError(`${r.status} ${msg}`.slice(0, 300), r.status === 401);
  }
  return d as T;
}

/** One run. Nothing happens unless the database says the day's sync is due (connected, on, not done today). The search
 *  figures decide: without them the run is an error and is tried again in an hour; the sitemap and the inspections are
 *  extras whose failure is only noted. No token is ever logged or returned. */
export async function runGscSync(d: GscDeps): Promise<GscSummary> {
  const b = await d.begin();
  if (!b?.due) return { status: 'not_due' };
  const now = d.now ?? (() => Date.now());
  const t0 = now();
  const warnings: string[] = [];
  try {
    if (!b.refresh_token) throw new GscError('The connection has no token: connect Google Search Console again', true);
    const token = await d.token(b.refresh_token);
    const host = new URL(d.base).hostname;
    const property = pickProperty(await call(d.fetch, `${API}/sites`, token), host);
    if (!property) throw new GscError(`This Google account has no Search Console property for ${host.replace(/^www\./, '')}: connect with the account that owns it`);
    const site = encodeURIComponent(property);
    const w = windowOf(now());
    const query = (dimensions: string[], rowLimit: number) => call<unknown>(d.fetch, `${API}/sites/${site}/searchAnalytics/query`, token,
      { body: { startDate: w.start, endDate: w.end, dimensions, rowLimit, dataState: 'final' } });
    const [totalsJson, pagesJson, rowsJson] = await Promise.all([query([], 1), query(['page'], 5000), query(['page', 'query'], 10000)]);
    const total = parseAnalytics(totalsJson, 0)[0] ?? { clicks: 0, impressions: 0, ctr: 0, position: 0 };
    const pageMap = new Map<string, PageStat>();
    for (const r of parseAnalytics(pagesJson, 1)) {
      const path = pathOf(r.keys[0]!, host);
      if (path && !pageMap.has(path)) pageMap.set(path, { path, clicks: r.clicks, impressions: r.impressions, ctr: r.ctr, position: r.position });
    }
    const pages = [...pageMap.values()];
    const seen = new Set<string>();
    const rows: PageQuery[] = [];
    for (const r of parseAnalytics(rowsJson, 2)) {
      const path = pathOf(r.keys[0]!, host), q = r.keys[1]!.slice(0, 300);
      if (!path || seen.has(`${path}\n${q}`)) continue;
      seen.add(`${path}\n${q}`);
      rows.push({ path, query: q, clicks: r.clicks, impressions: r.impressions, ctr: r.ctr, position: r.position });
    }

    // the sitemap, once a day: Google reads the root index and everything it lists
    const sitemap = `${d.base.replace(/\/$/, '')}/sitemap.xml`;
    let sitemapOk = false, sitemapError: string | null = null;
    try { await call(d.fetch, `${API}/sites/${site}/sitemaps/${encodeURIComponent(sitemap)}`, token, { method: 'PUT' }); sitemapOk = true; }
    catch (e) { sitemapError = e instanceof Error ? e.message : 'failed'; warnings.push(`sitemap: ${sitemapError}`); }

    // the written pages Google shows nowhere: a few inspected a day, the least recently inspected first (the database's order)
    const shown = new Set(pages.filter((p) => p.impressions > 0).map((p) => p.path));
    const room = Math.max(0, Math.min(b.inspect_max ?? 0, d.inspectRoom ?? 50));
    const todo = (b.pages ?? []).filter((p) => !shown.has(p)).slice(0, room);
    const inspected: Inspected[] = [];
    const deadline = d.deadlineMs ?? 40_000;
    let stop = false;
    const worker = async () => {
      for (;;) {
        const path = todo.shift();
        if (!path || stop || now() - t0 > deadline) return;
        try {
          inspected.push(inspectionRow(path, await call(d.fetch, INSPECT, token, { body: { inspectionUrl: `${d.base.replace(/\/$/, '')}${path === '/' ? '/' : path}`, siteUrl: property } })));
        } catch (e) {
          // the day's quota or a refusal: the rest waits for tomorrow
          stop = true;
          warnings.push(`inspection: ${e instanceof Error ? e.message : 'failed'}`);
        }
      }
    };
    await Promise.all(Array.from({ length: 4 }, worker));

    const candidates = b.rewrite_on === false ? [] : rewriteCandidates(pages, rows);
    await d.finish({ ok: true, property, window_start: w.start, window_end: w.end, totals: total, pages, rows, candidates, inspected,
      sitemap: { path: sitemap, ok: sitemapOk, error: sitemapError }, warning: warnings.join('; ').slice(0, 300) || null });
    return { status: 'synced', property, pages: pages.length, rows: rows.length, candidates: candidates.length, inspected: inspected.length, sitemap: sitemapOk, warnings };
  } catch (e) {
    const error = (e instanceof Error ? e.message : 'The Search Console sync failed').slice(0, 300);
    await d.finish({ ok: false, error, reconnect: e instanceof GscError && e.reconnect }).catch(() => undefined);
    return { status: 'error', error };
  }
}
