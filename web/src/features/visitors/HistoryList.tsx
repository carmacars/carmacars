import Link from '@/components/Link';
import { GetForm } from '@/components/GetForm';
import { QuickRange } from '@/components/QuickRange';
import { torontoToday } from '@/lib/nav/range';
import { VisitChart } from './VisitChart';
import { HistoryRows } from './HistoryRows';
import { duration, historyFilters, historyHref, historyParams, pct, topSourceWords, type FilterKey, type HistoryData, type TopRow } from './history';
import { DateRangePicker } from '@/components/DateRangePicker';

// The Visitors page's History (Release 27, redesigned): one list grouped by day, a compact row a visit (time, who and what
// they are to us, city, source, pages and the cars they looked at, score, what it led to) that opens to its page trail;
// quick date ranges, the filters that matter in one row and the rest under More; the totals as one line, the chart and the
// top lists folded under it. Admins, customer service and Sales (r27 consolidation; the page's gate and the database's). Never a phone or an email.

function Top({ title, rows, words, testId }: { title: string; rows: TopRow[]; words?: (r: TopRow) => string; testId: string }) {
  return (
    <div data-testid={testId}>
      <h3>{title}</h3>
      {rows.length ? <ol>{rows.map((r) => <li key={r.key}><span title={r.key}>{words ? words(r) : r.key}</span><span className="num">{r.n.toLocaleString('en-US')}</span></li>)}</ol>
        : <p className="small muted">None yet.</p>}
    </div>
  );
}

export function HistoryList({ d, sp, now, base = '/admin/visitors' }: { d: HistoryData; sp: Record<string, string | string[] | undefined>; now: number; /** the Visitors page: Admin's or staff's (r27 consolidation) */ base?: string }) {
  const f = historyFilters(sp);
  const s = d.summary;
  const tot = s?.totals;
  const first = !historyParams(sp).cursor;
  const v = (k: FilterKey) => f[k] ?? '';
  const more = !!(f.city || f.landing || f.device || f.country || f.visitor || f.contact || f.known || f.bots);
  const today = torontoToday(now);
  const keep = Object.fromEntries((Object.entries(f) as Array<[string, string]>).concat([['view', 'history']]));
  const n = (x: number) => x.toLocaleString('en-US');
  return (
    <div className="vs-hist" data-testid="vh-list">
      <details className="vs-about small muted"><summary>About these visits</summary><p className="vs-intro" data-testid="vh-intro">Visits by people who accepted analytics, known customers on their own booking pages and anyone who opened the chat, as the privacy policy allows. Staff are never recorded. Pages viewed are kept {d.keep.pages_days} days, the visit itself {d.keep.visits_days} days and the daily totals {d.keep.daily_days} days. What a visit led to is worked out 30 minutes after it ends.</p></details>

      <GetForm className="vhf" action={base} role="search" aria-label="Filter the visits" data-testid="vh-filters">
        <input type="hidden" name="view" value="history" />
        <div className="vhf__row">
          <QuickRange base={base} keep={keep} from={d.from} to={d.to} today={today} customId="vh-from" label="Dates" />
          <DateRangePicker id="vh-from" label="Dates" from={d.from} to={d.to} min={d.oldest} quick={false} />
          <div className="field"><label className="label" htmlFor="vh-source">Source</label><input className="input" id="vh-source" name="source" defaultValue={v('source')} placeholder="google, ad, newsletter" /></div>
          <div className="field"><label className="label" htmlFor="vh-converted">Led to</label>
            <select className="select" id="vh-converted" name="converted" defaultValue={v('converted')}>
              <option value="">Anything or nothing</option><option value="any">Any conversion</option><option value="request">A request sent</option><option value="booking">A booking confirmed</option>
              <option value="signup">An account opened</option><option value="contact">Contact details given</option><option value="none">Nothing</option></select></div>
          <button className="btn btn--primary btn--sm vhf__go" type="submit" data-testid="vh-apply">Show visits</button>
        </div>
        <details className="vs-more" open={more}>
          <summary>More filters</summary>
          <div className="vs-more__in">
            <div className="field"><label className="label" htmlFor="vh-city">City</label><input className="input" id="vh-city" name="city" defaultValue={v('city')} placeholder="Toronto" /></div>
            <div className="field"><label className="label" htmlFor="vh-device">Device</label>
              <select className="select" id="vh-device" name="device" defaultValue={v('device')}><option value="">Any</option><option value="phone">Phone</option><option value="tablet">Tablet</option><option value="desktop">Computer</option></select></div>
            <div className="field"><label className="label" htmlFor="vh-landing">Landing page</label><input className="input" id="vh-landing" name="landing" defaultValue={v('landing')} placeholder="/cars" /></div>
            <div className="field"><label className="label" htmlFor="vh-country">Country</label><input className="input" id="vh-country" name="country" defaultValue={v('country')} placeholder="CA" maxLength={2} /></div>
            <div className="field"><label className="label" htmlFor="vh-visitor">Visitor</label>
              <select className="select" id="vh-visitor" name="visitor" defaultValue={v('visitor')}><option value="">New and returning</option><option value="new">New</option><option value="returning">Returning</option></select></div>
            <div className="vs-more__checks">
              <label><input type="checkbox" name="contact" value="1" defaultChecked={f.contact === '1'} /> We can contact them</label>
              <label><input type="checkbox" name="known" value="1" defaultChecked={f.known === '1'} /> Known customers only</label>
              <label><input type="checkbox" name="bots" value="1" defaultChecked={f.bots === '1'} /> Show bots and staff</label>
            </div>
          </div>
        </details>
        {d.filtered ? <p className="small"><Link prefetch={false} className="link" href={`${base}?view=history`}>Clear the filters</Link></p> : null}
      </GetForm>

      {first && s && tot && (
        <>
          <p className="vh-sum" data-testid="vh-summary"><b>{n(tot.visits)}</b> visits{tot.left_out ? <span className="muted"> ({n(tot.left_out)} bots and staff left out)</span> : null}
            <span> · <b>{n(s.visitors ?? tot.visitor_days)}</b> visitors</span>
            <span> · <b>{n(tot.converted)}</b> converted{tot.visits ? ` (${pct(tot.converted, tot.visits)})` : ''}: {tot.requests} requests, {tot.bookings} bookings, {tot.signups} accounts, {tot.contacts} contacts</span>
            <span> · {tot.visits ? (Math.round((tot.page_views * 10) / tot.visits) / 10).toLocaleString('en-US') : '0'} pages a visit</span>
            <span> · {duration(tot.visits ? tot.seconds / tot.visits : 0)} average</span>
            <span> · {pct(tot.returning_visits, tot.visits) || '0%'} returning</span>
            <span> · {pct(tot.phone, tot.visits) || '0%'} on a phone</span></p>
          <details className="vs-sum">
            <summary>Day by day and top pages <span className="muted">({d.from === d.to ? d.from : `${d.from} to ${d.to}`})</span></summary>
            <div className="vs-chart" data-testid="vh-daily"><VisitChart days={s.days} at={s.computed_at} /></div>
            <div className="vh-tops">
              <Top title="Top pages" rows={s.top.page} words={(r) => `${r.label ?? r.key} (${r.key})`} testId="vh-top-pages" />
              <Top title="Top sources" rows={s.top.source} words={(r) => topSourceWords(r.key)} testId="vh-top-sources" />
              <Top title="Top landing pages" rows={s.top.landing} words={(r) => (r.key === '(not recorded)' ? 'Not recorded' : `${r.label ?? r.key} (${r.key})`)} testId="vh-top-landing" />
              <Top title="Countries" rows={s.top.country} words={(r) => (r.key === '--' ? 'Not known' : r.key)} testId="vh-top-countries" />
            </div>
          </details>
        </>
      )}

      {!d.rows.length ? <p className="vs-empty">{d.filtered ? 'No visits match. Clear a filter or widen the dates.' : 'No visits in these dates.'}</p> : <HistoryRows rows={d.rows} now={now} admin={base.startsWith('/admin')} />}
      <div className="vh-pager">
        {d.next && <Link prefetch={false} className="btn btn--ghost btn--sm" href={historyHref(f, d.next, base)} data-testid="vh-next">Older visits</Link>}
        {!first && <Link prefetch={false} className="link small" href={historyHref(f, null, base)}>Back to the newest</Link>}
        <span className="small muted">{d.rows.length} shown, {d.limit} a page</span>
      </div>
    </div>
  );
}
