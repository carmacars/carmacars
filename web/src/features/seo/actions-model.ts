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
  /** 2640: the site's own Search Console connection and daily sync; absent before the migration. */
  gsc?: GscCard;
}
export interface GscQueued { path: string; kind: 'page' | 'article'; reason: 'position' | 'low_ctr'; status: 'queued' | 'written' | 'dropped'; queued_at: string; done_at: string | null;
  impressions: number; ctr: number | null; position: number | null; queries: string[] }
export interface GscCard {
  status: 'not_connected' | 'connected' | 'error'; account_email: string | null; property: string | null; connected_at: string | null;
  last_sync_at: string | null; last_error: string | null; last_error_at: string | null; sync_on: boolean; rewrite_on: boolean; rewrite_daily_max: number;
  totals: { clicks: number; impressions: number; ctr: number | null; position: number | null; window_start: string | null; window_end: string | null } | null;
  sitemap: { path: string | null; at: string | null; error: string | null }; inspected_last: number;
  top_queries: SeoRow[]; queued: GscQueued[]; queued_waiting: number;
}
/** Why Search Console had a page written again, in words. */
export function gscReason(q: Pick<GscQueued, 'reason' | 'impressions' | 'ctr' | 'position'>): string {
  return q.reason === 'position'
    ? `Position ${positionText(q.position) || 'not known'}, close to the first results`
    : `Shown ${num(q.impressions)} times, clicked ${ctrText({ key: '', clicks: 0, impressions: 0, ctr: q.ctr ?? 0, position: null })}`;
}
export const GSC_STATUS: Record<GscQueued['status'], string> = { queued: 'Waiting for the writer', written: 'Written again', dropped: 'Not written in two weeks, let go' };
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
