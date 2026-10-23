import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Card, PageHead, Table, Tiles, t } from '@/features/admin/ui';
import { VisitChart } from '@/features/visitors/VisitChart';
import { CONVERSION_WORDS, DEVICE_WORDS, duration, historyFilters, historyHref, historyParams, pct, place, sourceWords, topSourceWords,
  type HistoryData, type HistoryRow, type TopRow } from '@/features/visitors/history';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Visitor history', path: '/admin/live/history', noindex: true, description: 'Past visits to the site: where they came from, what they looked at and what they led to.' });

function Top({ title, rows, words, testId }: { title: string; rows: TopRow[]; words?: (r: TopRow) => string; testId: string }) {
  return (
    <div data-testid={testId}>
      <h3>{title}</h3>
      {rows.length ? <ol>{rows.map((r) => <li key={r.key}><span title={r.key}>{words ? words(r) : r.key}</span><span className="num">{r.n.toLocaleString('en-US')}</span></li>)}</ol>
        : <p className="small muted">None yet.</p>}
    </div>
  );
}

// Today > Visitor history (migration 0118): past visits with filters, a page at a time, newest first, and the daily
// chart and totals of the dates from the daily rows. Admins only (the page's gate, and the database's).
export default async function VisitorHistory({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/live/history'), searchParams]);
  const f = historyFilters(sp);
  const d = await read<HistoryData>('visitor_history', historyParams(sp));
  const s = d.summary;
  const tot = s?.totals;
  const first = !historyParams(sp).cursor;
  const v = (k: keyof typeof f) => f[k] ?? '';
  return (
    <>
      <PageHead title="Visitor history" kicker="Today"><Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/live">Live visitors</Link></PageHead>
      <p className="small muted" style={{ maxWidth: '52rem' }} data-testid="vh-intro">Visits by people who accepted analytics, known customers on their own booking pages and anyone who opened the chat, as the privacy policy allows. Staff are never recorded. Pages viewed are kept {d.keep.pages_days} days, the visit itself {d.keep.visits_days} days and the daily totals {d.keep.daily_days} days (Settings &gt; Program, &quot;Live visitors and live chat&quot;). What a visit led to is worked out 30 minutes after it ends.</p>

      <form className="vh-filters" action="/admin/live/history" method="get" role="search" aria-label="Filter the visits" data-testid="vh-filters">
        <div className="field"><label className="label" htmlFor="vh-from">From</label><input className="input" id="vh-from" name="from" type="date" defaultValue={d.from} min={d.oldest} max={d.to} /></div>
        <div className="field"><label className="label" htmlFor="vh-to">To</label><input className="input" id="vh-to" name="to" type="date" defaultValue={d.to} min={d.oldest} /></div>
        <div className="field"><label className="label" htmlFor="vh-source">Source</label><input className="input" id="vh-source" name="source" defaultValue={v('source')} placeholder="google, newsletter" /></div>
        <div className="field"><label className="label" htmlFor="vh-landing">Landing page</label><input className="input" id="vh-landing" name="landing" defaultValue={v('landing')} placeholder="/cars" /></div>
        <div className="field"><label className="label" htmlFor="vh-device">Device</label>
          <select className="select" id="vh-device" name="device" defaultValue={v('device')}><option value="">Any</option><option value="phone">Phone</option><option value="tablet">Tablet</option><option value="desktop">Computer</option></select></div>
        <div className="field"><label className="label" htmlFor="vh-country">Country</label><input className="input" id="vh-country" name="country" defaultValue={v('country')} placeholder="CA" maxLength={2} /></div>
        <div className="field"><label className="label" htmlFor="vh-city">City</label><input className="input" id="vh-city" name="city" defaultValue={v('city')} placeholder="Toronto" /></div>
        <div className="field"><label className="label" htmlFor="vh-visitor">Visitor</label>
          <select className="select" id="vh-visitor" name="visitor" defaultValue={v('visitor')}><option value="">New and returning</option><option value="new">New</option><option value="returning">Returning</option></select></div>
        <div className="field"><label className="label" htmlFor="vh-converted">Led to</label>
          <select className="select" id="vh-converted" name="converted" defaultValue={v('converted')}>
            <option value="">Anything or nothing</option><option value="any">Any conversion</option><option value="request">A request sent</option><option value="booking">A booking confirmed</option>
            <option value="signup">An account opened</option><option value="contact">Contact details given</option><option value="none">Nothing</option></select></div>
        <div className="vh-filters__checks">
          <label><input type="checkbox" name="contact" value="1" defaultChecked={f.contact === '1'} /> We can contact them</label>
          <label><input type="checkbox" name="known" value="1" defaultChecked={f.known === '1'} /> Known customers only</label>
          <label><input type="checkbox" name="bots" value="1" defaultChecked={f.bots === '1'} /> Show bots and staff</label>
        </div>
        <div className="vh-filters__go"><button className="btn btn--sm" type="submit" data-testid="vh-apply">Show visits</button>{d.filtered || f.from || f.to ? <Link prefetch={false} className="link small" href="/admin/live/history">Clear the filters</Link> : null}</div>
      </form>

      {first && s && tot && (
        <>
          <Tiles items={[
            { k: 'Visits', v: tot.visits.toLocaleString('en-US'), sub: tot.left_out ? `${tot.left_out.toLocaleString('en-US')} bots and staff left out` : undefined },
            { k: 'Unique visitors', v: (s.visitors ?? tot.visitor_days).toLocaleString('en-US'), sub: s.visitors === null ? 'added up day by day (over 3 months)' : undefined },
            { k: 'Converted', v: tot.converted.toLocaleString('en-US'), sub: [pct(tot.converted, tot.visits), `${tot.requests} requests, ${tot.bookings} bookings, ${tot.signups} accounts, ${tot.contacts} contacts`].filter(Boolean).join(' · ') },
            { k: 'Returning', v: pct(tot.returning_visits, tot.visits) || '0%', sub: `${tot.known_visits.toLocaleString('en-US')} known customers` },
            { k: 'Pages a visit', v: tot.visits ? (Math.round((tot.page_views * 10) / tot.visits) / 10).toLocaleString('en-US') : '0', sub: tot.visits ? `${pct(tot.bounces, tot.visits)} saw one page` : undefined },
            { k: 'Average visit', v: duration(tot.visits ? tot.seconds / tot.visits : 0), sub: `${pct(tot.phone, tot.visits) || '0%'} on a phone` }
          ]} />
          <Card title="Day by day" testId="vh-daily" aside={<span className="small muted">All visits in the dates; the filters apply to the list below</span>}>
            <VisitChart days={s.days} at={s.computed_at} />
            <div className="vh-tops">
              <Top title="Top pages" rows={s.top.page} words={(r) => `${r.label ?? r.key} (${r.key})`} testId="vh-top-pages" />
              <Top title="Top sources" rows={s.top.source} words={(r) => topSourceWords(r.key)} testId="vh-top-sources" />
              <Top title="Top landing pages" rows={s.top.landing} words={(r) => (r.key === '(not recorded)' ? 'Not recorded' : `${r.label ?? r.key} (${r.key})`)} testId="vh-top-landing" />
              <Top title="Countries" rows={s.top.country} words={(r) => (r.key === '--' ? 'Not known' : r.key)} testId="vh-top-countries" />
            </div>
          </Card>
        </>
      )}

      <Card title="Visits" testId="vh-list" aside={<span className="small muted">{d.from === d.to ? d.from : `${d.from} to ${d.to}`}, newest first</span>}>
        <Table<HistoryRow & Record<string, unknown>> testId="vh-table" caption="Visits" rows={d.rows as Array<HistoryRow & Record<string, unknown>>}
          empty={d.filtered ? 'No visits match. Clear a filter or widen the dates.' : 'No visits in these dates.'}
          cols={[
            { key: 'started_at', label: 'When', render: (r) => <Link prefetch={false} className="link" href={`/admin/live/history/${r.id}`} data-testid="vh-open">{t(r.started_at)}</Link> },
            { key: 'who', label: 'Visitor', render: (r) => <>{r.who}{r.returning ? <> <span className="ad-b ad-b--grey">Visit {r.visit_number}</span></> : null}{r.exclude_reason ? <> <span className="ad-b ad-b--light">{r.exclude_reason === 'bot' ? 'Bot' : 'Staff'}</span></> : null}</> },
            { key: 'source', label: 'Came from', render: (r) => sourceWords(r) },
            { key: 'landing', label: 'Pages', className: 'wrap', render: (r) => <>{r.landing ?? 'Not recorded'}{r.exit && r.exit_path !== r.landing_path ? <> to {r.exit}</> : null} <span className="muted">({r.page_views})</span></> },
            { key: 'duration_s', label: 'Length', num: true, render: (r) => duration(r.duration_s) },
            { key: 'device', label: 'Device and place', render: (r) => [r.device ? DEVICE_WORDS[r.device] : null, place(r)].filter(Boolean).join(', ') || <span className="muted">not known</span> },
            { key: 'conversions', label: 'Led to', render: (r) => <span className="vh-tags">{r.conversions.map((c) => <span key={c} className="ad-b ad-b--dark">{CONVERSION_WORDS[c]}</span>)}
              {r.has_contact && !r.conversions.includes('contact') ? <span className="ad-b ad-b--grey">Contact on file</span> : null}
              {!r.summarized ? <span className="small muted">worked out after the visit</span> : null}</span> }
          ]} />
        <div className="vh-more">
          {d.next && <Link prefetch={false} className="btn btn--ghost btn--sm" href={historyHref(f, d.next)} data-testid="vh-next">Older visits</Link>}
          {!first && <Link prefetch={false} className="link small" href={historyHref(f)}>Back to the newest</Link>}
          <span className="small muted">{d.rows.length} shown, {d.limit} a page</span>
        </div>
      </Card>
    </>
  );
}
