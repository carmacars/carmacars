import '@/styles/portal.css';
import { pageMeta } from '@/features/seo/meta';
import { when } from '@/features/agreement/model';
import { money } from '@/lib/format';
import { markPayLinkOpened, payLinkFacts } from '@/server/paylink';
import { PayLinkForm } from '@/features/money/PayLinkForm';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Pay securely', path: '/pay', noindex: true, description: 'Pay CarmaCars by card for your booking.' });

const WHAT: Record<string, string> = { rental: 'the rental', fees: 'the fees', later: 'a charge on your booking', deposit: 'the refundable deposit', card: 'your card on file' };

// A card payment staff started for a booking (0129): the renter, on their phone or on the staff device handed to them,
// types the card in Stripe's frame. No account needed: the link is the key, valid for a few days (two hours on a device).
export default async function PayLink({ params, searchParams }: { params: Promise<{ token: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const token = (await params).token;
  // the staff page to go back to on a device handed to the renter (only a staff address)
  const back = (await searchParams).back;
  const backTo = back && /^\/(field|admin|va|account)\/[\w/-]*$/.test(back) ? back : null;
  const f = await payLinkFacts(token);
  if (f?.status === 'open') await markPayLinkOpened(token);
  if (!f || f.status !== 'open') return (
    <div className="pt"><div className="wrap pt__body stack" style={{ maxWidth: '36rem' }} data-testid="paylink-closed">
      <h1 className="d2">{f?.status === 'paid' ? 'Paid, thank you' : 'This link is no longer open'}</h1>
      <p>{f?.status === 'paid' ? 'We have it. Your receipt is in your email.' : 'Pay links work for a few days and only once. Ask us for a new one, or call us.'}</p>
    </div></div>
  );
  return (
    <div className="pt"><div className="wrap pt__body stack" style={{ maxWidth: '36rem' }}>
      <header className="stack">
        <p className="pt-kicker">Booking {f.booking_number}</p>
        <h1 className="d2">{f.kind === 'hold' ? 'Deposit hold' : f.kind === 'setup' ? 'Save your card' : `Pay ${money(f.amount_cents, { cents: true })}`}</h1>
        <p className="muted">{f.vehicle_name}, {when(f.pickup_at)} to {when(f.return_at)}</p>
      </header>
      <section className="pt-card stack" aria-labelledby="pl-what">
        <h2 className="d4" id="pl-what">What this is</h2>
        <p data-testid="paylink-what">{f.kind === 'hold'
          ? `A hold of ${money(f.amount_cents, { cents: true })} for ${WHAT.deposit}. Nothing is charged now: the hold is released after the rental, unless a charge in your agreement applies. A hold lasts about ${f.hold_days} days.`
          : f.kind === 'setup' ? 'Your card is saved for the deposit and the later charges you agreed to in your rental agreement. Nothing is charged now.'
          : `${money(f.amount_cents, { cents: true })} for ${f.reason ? f.reason.toLowerCase() : WHAT[f.covers] ?? 'your booking'}.`}</p>
        <PayLinkForm token={token} kind={f.kind} amountCents={f.amount_cents} legalName={f.renter_name} backTo={backTo} />
      </section>
      <p className="small muted">The card is entered in Stripe&apos;s secure form. CarmaCars never sees or keeps the card number.</p>
    </div></div>
  );
}
