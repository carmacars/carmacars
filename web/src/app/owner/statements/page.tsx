import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { money } from '@/lib/format';
import { day, monthOf } from '@/features/owner/Blocks';
import { ownerMonthToDate, requireOwner } from '@/server/owner/data';
import { MonthToDate } from '@/features/owner/MonthToDate';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Statements', path: '/owner/statements', noindex: true, description: 'Your monthly statements.' });

export default async function OwnerStatements() {
  const { user, home } = await requireOwner('/owner/statements');
  const mtd = await ownerMonthToDate(user);
  return (
    <>
      <PageHeader title="Statements" purpose={`One statement a month with the booking behind every number. Paid out on the ${home.auto_debit.terms.payout_day_text} for the month before.`} />
      <MonthToDate m={mtd} />
      {home.statements.length ? (
        <ul className="ow-rows">{home.statements.map((s) => <li key={s.id}><Link prefetch={false} className="ow-row-link" href={`/owner/statements/${s.id}`}>{monthOf(s.statement_month)} · {s.statement_number}</Link><span className="ow-amount">{money(s.payout_cents, { cents: true })}</span><span className="ow-meta"><span>Payout {day(s.payout_date)}</span><span className={`badge ${s.status === 'paid' ? '' : 'badge--outline'}`}>{s.status === 'paid' ? 'Paid' : 'Approved'}</span></span></li>)}</ul>
      ) : <p className="pt-empty muted">Your first approved statement appears here after the month ends; the month so far is above. Payouts are made on the {home.auto_debit.terms.payout_day_text}.</p>}
    </>
  );
}
