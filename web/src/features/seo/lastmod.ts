// A sitemap lastmod (release 35, part M; migration 1100): the later of a page's own date and the content epoch (when
// the facts every programmatic page shows, or its template, last changed), so a page's lastmod moves when its content
// does. Pure (the unit test runs it in Node).
export function withEpoch(d: string | null, epoch: number): string | null {
  const t = d ? Date.parse(d) : NaN;
  const m = Math.max(Number.isFinite(t) ? t : 0, epoch);
  return m > 0 ? new Date(m).toISOString() : null;
}
