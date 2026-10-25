import { pageMeta } from '@/features/seo/meta';
import { More, PageHeader } from '@/features/portal/Chrome';
import { money } from '@/lib/format';
import { day } from '@/features/owner/Blocks';
import { requireOwner } from '@/server/owner/data';
import { nextPayout } from '@/features/owner/insights';
import { StatCard, Timeline, TimelineItem } from '@/components/portal-ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Payouts', path: '/owner/payouts', noindex: true, description: 'Payouts to you.' });

const STATUS: Record<string, string> = { draft: 'Being prepared', pending_approval: 'Being prepared', approved: 'Approved', sent: 'Sent', paid: 'Paid', failed: 'Failed, we will contact you', cancelled: 'Cancelled' };

export default async function OwnerPayouts() {
  const { home } = await requireOwner('/owner/payouts');
  const np = nextPayout(home);
  return (
    <>
      <PageHeader title="Payouts" purpose={`Money we sent you. Next payout date: ${day(home.next_payout_date)}.`} />
      <More summary="When and how we pay you"><p className="small muted">Paid on the {home.auto_debit.terms.payout_day_text} of each month for the month before, by bank transfer to your account on file (Account &gt; Banking).</p></More>
      <div className="pu-stats ow-pay-stats">
        <StatCard card label="Paid to you to date" value={home.payouts.filter((p) => p.status === 'paid').reduce((t, p) => t + p.amount_cents, 0)} format="cents" testId="owner-paid-to-date" />
        <StatCard card label="Next payout" value={np.cents ?? day(np.date)} format="cents" sub={np.cents !== null ? `On ${day(np.date)}` : 'Amount on your statement'} />
      </div>
      {home.payouts.length ? (
        <section className="pu-panel" aria-labelledby="ow-pay-list"><h2 className="pu-title" id="ow-pay-list">Every payout</h2>
          <Timeline label="Payouts" testId="owner-payouts">{home.payouts.map((p) => (
            <TimelineItem key={p.id} date={p.scheduled_for} dateLabel={day(p.scheduled_for)} state={p.status === 'paid' ? 'done' : p.status === 'failed' ? 'now' : 'future'}
              title={p.kind === 'owner_statement' ? 'Monthly payout' : p.kind.replace(/_/g, ' ')} amount={money(p.amount_cents, { cents: true })}
              meta={<><span>{p.method.replace('_', ' ')}</span><span>{STATUS[p.status] ?? p.status}</span></>} />))}
          </Timeline>
        </section>)
        : <p className="pt-empty muted">No payouts yet.</p>}
    </>
  );
}
