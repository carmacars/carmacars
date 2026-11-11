// Search Console traction on the investor deck (migration 1507): pure words for the figures (no fleet, utilisation,
// premium or cost figure is ever here).
//   node --test --experimental-strip-types src/features/deck/search.test.ts   (npm run test:unit)
export interface DeckSearch { as_of: string | null; clicks_28d: number | null; impressions_28d: number | null; clicks_prev_28d: number | null; impressions_prev_28d: number | null;
  clicks_growth_pct: number | null; impressions_growth_pct: number | null; indexed_pages: number | null; indexed_estimate: boolean; indexed_on: string | null;
  weeks: Array<{ week_of: string; clicks: number; impressions: number }> }

export const compact = (n: number | null | undefined): string => {
  if (n === null || n === undefined || !Number.isFinite(Number(n))) return 'n/a';
  const v = Number(n);
  return v >= 1_000_000 ? `${(v / 1_000_000).toFixed(v >= 10_000_000 ? 0 : 1)}M` : v >= 10_000 ? `${Math.round(v / 1000)}K` : v >= 1000 ? `${(v / 1000).toFixed(1)}K` : String(v);
};
export const growth = (p: number | null | undefined): string => (p === null || p === undefined ? 'new' : `${p >= 0 ? '+' : ''}${p}% on the 28 days before`);
/** The bar heights (0 to 100) of the weekly impressions, for the trend. */
export function trendBars(weeks: DeckSearch['weeks']): number[] {
  const max = Math.max(0, ...weeks.map((w) => Number(w.impressions) || 0));
  return weeks.map((w) => (max > 0 ? Math.round((100 * (Number(w.impressions) || 0)) / max) : 0));
}
