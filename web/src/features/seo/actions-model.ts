// The SEO page's figures (migration 1860, app.seo_actions): pure helpers, no imports, tested in Node.
export interface SeoRow { key: string; clicks: number; impressions: number; ctr: number | null; position: number | null }
export interface SeoSitemapRow { sitemap: string; inspected: number; indexed: number; crawled: number; discovered: number; unknown: number }
export interface SeoData {
  goal: { target: number; clicks_28d: number; impressions_28d: number; month_to_date: number; last_day: string | null; pace_30d: number; share_bps: number };
  weeks: Array<{ week: string; clicks: number; impressions: number }>;
  top_queries: SeoRow[]; top_pages: SeoRow[]; low_ctr: SeoRow[]; low_ctr_line: { pct: number; min_impressions: number };
  /** 2350: the queries ranking between min_pos and max_pos (Program settings), by impressions; absent before the migration. */
  striking?: SeoRow[]; striking_line?: { min_pos: number; max_pos: number; min_impressions: number };
  by_sitemap: SeoSitemapRow[];
  coverage: { at: string; inspected: number; buckets: Record<string, number> } | null;
  indexnow: { waiting: number; sent_7d: number; not_indexed_scheduled: number };
  digest: { on: boolean };
  read_only: boolean;
}
const nf = new Intl.NumberFormat('en-CA');
export const num = (n: number | null | undefined) => (n === null || n === undefined ? '' : nf.format(Math.round(n)));
/** 4,200 bps -> "42%"; under 1% keeps a decimal so a small start still reads as moving */
export function goalShare(bps: number): string {
  const p = bps / 100;
  return p >= 10 ? `${Math.round(p)}%` : `${(Math.round(p * 10) / 10).toString()}%`;
}
export const ctrText = (r: SeoRow) => {
  const v = r.ctr ?? (r.impressions > 0 ? r.clicks / r.impressions : 0);
  return `${(Math.round(v * 1000) / 10).toString()}%`;
};
export const positionText = (p: number | null) => (p === null || p === undefined ? '' : (Math.round(p * 10) / 10).toString());
/** the share of the sampled pages Google knows that are indexed, or null when it knows none */
export function indexedShare(b: Record<string, number> | undefined): number | null {
  if (!b) return null;
  const known = (b.indexed ?? 0) + (b.crawled ?? 0) + (b.discovered ?? 0) + (b.other ?? 0);
  return known > 0 ? (b.indexed ?? 0) / known : null;
}
