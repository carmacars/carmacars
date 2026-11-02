import Link from '@/components/Link';
import { door } from '@/server/door';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';

type Row = { id: string; return_month: string; opening_invested_cents: number; days_earning: number; days_in_month: number; return_cents: number; disposition: string; payment_date: string; status: string };

// Documents > Statements: one row per Return Month (07-investor.md section 2), the yearly downloads under it.
export async function StatementsTab({ userId }: { userId: string }) {
  const user = { id: userId };
  const [rows, home] = await Promise.all([door<Row[]>(user.id, 'investor_read', 'statements'), door<{ investor: { id: string } }>(user.id, 'investor_read', 'home')]);
  const years = await door<Array<{ key: string; title: string; year: number }>>(user.id, 'ops_read', 'files', { for: 'investor', id: home.investor.id });
  const month = (s: string) => new Intl.DateTimeFormat('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${s}T12:00:00Z`));
  return (
    <div className="stack">
      <p className="ph__purpose">Your Return each month, paid or reinvested. Open a month for its statement, or download a year.</p>
      {!rows.length ? <div className="pt-empty" data-testid="statements-empty"><p className="d4">No statements yet</p><p className="muted">Your first statement appears after your first Return Month, which starts when the lockup ends.</p></div> : (
        <div className="table-scroll" tabIndex={0} role="region" aria-label="Statements">
          <table className="pt-table ad-table--cards" role="table" data-testid="statements"><thead role="rowgroup"><tr role="row"><th scope="col">Return Month</th><th scope="col">Invested Amount</th><th scope="col">Days</th><th scope="col" className="num">Return</th><th scope="col">Paid or reinvested</th><th scope="col">Payment Date</th><th scope="col">Status</th></tr></thead>
            <tbody role="rowgroup">{rows.map((r) => <tr key={r.id} role="row"><td role="cell" data-label="Return Month"><Link className="link" href={`/investor/statements/${r.id}`}>{month(r.return_month)}</Link> <a className="link small" href={`/files/investor_statement/${r.id}`} aria-label={`PDF for ${month(r.return_month)}`}>PDF</a></td><td role="cell" data-label="Invested Amount">{money(r.opening_invested_cents, { cents: true })}</td><td role="cell" data-label="Days">{r.days_earning} of {r.days_in_month}</td>
              <td role="cell" data-label="Return" className="num">{money(r.return_cents, { cents: true })}</td><td role="cell" data-label="Paid or reinvested">{r.disposition === 'reinvest' ? 'Reinvested' : 'Paid'}</td><td role="cell" data-label="Payment Date">{when(`${r.payment_date}T12:00:00Z`, false)}</td><td role="cell" data-label="Status">{r.status.replace(/_/g, ' ')}</td></tr>)}</tbody></table>
        </div>)}
      {rows.length > 0 && <section className="stack" aria-labelledby="iv-all"><h2 className="d4" id="iv-all">Download a year</h2>
        <ul className="pt-links" data-testid="year-downloads">{[...new Set(rows.map((r) => r.return_month.slice(0, 4)))].sort().reverse().map((y) => (
          <li key={y}><a className="link" href={`/investor/statements/year/${y}`} data-testid={`year-zip-${y}`}>All {y} statements (ZIP)</a> · <a className="link" href={`/investor/statements/year/${y}?format=csv`}>{y} summary table (CSV)</a></li>))}</ul></section>}
      {years.length > 0 && <section className="stack" aria-labelledby="iv-years"><h2 className="d4" id="iv-years">Yearly summaries</h2>
        <ul className="pt-links" data-testid="yearly">{years.map((y) => <li key={y.key}><a className="link" href={`/files/investor_year/${encodeURIComponent(y.key)}`}>{y.title} (PDF)</a></li>)}</ul></section>}
    </div>
  );
}
