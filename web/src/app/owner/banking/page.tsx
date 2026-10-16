import { pageMeta } from '@/features/seo/meta';
import { Dl } from '@/features/portal/Blocks';
import { day } from '@/features/owner/Blocks';
import { PayoutForm } from '@/features/owner/OwnerForms';
import { DebitSetupForm } from '@/features/owner/DebitSetupForm';
import { MandateBlock } from '@/features/owner/OwnerPayForm';
import { money } from '@/lib/format';
import { requireOwner } from '@/server/owner/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Banking', path: '/owner/banking', noindex: true, description: 'Where we pay you, and how your fees are paid.' });

export default async function OwnerBanking() {
  const { home } = await requireOwner('/owner/banking');
  const current = home.payout_accounts.find((a) => a.is_current);
  const waiting = home.payout_accounts.filter((a) => !a.verified_at);
  const d = home.auto_debit;
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
          <section className="pt-card" aria-labelledby="ow-debit" data-testid="owner-auto-debit"><h2 className="d4" id="ow-debit">Automatic debit of your fees</h2>
            {d.mandate ? (
              <Dl rows={[['Bank account', `${d.bank ?? 'Account'} ending ${d.bank_last4 ?? ''}`.trim()],
                ['Next debit', d.next_debit_on ? `${money(d.next_debit_cents, { cents: true })} on ${day(d.next_debit_on)}` : `None scheduled. Notices go out on ${day(d.next_notice_on)} for the ${day(d.next_cycle_on)} debit.`],
                ...(d.processing_cents > 0 ? [['Processing', money(d.processing_cents, { cents: true })] as [string, string]] : []),
                ...(d.paused ? [['Status', 'Paused by CarmaCars. Pay your invoices from their page.'] as [string, string]] : [])]} />
            ) : d.pending_setup ? (
              <p className="pt-note" data-testid="debit-pending">Your bank account is being confirmed by Stripe with two small deposits. Follow the email from Stripe to finish; until then, pay your invoices from their page.</p>
            ) : (
              <p className="small" data-testid="debit-missing">Your fees are paid by pre-authorized debit on the {d.terms.debit_day_text} of each month. Set it up once and we debit each invoice on that day, with a notice {d.notice_days} days before.</p>
            )}
            {d.mandate && (
              <details className="ow-agreement" id="agreement" data-testid="pad-in-force"><summary className="link">The pre-authorized debit agreement you accepted</summary>
                <MandateBlock kind={home.owner.owner_type === 'corporation' ? 'business' : 'personal'} terms={d.terms} withInvoice={false} id="ow-inforce-h" />
                <p className="small muted">We emailed you a confirmation of it when your bank account was set up.</p>
              </details>
            )}
            {d.enabled && <DebitSetupForm ownerType={home.owner.owner_type} terms={d.terms} replace={d.mandate} holderName={home.owner.owner_type === 'corporation' ? (home.owner.corporation_name ?? home.owner.legal_name) : home.owner.legal_name} />}
          </section>
          <section className="pt-card" aria-labelledby="ow-pm"><h2 className="d4" id="ow-pm">Saved payment methods</h2>
            {home.payment_methods.length ? <Dl rows={home.payment_methods.map((m) => [m.kind === 'card' ? 'Card' : 'Pre-authorized debit', `${m.brand_or_bank ?? ''} ending ${m.last4 ?? ''}${m.is_default ? ', default' : ''}${m.status === 'pending' ? ', being confirmed' : ''}`.trim()])} />
              : <p className="small muted">None yet.</p>}
            <p className="small muted" data-testid="late-fee-rule">{d.terms.late_fee_rule} You can always pay an invoice by card from its page before its debit day.</p>
          </section>
        </aside>
      </div>
    </>
  );
}
