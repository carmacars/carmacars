// Which sitemaps Search Console should hold (0124), worked out by web/scripts/gsc.mjs (the gsc workflow). No imports:
// it runs in Node for the workflow and the unit test.
//
// Search Console takes at most 500 sitemaps per property, and a sitemap index there is only as useful as the files it
// lists (Google reads them one by one, slowly). So the property holds the files themselves, the most useful first:
//   1. /sitemap.xml (the root index: everything is reachable from it and from robots.txt, which names every index file);
//   2. the priority sitemap's parts and the site's own files (pages, cars, landing pages, guides, model pages);
//   3. the place and vehicle files in the index's order (popular first), only those with addresses, keeping the ones
//      already submitted so a file's figures build up over time, up to the limit.
// What the property holds of ours and the plan does not (the old /sitemap-index/<n>.xml files, which listed files
// outside their directory and so showed 0 discovered pages, and the old /sitemap-priority.xml) is removed to make room.

export interface GscSitemap { path: string; errors?: string | number; warnings?: string | number; isPending?: boolean; isSitemapsIndex?: boolean; lastDownloaded?: string; lastSubmitted?: string; contents?: Array<{ type?: string; submitted?: string | number; indexed?: string | number }> }
export interface GscPlan { desired: string[]; submit: string[]; remove: string[]; retry: string[] }

/** One of the site's own sitemap addresses (current or old), so only those are ever removed from the property. */
export function isOurSitemap(path: string, base: string): boolean {
  if (!path.startsWith(base + '/')) return false;
  const p = path.slice(base.length);
  return /^\/(sitemap[a-z0-9.-]*\.xml|sitemap-(index|vehicles|places)\/[a-z0-9.-]+\.xml)$/.test(p);
}

export function planSitemaps(o: {
  base: string;
  /** the root index, the priority parts and the site's own files, in that order */
  head: string[];
  /** the place and vehicle files with addresses, in the index's order */
  files: string[];
  current: GscSitemap[];
  max: number;
  /** submit every desired file again (a run by hand), else only those the property does not hold */
  all: boolean;
  retryMax?: number;
}): GscPlan {
  const max = Math.max(1, o.max);
  const held = new Map(o.current.map((s) => [s.path, s]));
  const desired: string[] = [];
  const add = (p: string) => { if (desired.length < max && !desired.includes(p)) desired.push(p); };
  for (const p of o.head) add(p);
  // the files already held first (their figures keep building), then new ones, both in the index's order
  for (const p of o.files) if (held.has(p)) add(p);
  for (const p of o.files) add(p);
  const want = new Set(desired);
  const remove = o.current.map((s) => s.path).filter((p) => !want.has(p) && isOurSitemap(p, o.base));
  const submit = desired.filter((p) => o.all || !held.has(p));
  const sub = new Set(submit);
  const retry = desired.filter((p) => !sub.has(p) && Number(held.get(p)?.errors ?? 0) > 0).slice(0, o.retryMax ?? 40);
  return { desired, submit, remove, retry };
}

/** A row of app.gsc_sitemap_log from Search Console's answer. */
export function gscRow(s: GscSitemap) {
  const web = (s.contents ?? []).find((c) => c.type === 'web') ?? (s.contents ?? [])[0];
  const n = (v: unknown) => (v === undefined || v === null || v === '' ? null : Number(v));
  return { path: s.path, is_index: !!s.isSitemapsIndex, is_pending: !!s.isPending, last_submitted: s.lastSubmitted ?? null, last_downloaded: s.lastDownloaded ?? null,
    errors: n(s.errors), warnings: n(s.warnings), submitted: n(web?.submitted), indexed: n(web?.indexed) };
}

/** The <loc> values of a sitemap or sitemap index. */
export const locsOf = (xml: string) => [...xml.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]!.replace(/&amp;/g, '&'));
