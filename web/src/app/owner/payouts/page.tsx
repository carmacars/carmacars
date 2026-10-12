import { pageMeta } from '@/features/seo/meta';
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
      <header className="stack"><h1 className="d2">Payouts</h1><p className="muted">Paid on the 10th of each month for the month before, by bank transfer to your account on file. Next payout date: {day(home.next_payout_date)}.</p></header>
      {home.payouts.length ? <ul className="ow-rows">{home.payouts.map((p) => <li key={p.id}><span>{p.kind === 'owner_statement' ? 'Monthly payout' : p.kind.replace(/_/g, ' ')}</span><span className="ow-amount">{money(p.amount_cents, { cents: true })}</span><span className="ow-meta"><span>{day(p.scheduled_for)}</span><span>{p.method.replace('_', ' ')}</span><span>{STATUS[p.status] ?? p.status}</span></span></li>)}</ul>
        : <p className="pt-empty muted">No payouts yet.</p>}
    </>
  );
}
