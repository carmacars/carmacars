import Link from '@/components/Link';
import './sales-leads.css';
import { Filters } from '@/features/admin/ui';
import { minutes, pct, type CallTeam, type Dashboard, type Figures } from './model';

const PERIODS: Array<['today' | 'week' | 'month', string]> = [['today', 'Today'], ['week', 'This week'], ['month', 'This month']];

function Tiles({ f, testId }: { f: Figures; testId: string }) {
  const items: Array<[string, string]> = [['Leads claimed', String(f.claimed)], ['Won', String(f.won)], ['Close rate', pct(f.close_rate, f.claimed)],
    ['Contacted', pct(f.contacted_pct, f.claimed)], ['First contact in', minutes(f.first_contact_minutes)], ['Claims that ran out', String(f.expired)]];
  return <div className="sl-dash" data-testid={testId}>{items.map(([k, v]) => <div key={k} className="sl-dash__tile"><span className="small muted">{k}</span><b>{v}</b></div>)}</div>;
}

/** A salesperson's own numbers (their home and the lead list): claimed, won, close rate = won / claimed, contacted %,
 *  average time from claim to first contact, claims that ran out; today, this week, this month. */
export function SalesDashboard({ d, base }: { d: Dashboard; base: string }) {
  return (
    <section className="va-section pu-panel" aria-labelledby="sl-dash-h" data-testid="sales-dashboard">
      <div className="va-section__head"><h2 className="va-section__title" id="sl-dash-h">My leads</h2>
        <p className="va-section__note">{d.active} claimed now of {d.max_active} · {d.open_pool} open in the pool · <Link prefetch={false} className="link" href={base}>Open the lead list</Link></p></div>
      <h3 className="small">Today</h3><Tiles f={d.today} testId="sales-dash-today" />
      <details><summary className="small link">This week and this month</summary>
        {PERIODS.slice(1).map(([k, l]) => <div key={k} className="stack" style={{ gap: 'var(--s-2)', marginTop: 'var(--s-3)' }}><h3 className="small">{l}</h3><Tiles f={d[k]} testId={`sales-dash-${k}`} /></div>)}</details>
    </section>
  );
}

/** The Admin's team view: each person's numbers for the period and the leaderboard (won, then close rate). */
export function SalesTeam({ d, base, sp, calls }: { d: Dashboard; base: string; sp: Record<string, string | undefined>; calls?: CallTeam }) {
  const team = d.team ?? [];
  // r35 (0970): the minutes of connected calls made with the site's Call button this month, from my_call_minutes (an Admin gets the team)
  const mins = new Map((calls ?? []).map((c) => [c.user_id, c.month]));
  return (
    <section className="stack" data-testid="sales-team">
      <Filters base={base} name="period" value={d.period} sp={sp} options={PERIODS} />
      {team.length ? <div className="sl-table-wrap"><table className="table" data-testid="sales-leaderboard">
        <caption className="vh">Sales leaderboard</caption>
        <thead><tr><th scope="col">#</th><th scope="col">Person</th><th scope="col" className="num">Claimed</th><th scope="col" className="num">Won</th><th scope="col" className="num">Close rate</th>
          <th scope="col" className="num">Contacted</th><th scope="col" className="num">First contact</th><th scope="col" className="num">Ran out</th><th scope="col" className="num">Holding now</th>{calls && <th scope="col" className="num">Call minutes, this month</th>}</tr></thead>
        <tbody>{team.map((r) => <tr key={r.id}><td>{r.rank}</td><td>{r.name}</td><td className="num">{r.claimed}</td><td className="num">{r.won}</td><td className="num">{pct(r.close_rate, r.claimed)}</td>
          <td className="num">{pct(r.contacted_pct, r.claimed)}</td><td className="num">{minutes(r.first_contact_minutes)}</td><td className="num">{r.expired}</td><td className="num">{r.active}</td>{calls && <td className="num" data-testid={`sales-call-minutes-${r.id}`}>{(mins.get(r.id) ?? 0).toFixed(1)}</td>}</tr>)}</tbody>
      </table></div> : <p className="small muted">Nobody in Sales has claimed a lead yet.</p>}
    </section>
  );
}
