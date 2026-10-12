import { pageMeta } from '@/features/seo/meta';
import { Dl } from '@/features/portal/Blocks';
import { day } from '@/features/owner/Blocks';
import { PayoutForm } from '@/features/owner/OwnerForms';
import { requireOwner } from '@/server/owner/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Banking', path: '/owner/banking', noindex: true, description: 'Where we pay you, and how your fees are paid.' });

export default async function OwnerBanking() {
  const { home } = await requireOwner('/owner/banking');
  const current = home.payout_accounts.find((a) => a.is_current);
  const waiting = home.payout_accounts.filter((a) => !a.verified_at);
  const label = (a: (typeof home.payout_accounts)[number]) => (a.method === 'e_transfer' ? `e-Transfer to ${a.e_transfer_email}` : `Bank account ending ${a.account_last4}`);
  return (
    <>
      <h1 className="d2">Banking</h1>
      <div className="pt-split">
        <section className="pt-card" aria-labelledby="ow-payout"><h2 className="d4" id="ow-payout">Where we pay you</h2>
          {current ? <Dl rows={[['In use', label(current)], ['Verified', current.verified_at ? day(current.verified_at) : '']]} /> : <p className="small muted">No payout account in use yet.</p>}
          {waiting.map((a) => <p key={a.id} className="pt-note" data-testid="payout-verifying">{label(a)}: being verified (submitted {day(a.submitted_at)}).</p>)}
          <PayoutForm />
        </section>
        <aside className="pt-split__aside">
          <section className="pt-card" aria-labelledby="ow-pm"><h2 className="d4" id="ow-pm">How your fees are paid</h2>
            {home.payment_methods.length ? <Dl rows={home.payment_methods.map((m) => [m.kind === 'card' ? 'Card' : 'Pre-authorized debit', `${m.brand_or_bank ?? ''} ending ${m.last4 ?? ''}${m.is_default ? ', default' : ''}`.trim()])} />
              : <p className="small muted">Set up when you pay your first invoice by card or pre-authorized debit.</p>}
            <p className="small muted">Fees are charged on the 15th of each month by pre-authorized debit. To change the account, pay your next invoice with the new one, or call us.</p>
          </section>
        </aside>
      </div>
    </>
  );
}
