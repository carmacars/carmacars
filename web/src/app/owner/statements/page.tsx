import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { money } from '@/lib/format';
import { day, monthOf } from '@/features/owner/Blocks';
import { ownerMonthToDate, requireOwner } from '@/server/owner/data';
import { BarChart, DocumentList, DocumentRow, StatCard } from '@/components/portal-ui';
import { MonthToDate } from '@/features/owner/MonthToDate';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Statements', path: '/owner/statements', noindex: true, description: 'Your monthly statements.' });

export default async function OwnerStatements() {
  const { user, home } = await requireOwner('/owner/statements');
  const chart = home.statements.slice(0, 12).reverse();
  const year = new Date().toISOString().slice(0, 4);
  const mtd = await ownerMonthToDate(user);
  return (
    <>
      <PageHeader title="Statements" purpose={`One statement a month with the booking behind every number. Paid out on the ${home.auto_debit.terms.payout_day_text} for the month before.`} />
      <MonthToDate m={mtd} />
      {home.statements.length ? (
        <>
          <div className="pu-grid-2 pu-grid-2--wide">
            <section className="pu-panel" aria-labelledby="ow-st-chart"><div className="pu-panel__head"><h2 className="pu-title" id="ow-st-chart">Payouts by statement month</h2></div>
              <BarChart testId="statements-chart" title="Payouts by statement month" selected={chart[chart.length - 1]?.id}
                bars={chart.map((s) => ({ key: s.id, label: monthOf(s.statement_month), short: new Intl.DateTimeFormat('en-CA', { month: 'short', timeZone: 'UTC' }).format(new Date(`${s.statement_month.slice(0, 10)}T12:00:00Z`)).replace('.', ''), value: s.payout_cents, display: money(s.payout_cents) }))} />
            </section>
            <div className="pu-stats ow-st-stats">
              <StatCard card label={`Paid out in ${year}`} value={home.statements.filter((s) => s.status === 'paid' && s.payout_date.startsWith(year)).reduce((t, s) => t + s.payout_cents, 0)} format="cents" />
              <StatCard card label="Latest statement" value={home.statements[0]!.payout_cents} format="cents" sub={monthOf(home.statements[0]!.statement_month)} />
            </div>
          </div>
          <DocumentList testId="owner-statements" label="Statements">{home.statements.map((s) => (
            <DocumentRow key={s.id} href={`/owner/statements/${s.id}`} badge="ST" title={monthOf(s.statement_month)}
              meta={<><span>{s.statement_number}</span><span>Payout {day(s.payout_date)}</span></>} amount={money(s.payout_cents, { cents: true })}
              status={<span className={`badge ${s.status === 'paid' ? '' : 'badge--outline'}`}>{s.status === 'paid' ? 'Paid' : 'Approved'}</span>} />))}
          </DocumentList>
        </>
      ) : <p className="pt-empty muted">Your first approved statement appears here after the month ends; the month so far is above. Payouts are made on the {home.auto_debit.terms.payout_day_text}.</p>}
    </>
  );
}
