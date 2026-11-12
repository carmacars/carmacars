import Link from '@/components/Link';
import { Card, Kv, Table, Tiles, d } from '@/features/admin/ui';
import { ctrText, goalShare, indexedShare, num, positionText, type SeoData, type SeoRow, type SeoSitemapRow } from './actions-model';

// Marketing > SEO (Admin) and Sales > Marketing > SEO (read only), migration 1860: the goal in Google clicks a month, the best
// queries and pages, the pages shown a lot and clicked little, and the pages Google knows but has not indexed, by sitemap.
// The figures come from the gsc workflow (Search Console's API, every three hours).
export function SeoActionsView({ data, settingsHref }: { data: SeoData; settingsHref?: string }) {
  const g = data.goal;
  const cov = data.coverage?.buckets;
  const share = indexedShare(cov);
  const rowCols = (first: string) => [
    { key: 'key', label: first, render: (r: SeoRow) => <span className="ad-wrap">{r.key}</span> },
    { key: 'clicks', label: 'Clicks', num: true, render: (r: SeoRow) => num(r.clicks) },
    { key: 'impressions', label: 'Impressions', num: true, render: (r: SeoRow) => num(r.impressions) },
    { key: 'ctr', label: 'Click rate', num: true, render: (r: SeoRow) => ctrText(r) },
    { key: 'position', label: 'Position', num: true, render: (r: SeoRow) => positionText(r.position) }
  ];
  return (<>
    <Tiles items={[
      { k: 'Clicks, last 28 days', v: num(g.clicks_28d), sub: g.last_day ? `to ${d(g.last_day)}` : 'No Search Console figures yet' },
      { k: 'Pace for a month', v: num(g.pace_30d), sub: `${goalShare(g.share_bps)} of the goal` },
      { k: 'Monthly goal', v: num(g.target), sub: data.read_only ? undefined : <Link prefetch={false} className="link" href={settingsHref ?? '/admin/settings'}>Change in Program settings</Link> },
      { k: 'Month so far', v: num(g.month_to_date) }
    ]} />
    <Card title="Goal tracker" testId="seo-goal">
      <div className="ug-meter" role="meter" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.min(100, Math.round(g.share_bps / 100))} aria-label={`Clicks a month against the goal: ${goalShare(g.share_bps)}`}>
        <span className="ug-meter__bar" style={{ width: `${Math.max(0.5, Math.min(100, g.share_bps / 100))}%` }} />
      </div>
      <p className="small muted" data-testid="seo-goal-line">At the last 28 days&apos; pace the month brings about {num(g.pace_30d)} clicks, {goalShare(g.share_bps)} of {num(g.target)}.</p>
      <Table testId="seo-weeks" caption="Clicks by week" rows={[...data.weeks].reverse() as unknown as Array<Record<string, unknown>>} rowKey={(r) => String(r.week)}
        empty="Search Console has not reported yet (the gsc workflow runs every three hours)."
        cols={[{ key: 'week', label: 'Week of', render: (r) => d(String(r.week)) }, { key: 'clicks', label: 'Clicks', num: true, render: (r) => num(Number(r.clicks)) }, { key: 'impressions', label: 'Impressions', num: true, render: (r) => num(Number(r.impressions)) }]} />
    </Card>
    <Card title="Best queries" testId="seo-queries"><Table testId="seo-queries-table" caption="Best queries" rows={data.top_queries as unknown as Array<Record<string, unknown>>} rowKey={(r) => String(r.key)} cols={rowCols('Query') as never} empty="No query figures yet." /></Card>
    <Card title="Best pages" testId="seo-pages"><Table testId="seo-pages-table" caption="Best pages" rows={data.top_pages as unknown as Array<Record<string, unknown>>} rowKey={(r) => String(r.key)} cols={rowCols('Page') as never} empty="No page figures yet." /></Card>
    <Card title="Shown a lot, clicked little" testId="seo-low-ctr"
      aside={<span className="small muted">From {num(data.low_ctr_line.min_impressions)} impressions and under {data.low_ctr_line.pct}% click rate: a better title and description are the fix</span>}>
      <Table testId="seo-low-ctr-table" caption="Pages with impressions but a low click rate" rows={data.low_ctr as unknown as Array<Record<string, unknown>>} rowKey={(r) => String(r.key)} cols={rowCols('Page') as never} empty="No page is shown a lot and clicked little." />
    </Card>
    {data.striking_line && (
      <Card title="Within reach: queries ranking 5 to 30" testId="seo-striking"
        aside={<span className="small muted">Average position {data.striking_line.min_pos} to {data.striking_line.max_pos}, from {num(data.striking_line.min_impressions)} impressions: tune the page&apos;s title and description, answer the query on the page, and link to it from home</span>}>
        <Table testId="seo-striking-table" caption="Queries ranking within reach of the first results" rows={(data.striking ?? []) as unknown as Array<Record<string, unknown>>} rowKey={(r) => String(r.key)} cols={rowCols('Query') as never} empty="No query ranks within reach yet." />
      </Card>
    )}
    <Card title="Indexing" testId="seo-index">
      <Kv rows={[
        ['Sample inspected', data.coverage ? `${num(data.coverage.inspected)} pages, last run ${d(data.coverage.at)}` : 'No sample yet'],
        ['Indexed of the pages Google knows', share === null ? '' : `${Math.round(share * 100)}%`],
        ['Crawled, currently not indexed', cov ? num(cov.crawled) : ''],
        ['Discovered, currently not indexed', cov ? num(cov.discovered) : ''],
        ['Search engines told (IndexNow)', `${num(data.indexnow.sent_7d)} addresses in 7 days, ${num(data.indexnow.waiting)} waiting; ${num(data.indexnow.not_indexed_scheduled)} not-indexed pages are sent again on a growing schedule`]
      ]} />
      <Table testId="seo-sitemaps" caption="Inspected pages by sitemap" rows={data.by_sitemap as unknown as Array<Record<string, unknown>>} rowKey={(r) => String(r.sitemap)} empty="No inspected page names its sitemap yet."
        cols={[
          { key: 'sitemap', label: 'Sitemap', render: (r) => <span className="ad-wrap">{(r as unknown as SeoSitemapRow).sitemap}</span> },
          { key: 'inspected', label: 'Inspected', num: true }, { key: 'indexed', label: 'Indexed', num: true },
          { key: 'crawled', label: 'Crawled, not indexed', num: true }, { key: 'discovered', label: 'Discovered, not indexed', num: true }, { key: 'unknown', label: 'Unknown to Google', num: true }
        ]} />
      <p className="small muted">Search Console&apos;s Pages report has no API; this is the sample the gsc workflow inspects with the URL Inspection API (2,000 a day). {data.digest.on ? 'A weekly digest goes to the alert address on Monday mornings.' : 'The weekly digest is off in Program settings.'}</p>
    </Card>
  </>);
}
