import { compact, growth, trendBars, type DeckSearch } from './search';

// The investor deck's Search Console slide (migration 1507): clicks and impressions of the last 28 days with their growth,
// the indexed pages and the weekly impressions trend. The site's own search figures only.
const day = (s: string) => new Date(`${s}T12:00:00Z`).toLocaleDateString('en-CA', { timeZone: 'UTC', month: 'short', day: 'numeric' });

export function SearchTraction({ s }: { s: DeckSearch | null }) {
  if (!s || (!s.as_of && s.indexed_pages === null)) return null;
  const bars = trendBars(s.weeks);
  return (
    <section className="pt-card stack" aria-labelledby="dk-search" data-testid="deck-search">
      <h2 className="d3" id="dk-search">Search traction</h2>
      <dl className="th-points">
        <div><dt className="small muted">Google clicks, last 28 days</dt><dd className="d3" data-testid="deck-search-clicks">{compact(s.clicks_28d)}</dd><dd className="small">{growth(s.clicks_growth_pct)}</dd></div>
        <div><dt className="small muted">Impressions, last 28 days</dt><dd className="d3" data-testid="deck-search-impressions">{compact(s.impressions_28d)}</dd><dd className="small">{growth(s.impressions_growth_pct)}</dd></div>
        <div><dt className="small muted">Pages indexed by Google</dt><dd className="d3" data-testid="deck-search-indexed">{compact(s.indexed_pages)}</dd>
          <dd className="small">{s.indexed_estimate ? 'estimate from a sample' : s.indexed_on ? `Search Console, ${day(s.indexed_on)}` : ''}</dd></div>
      </dl>
      {bars.length > 1 && <figure className="stack" data-testid="deck-search-trend">
        <div role="img" aria-label={`Weekly impressions over ${bars.length} weeks, from ${compact(s.weeks[0]?.impressions)} to ${compact(s.weeks[s.weeks.length - 1]?.impressions)}`}
          style={{ display: 'flex', alignItems: 'flex-end', gap: 4, height: 80 }}>
          {bars.map((h, i) => <span key={s.weeks[i]!.week_of} title={`Week of ${day(s.weeks[i]!.week_of)}: ${s.weeks[i]!.impressions} impressions, ${s.weeks[i]!.clicks} clicks`}
            style={{ flex: 1, height: `${Math.max(2, h)}%`, background: 'var(--accent, currentColor)', opacity: 0.8, borderRadius: 2 }} />)}</div>
        <figcaption className="small muted">Impressions week by week{s.as_of ? `, to ${day(s.as_of)}` : ''} (Google Search Console; its figures settle after about three days).</figcaption>
      </figure>}
    </section>
  );
}
