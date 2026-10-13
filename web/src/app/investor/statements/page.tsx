import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { door, requireInvestor } from '@/server/door';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Statements', path: '/investor/statements', noindex: true, description: 'Your monthly statements.' });

type Row = { id: string; return_month: string; opening_invested_cents: number; days_earning: number; days_in_month: number; return_cents: number; disposition: string; payment_date: string; status: string };

// One row per Return Month (07-investor.md section 2).
export default async function Statements() {
  const { user } = await requireInvestor('/investor/statements');
  const rows = await door<Row[]>(user.id, 'investor_read', 'statements');
  const month = (s: string) => new Intl.DateTimeFormat('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${s}T12:00:00Z`));
  return (
    <div className="stack">
      <h1 className="d2">Statements</h1>
      {!rows.length ? <p className="pt-empty">No statements yet.</p> : (
        <div className="table-scroll" tabIndex={0} role="region" aria-label="Statements">
          <table className="pt-table" data-testid="statements"><thead><tr><th scope="col">Return Month</th><th scope="col">Invested Amount</th><th scope="col">Days</th><th scope="col" className="num">Return</th><th scope="col">Paid or reinvested</th><th scope="col">Payment Date</th><th scope="col">Status</th></tr></thead>
            <tbody>{rows.map((r) => <tr key={r.id}><td><Link className="link" href={`/investor/statements/${r.id}`}>{month(r.return_month)}</Link></td><td>{money(r.opening_invested_cents, { cents: true })}</td><td>{r.days_earning} of {r.days_in_month}</td>
              <td className="num">{money(r.return_cents, { cents: true })}</td><td>{r.disposition === 'reinvest' ? 'Reinvested' : 'Paid'}</td><td>{when(`${r.payment_date}T12:00:00Z`, false)}</td><td>{r.status.replace(/_/g, ' ')}</td></tr>)}</tbody></table>
        </div>)}
    </div>
  );
}
