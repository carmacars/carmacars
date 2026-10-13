import Link from 'next/link';
import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { when } from '@/features/agreement/model';
import { bookingPath, carName } from '@/features/portal/status';
import { Back, PriceBreakdown } from '@/features/portal/Blocks';
import { PayForm } from '@/features/portal/PayForm';
import { myBooking } from '@/server/portal/data';
import { PUSH_BACK } from '@/server/portal/payment';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Pay for your booking', path: '/account/bookings', noindex: true, description: 'Pay to confirm your booking.' });

// Pay (02 section 6): the lines as stored, the deposit rule, and the card form.
export default async function PayPage({ params }: { params: Promise<{ number: string }> }) {
  const { b } = await myBooking((await params).number, 'pay');
  if (['confirmed', 'on_rent', 'returned', 'closed'].includes(b.status)) redirect(bookingPath(b.booking_number));
  if (b.status === 'offered') redirect(bookingPath(b.booking_number, 'offer'));
  if (b.status === 'pending_payment' && !b.agreement?.renter_signed_at) redirect(bookingPath(b.booking_number, 'sign'));
  const pushedBack = b.status === 'requested' && b.offers[b.offers.length - 1]?.status === 'withdrawn';
  return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <header className="stack">
        <p className="pt-kicker">Step 3 of 3 · Pay</p>
        <h1 className="d2">Pay to confirm</h1>
        <p className="muted">{carName(b)}, {when(b.pickup_at)} to {when(b.return_at)}</p>
      </header>
      {b.status !== 'pending_payment' ? (
        <div className="pt-card pt-card--next" role="alert" data-testid="pay-pushed-back">
          <h2 className="d4">{pushedBack ? 'This car was just taken' : 'Nothing to pay'}</h2>
          <p>{pushedBack ? PUSH_BACK : 'This booking is not waiting for payment.'}</p>
          <p><Link prefetch={false} className="btn btn--primary" href={bookingPath(b.booking_number)}>Back to the booking</Link></p>
        </div>
      ) : (
        <div className="pt-split">
          <section className="pt-card" aria-labelledby="pt-pay"><h2 className="d4" id="pt-pay">Card</h2>
            <PayForm number={b.booking_number} amountCents={b.renter_due_at_booking_cents} depositCents={b.deposit_cents} />
          </section>
          <aside className="pt-split__aside pt-first">
            <section className="pt-card" aria-labelledby="pt-sum"><h2 className="d4" id="pt-sum">What you pay now</h2>
              <PriceBreakdown lines={b.lines.filter((l) => l.stage === 'booking')} hst={b.hst_at_booking_cents} total={b.renter_due_at_booking_cents} insurer={b.insurer_pays_cents || undefined} deposit={b.deposit_cents} />
            </section>
          </aside>
        </div>
      )}
    </>
  );
}
