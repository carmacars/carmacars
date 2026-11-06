// The index coverage report (release 28, B7; web/scripts/gsc-coverage.mjs, migration 0564): which bucket a Search
// Console coverage state falls in, what kind of page an address is, and the sample of addresses a run inspects. Pure.

export type Bucket = 'indexed' | 'crawled' | 'discovered' | 'other';
/** Search Console's coverageState words, in four buckets. */
export function coverageBucket(state: string): Bucket {
  if (/^(Submitted and indexed|Indexed, not submitted in sitemap)$/i.test(state)) return 'indexed';
  if (/crawled - currently not indexed/i.test(state)) return 'crawled';
  if (/discovered - currently not indexed/i.test(state)) return 'discovered';
  return 'other';
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
