import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { day, monthOf } from '@/features/owner/Blocks';
import { requireOwner } from '@/server/owner/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Statements', path: '/owner/statements', noindex: true, description: 'Your monthly statements.' });

export default async function OwnerStatements() {
  const { home } = await requireOwner('/owner/statements');
  return (
    <>
      <header className="stack"><h1 className="d2">Statements</h1><p className="muted">One statement a month, with a block per vehicle and the booking behind every number. Payouts are made on the 10th for the month before.</p></header>
      {home.statements.length ? (
        <ul className="ow-rows">{home.statements.map((s) => <li key={s.id}><Link className="ow-row-link" href={`/owner/statements/${s.id}`}>{monthOf(s.statement_month)} · {s.statement_number}</Link><span className="ow-amount">{money(s.payout_cents, { cents: true })}</span><span className="ow-meta"><span>Payout {day(s.payout_date)}</span><span className={`badge ${s.status === 'paid' ? '' : 'badge--outline'}`}>{s.status === 'paid' ? 'Paid' : 'Approved'}</span></span></li>)}</ul>
      ) : <p className="pt-empty muted">Your first statement appears here once a month with rentals is approved. Payouts are made on the 10th.</p>}
    </>
  );
}
