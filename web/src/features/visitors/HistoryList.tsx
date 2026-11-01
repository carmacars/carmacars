import Link from 'next/link';
import { Tiles, t } from '@/features/admin/ui';
import { VisitChart } from './VisitChart';
import { VsIcon } from '@/features/live/LiveVisitors';
import { HistoryLocate } from './HistoryLocate';
import { CONVERSION_WORDS, DEVICE_WORDS, duration, historyFilters, historyHref, historyParams, pct, place, sourceWords, topSourceWords,
  type FilterKey, type HistoryData, type HistoryRow, type TopRow } from './history';

// The Visitors page's History (Release 26; Visitor history, migration 0118): past visits as cards (who, where they came
// from, the pages, how long, the device and place, what it led to), the filters that matter in one row and the rest
// folded, and the dates' chart and totals folded under them. Each card finds its lead on the map; "Open the visit"
// has every page and event. Admins only (the page's gate, and the database's). Never a phone or an email.

function Top({ title, rows, words, testId }: { title: string; rows: TopRow[]; words?: (r: TopRow) => string; testId: string }) {
  return (
    <div data-testid={testId}>
      <h3>{title}</h3>
      {rows.length ? <ol>{rows.map((r) => <li key={r.key}><span title={r.key}>{words ? words(r) : r.key}</span><span className="num">{r.n.toLocaleString('en-US')}</span></li>)}</ol>
        : <p className="small muted">None yet.</p>}
    </div>
  );
}

/** What the visit is, for its icon: what it led to (the strongest), else a returning or a new visitor. */
function kindOf(r: HistoryRow): { key: string; label: string } {
  if (r.exclude_reason) return { key: 'bot', label: r.exclude_reason === 'bot' ? 'Bot' : 'Staff' };
  for (const c of ['booking', 'request', 'signup', 'contact'] as const) if (r.conversions.includes(c)) return { key: c, label: CONVERSION_WORDS[c] };
  if (r.known) return { key: 'known', label: 'Known customer' };
  return { key: 'visitor', label: r.returning ? `Visit ${r.visit_number}` : 'New visitor' };
}

export function HistoryList({ d, sp }: { d: HistoryData; sp: Record<string, string | string[] | undefined> }) {
  const f = historyFilters(sp);
  const s = d.summary;
  const tot = s?.totals;
  const first = !historyParams(sp).cursor;
  const v = (k: FilterKey) => f[k] ?? '';
  const more = !!(f.device || f.landing || f.country || f.visitor || f.contact || f.known || f.bots);
  return (
    <div className="vs-hist" data-testid="vh-list">
      <p className="small muted vs-intro" data-testid="vh-intro">Visits by people who accepted analytics, known customers on their own booking pages and anyone who opened the chat, as the privacy policy allows. Staff are never recorded. Pages viewed are kept {d.keep.pages_days} days, the visit itself {d.keep.visits_days} days and the daily totals {d.keep.daily_days} days. What a visit led to is worked out 30 minutes after it ends.</p>

      <form className="vs-filters" action="/admin/visitors" method="get" role="search" aria-label="Filter the visits" data-testid="vh-filters">
        <input type="hidden" name="view" value="history" />
        <div className="field"><label className="label" htmlFor="vh-from">From</label><input className="input" id="vh-from" name="from" type="date" defaultValue={d.from} min={d.oldest} max={d.to} /></div>
        <div className="field"><label className="label" htmlFor="vh-to">To</label><input className="input" id="vh-to" name="to" type="date" defaultValue={d.to} min={d.oldest} /></div>
        <div className="field"><label className="label" htmlFor="vh-converted">Led to</label>
          <select className="select" id="vh-converted" name="converted" defaultValue={v('converted')}>
            <option value="">Anything or nothing</option><option value="any">Any conversion</option><option value="request">A request sent</option><option value="booking">A booking confirmed</option>
            <option value="signup">An account opened</option><option value="contact">Contact details given</option><option value="none">Nothing</option></select></div>
        <div className="field"><label className="label" htmlFor="vh-city">City</label><input className="input" id="vh-city" name="city" defaultValue={v('city')} placeholder="Toronto" /></div>
        <div className="field"><label className="label" htmlFor="vh-source">Source or campaign</label><input className="input" id="vh-source" name="source" defaultValue={v('source')} placeholder="google, newsletter" /></div>
        <details className="vs-more" open={more}>
          <summary>More filters</summary>
          <div className="vs-more__in">
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
        <div className="vs-filters__go"><button className="btn btn--primary btn--sm" type="submit" data-testid="vh-apply">Show visits</button>
          {d.filtered || f.from || f.to ? <Link prefetch={false} className="link small" href="/admin/visitors?view=history">Clear the filters</Link> : null}</div>
      </form>

      {first && s && tot && (
        <details className="vs-sum" open>
          <summary>Totals and day by day <span className="muted">({d.from === d.to ? d.from : `${d.from} to ${d.to}`}, all visits in the dates)</span></summary>
          <Tiles items={[
            { k: 'Visits', v: tot.visits.toLocaleString('en-US'), sub: tot.left_out ? `${tot.left_out.toLocaleString('en-US')} bots and staff left out` : undefined },
            { k: 'Unique visitors', v: (s.visitors ?? tot.visitor_days).toLocaleString('en-US'), sub: s.visitors === null ? 'added up day by day (over 3 months)' : undefined },
            { k: 'Converted', v: tot.converted.toLocaleString('en-US'), sub: [pct(tot.converted, tot.visits), `${tot.requests} requests, ${tot.bookings} bookings, ${tot.signups} accounts, ${tot.contacts} contacts`].filter(Boolean).join(' · ') },
            { k: 'Returning', v: pct(tot.returning_visits, tot.visits) || '0%', sub: `${tot.known_visits.toLocaleString('en-US')} known customers` },
            { k: 'Pages a visit', v: tot.visits ? (Math.round((tot.page_views * 10) / tot.visits) / 10).toLocaleString('en-US') : '0', sub: tot.visits ? `${pct(tot.bounces, tot.visits)} saw one page` : undefined },
            { k: 'Average visit', v: duration(tot.visits ? tot.seconds / tot.visits : 0), sub: `${pct(tot.phone, tot.visits) || '0%'} on a phone` }
          ]} />
          <div className="vs-chart" data-testid="vh-daily"><VisitChart days={s.days} at={s.computed_at} /></div>
          <div className="vh-tops">
            <Top title="Top pages" rows={s.top.page} words={(r) => `${r.label ?? r.key} (${r.key})`} testId="vh-top-pages" />
            <Top title="Top sources" rows={s.top.source} words={(r) => topSourceWords(r.key)} testId="vh-top-sources" />
            <Top title="Top landing pages" rows={s.top.landing} words={(r) => (r.key === '(not recorded)' ? 'Not recorded' : `${r.label ?? r.key} (${r.key})`)} testId="vh-top-landing" />
            <Top title="Countries" rows={s.top.country} words={(r) => (r.key === '--' ? 'Not known' : r.key)} testId="vh-top-countries" />
          </div>
        </details>
      )}

      <h2 className="vs-h">Visits <span className="muted">{d.from === d.to ? d.from : `${d.from} to ${d.to}`}, newest first</span></h2>
      {!d.rows.length ? <p className="vs-empty">{d.filtered ? 'No visits match. Clear a filter or widen the dates.' : 'No visits in these dates.'}</p> : (
        <ul className="vs-cards" data-testid="vh-table" aria-label="Visits">
          {d.rows.map((r) => {
            const k = kindOf(r), where = [r.device ? DEVICE_WORDS[r.device] : null, place(r)].filter(Boolean).join(' · ');
            return (
              <li key={r.id} className={`vs-card vs-card--${k.key}`} data-testid="vh-row">
                <HistoryLocate id={r.id} renter={r.renter_id} who={r.who} kind={k.key}><VsIcon kind={k.key} /></HistoryLocate>
                <div className="vs-card__main">
                  <div className="vs-card__top">
                    <b className="vs-card__who">{r.who}</b>
                    <span className={`vs-chip vs-chip--${k.key}`}>{k.label}</span>
                    {r.returning && k.key !== 'visitor' ? <span className="vs-chip">Visit {r.visit_number}</span> : null}
                    {r.has_contact && !r.conversions.includes('contact') ? <span className="vs-chip">Contact on file</span> : null}
                  </div>
                  <p className="vs-card__line">{sourceWords(r)}{where ? ` · ${where}` : ''}</p>
                  <p className="vs-card__line muted">{r.landing ?? 'Landing page not recorded'}{r.exit && r.exit_path !== r.landing_path ? ` to ${r.exit}` : ''}
                    {' · '}{r.page_views} page{r.page_views === 1 ? '' : 's'}{r.cars_viewed ? `, ${r.cars_viewed} car${r.cars_viewed === 1 ? '' : 's'}` : ''} · {duration(r.duration_s)}</p>
                  {r.conversions.length > 1 && <p className="vs-tags">{r.conversions.filter((c) => c !== k.key).map((c) => <span key={c} className="vs-chip vs-chip--dark">{CONVERSION_WORDS[c]}</span>)}</p>}
                  {!r.summarized && <p className="small muted">What it led to is worked out after the visit.</p>}
                </div>
                <div className="vs-card__side">
                  <time className="small muted" dateTime={r.started_at}>{t(r.started_at)}</time>
                  <Link prefetch={false} className="btn btn--ghost btn--sm" href={`/admin/live/history/${r.id}`} data-testid="vh-open">Open the visit</Link>
                </div>
              </li>
            );
          })}
        </ul>
      )}
      <div className="vh-more">
        {d.next && <Link prefetch={false} className="btn btn--ghost btn--sm" href={historyHref(f, d.next)} data-testid="vh-next">Older visits</Link>}
        {!first && <Link prefetch={false} className="link small" href={historyHref(f)}>Back to the newest</Link>}
        <span className="small muted">{d.rows.length} shown, {d.limit} a page</span>
      </div>
    </div>
  );
}
