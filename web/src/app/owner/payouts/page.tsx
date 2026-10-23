import { pageMeta } from '@/features/seo/meta';
import { More, PageHeader } from '@/features/portal/Chrome';
import { money } from '@/lib/format';
import { day } from '@/features/owner/Blocks';
import { requireOwner } from '@/server/owner/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Payouts', path: '/owner/payouts', noindex: true, description: 'Payouts to you.' });

const STATUS: Record<string, string> = { draft: 'Being prepared', pending_approval: 'Being prepared', approved: 'Approved', sent: 'Sent', paid: 'Paid', failed: 'Failed, we will contact you', cancelled: 'Cancelled' };

export default async function OwnerPayouts() {
  const { home } = await requireOwner('/owner/payouts');
  return (
    <>
      <PageHeader title="Payouts" purpose={`Money we sent you. Next payout date: ${day(home.next_payout_date)}.`} />
      <More summary="When and how we pay you"><p className="small muted">Paid on the {home.auto_debit.terms.payout_day_text} of each month for the month before, by bank transfer to your account on file (Account &gt; Banking).</p></More>
      {home.payouts.length ? <ul className="ow-rows">{home.payouts.map((p) => <li key={p.id}><span>{p.kind === 'owner_statement' ? 'Monthly payout' : p.kind.replace(/_/g, ' ')}</span><span className="ow-amount">{money(p.amount_cents, { cents: true })}</span><span className="ow-meta"><span>{day(p.scheduled_for)}</span><span>{p.method.replace('_', ' ')}</span><span>{STATUS[p.status] ?? p.status}</span></span></li>)}</ul>
        : <p className="pt-empty muted">No payouts yet.</p>}
    </>
  );
}
