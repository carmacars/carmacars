// The index coverage report (release 28, B7; web/scripts/gsc-coverage.mjs, migration 0564): which bucket a Search
// Console coverage state falls in, what kind of page an address is, and the sample of addresses a run inspects. Pure.

export type Bucket = 'indexed' | 'crawled' | 'discovered' | 'unknown' | 'other';
/** Search Console's coverageState words, in five buckets (1103: "URL is unknown to Google" is its own bucket, not "not
 *  indexed"; an indexed state is any state that says indexed and not "not indexed"). The verdict PASS is indexed too. */
export function coverageBucket(state: string, verdict?: string | null): Bucket {
  if (verdict === 'PASS') return 'indexed';
  if (/crawled\W+currently not indexed/i.test(state)) return 'crawled';
  if (/discovered\W+currently not indexed/i.test(state)) return 'discovered';
  if (/unknown to google/i.test(state)) return 'unknown';
  if (/indexed/i.test(state) && !/not indexed/i.test(state)) return 'indexed';
  return 'other';
}
export const emptyBuckets = (): Record<Bucket, number> => ({ indexed: 0, crawled: 0, discovered: 0, unknown: 0, other: 0 });

/** 1103: the shares the Admin card shows: indexed of the addresses Google knows (as Search Console counts), and of all
 *  inspected; the sample's long tail is mostly unknown to Google, which made 172K indexed read as 1%. */
export function coverageShares(b: Record<Bucket, number>): { inspected: number; known: number; indexedOfKnown: number | null; indexedOfAll: number | null } {
  const inspected = b.indexed + b.crawled + b.discovered + b.unknown + b.other;
  const known = inspected - b.unknown;
  return { inspected, known, indexedOfKnown: known ? b.indexed / known : null, indexedOfAll: inspected ? b.indexed / inspected : null };
}

/** The kind of page an address is: cars, places (the place and term pages), vehicle pages, guides, other. */
export function pageKind(path: string): 'car' | 'place' | 'vehicle' | 'guide' | 'other' {
  if (/^\/cars\/[^/]+/.test(path)) return 'car';
  if (/^\/(car-rental|rent|buy|detailing|body-shop|places)\//.test(path)) return 'place';
  if (/^\/(makes|vehicles?|models?)\b/.test(path)) return 'vehicle';
  if (/^\/guides\//.test(path)) return 'guide';
  return 'other';
}

/** The run's sample: a third from the priority list, the rest from the long tail, each part rotating by `seed` so every
 *  run looks at another slice; each address once. */
export function pickSample(priority: string[], tail: string[], n: number, seed: number): string[] {
  const take = (list: string[], k: number) => {
    if (!list.length || k <= 0) return [];
    const step = Math.max(1, Math.floor(list.length / k));
    const start = (seed * 31) % list.length;
    const out: string[] = [];
    for (let i = 0; out.length < Math.min(k, list.length) && i < list.length * 2; i++) {
      const u = list[(start + i * step) % list.length]!;
      if (!out.includes(u)) out.push(u);
    }
    return out;
  };
  const p = take(priority, Math.ceil(n / 3));
  const t = take(tail.filter((u) => !p.includes(u)), n - p.length);
  const rest = t.length < n - p.length ? take(priority.filter((u) => !p.includes(u)), n - p.length - t.length) : [];
  return [...p, ...t, ...rest].slice(0, n);
}

// r50 hotfix 2: the pages Google already shows in search (Search Analytics, the gsc workflow's pages file) checked on
// the live site. The sample above inspects sitemap addresses, which the site itself lists, so it never met a page that
// had gone; Search Console's own error report has no API. A known page that answers 404 or 410 (or 5xx twice) is stored
// as an error (app.gsc_url_inspection), where the self-healing checks find it (4800: a car page gets its redirect).
/** The most shown pages of the pages file, as paths, at most n. */
export function knownPages(rows: Array<{ kind: string; key: string; impressions?: number }>, n: number): string[] {
  return rows.filter((r) => r.kind === 'page' && /^\/[a-z0-9/._-]*$/.test(r.key) && !r.key.startsWith('/api/'))
    .sort((a, b) => (b.impressions ?? 0) - (a.impressions ?? 0)).slice(0, Math.max(0, n)).map((r) => r.key);
}
/** The stored state of a known page from its answer (null: fine, a redirect included). */
export function knownPageState(status: number): { state: string; bucket: 'other' } | null {
  if (status === 404 || status === 410) return { state: `Not found (${status}), seen by the site check`, bucket: 'other' };
  if (status >= 500) return { state: `Server error (5xx), seen by the site check`, bucket: 'other' };
  return null;
}
