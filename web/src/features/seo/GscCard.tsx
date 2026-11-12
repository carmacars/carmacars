import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { Card, Kv, Table, d } from '@/features/admin/ui';
import { GSC_STATUS, ctrText, gscReason, num, positionText, type GscCard as Gsc, type GscQueued, type SeoRow } from './actions-model';

// Marketing > SEO, "Google Search Console" (release 42, migration 2640): whether the site is connected, the last daily
// sync, the 28-day totals, the best searches, and the pages sent to the writer because of what Search Console says.
// An Admin connects and disconnects here; Sales sees the same card read only (no account, no buttons).
const FLASH: Record<string, [string, boolean]> = {
  connected: ['Google Search Console is connected. The first figures arrive within a few minutes.', true],
  'no-keys': ['The site has no Google app keys yet (GOOGLE_REVIEWS_CLIENT_ID and SECRET).', false],
  'no-refresh': ['Google sent no lasting access: press Connect Google Search Console again and allow it.', false],
  'no-scope': ['Search Console was not ticked on Google\'s screen: press Connect Google Search Console again and allow it.', false],
  'no-vault': ['The database has no vault to keep the connection in.', false],
  declined: ['The connection was not allowed on Google.', false],
  state: ['The connection took too long or was started in another browser. Press Connect Google Search Console again.', false],
  failed: ['Google refused the connection. Press Connect Google Search Console again.', false]
};

export function GscCard({ g, readOnly, flash, settingsHref }: { g: Gsc; readOnly: boolean; flash?: string; settingsHref?: string }) {
  const f = flash ? FLASH[flash] : undefined;
  const on = g.status === 'connected';
  const t = g.totals;
  const rowCols = [
    { key: 'key', label: 'Search', render: (r: SeoRow) => <span className="ad-wrap">{r.key}</span> },
    { key: 'clicks', label: 'Clicks', num: true, render: (r: SeoRow) => num(r.clicks) },
    { key: 'impressions', label: 'Impressions', num: true, render: (r: SeoRow) => num(r.impressions) },
    { key: 'ctr', label: 'Click rate', num: true, render: (r: SeoRow) => ctrText(r) },
    { key: 'position', label: 'Position', num: true, render: (r: SeoRow) => positionText(r.position) }
  ];
  return (
    <Card title="Google Search Console" testId="gsc-card" tone={g.status === 'error' ? 'warn' : undefined}>
      {f && <p className={`alert ${f[1] ? 'alert--ok' : 'alert--error'}`} role={f[1] ? 'status' : 'alert'}><span>{f[0]}</span></p>}
      <p className="small row" style={{ gap: '0.5rem', alignItems: 'center', flexWrap: 'wrap' }}>
        <span data-testid="gsc-status">{on
          ? <><b>Connected</b>{g.account_email ? ` as ${g.account_email}` : ''}{g.property ? `, property ${g.property}` : ''}. The site reads Search Console once a day{g.sync_on ? '' : ' (turned off in Program settings)'}.</>
          : g.status === 'error'
            ? <><b>Connection lost.</b> Google no longer accepts it{readOnly ? ': an Admin connects it again.' : ': connect again.'}</>
            : <><b>Not connected.</b> {readOnly ? 'An Admin connects it once.' : 'Connect once and the site reads its own search figures every day, submits the sitemap and has pages that rank just under the first results written again.'}</>}</span>
        {!readOnly && <>
          {/* eslint-disable-next-line @next/next/no-html-link-for-pages -- an API route (an OAuth redirect), not a page */}
          <a className={`btn btn--sm ${on ? 'btn--ghost' : 'btn--primary'}`} href="/api/google/search-console/connect" data-testid="gsc-connect">{on ? 'Connect again' : 'Connect Google Search Console'}</a>
          {g.status !== 'not_connected' && <Act action="gsc_disconnect" label="Disconnect" confirm="The site stops reading Search Console. The figures already read stay." refresh={['/admin/marketing/seo']} testId="gsc-disconnect" />}
        </>}
      </p>
      {g.last_error && <p className="small error" data-testid="gsc-error">Last sync problem{g.last_error_at ? ` (${d(g.last_error_at)})` : ''}: {g.last_error}</p>}
      {g.status !== 'not_connected' && <>
        <Kv rows={[
          ['Last sync', g.last_sync_at ? d(g.last_sync_at) : 'Not yet: the first one runs within a few minutes of connecting'],
          ['Days read', t?.window_start && t.window_end ? `${d(t.window_start)} to ${d(t.window_end)} (28 days)` : ''],
          ['Clicks', t ? num(t.clicks) : ''],
          ['Impressions', t ? num(t.impressions) : ''],
          ['Average position', t ? positionText(t.position) : ''],
          ['Sitemap', g.sitemap.error ? `Not accepted: ${g.sitemap.error}` : g.sitemap.at ? `Submitted ${d(g.sitemap.at)}` : ''],
          ['Pages checked with Google at the last sync', g.last_sync_at ? num(g.inspected_last) : ''],
          ['Rewrites', g.rewrite_on ? `On: up to ${num(g.rewrite_daily_max)} pages a day, the same page at most once in 28 days; ${num(g.queued_waiting)} waiting for the writer` : 'Off in Program settings']
        ]} />
        <Table testId="gsc-queries" caption="Top 10 searches, last 28 days" rows={g.top_queries as unknown as Array<Record<string, unknown>>} rowKey={(r) => String(r.key)} cols={rowCols as never} empty="No search figures yet." />
        <Table testId="gsc-queued" caption="Pages sent to the writer because of Search Console" rows={g.queued as unknown as Array<Record<string, unknown>>} rowKey={(r) => `${String(r.path)}-${String(r.queued_at)}`}
          empty="No page has been sent to the writer yet. A landing page or a guide is sent when it ranks at position 8 to 20, or is shown at least 50 times with a click rate under 1%."
          cols={[
            { key: 'path', label: 'Page', render: (r) => <span className="ad-wrap">{(r as unknown as GscQueued).path}</span> },
            { key: 'reason', label: 'Why', render: (r) => gscReason(r as unknown as GscQueued) },
            { key: 'queries', label: 'Searches given to the writer', render: (r) => <span className="ad-wrap">{(r as unknown as GscQueued).queries.join(', ')}</span> },
            { key: 'queued_at', label: 'Sent', render: (r) => d((r as unknown as GscQueued).queued_at) },
            { key: 'status', label: 'Now', render: (r) => GSC_STATUS[(r as unknown as GscQueued).status] ?? '' }
          ]} />
      </>}
      {!readOnly && <p className="small muted">The daily sync and the rewrites are on by default. <Link prefetch={false} className="link" href={settingsHref ?? '/admin/settings'}>Turn either off in Program settings</Link> (Search Console).</p>}
    </Card>
  );
}
