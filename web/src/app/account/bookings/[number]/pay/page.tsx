import Link from 'next/link';
import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { bookingPath, carName } from '@/features/portal/status';
import { Back, PriceBreakdown } from '@/features/portal/Blocks';
import { PayForm } from '@/features/portal/PayForm';
import { myBooking } from '@/server/portal/data';
import { rpc } from '@/lib/db/repo';
import { PUSH_BACK } from '@/server/portal/payment';
import { ReceiptEmail } from '@/features/portal/ReceiptEmail';
import { accountGate, GATE_MESSAGE } from '@/server/sign-in-settings';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Pay for your booking', path: '/account/bookings', noindex: true, description: 'Pay to confirm your booking.' });

// Pay (02 section 6): the lines as stored, the deposit rule, and the card form.
export default async function PayPage({ params }: { params: Promise<{ number: string }> }) {
  const { b, user } = await myBooking((await params).number, 'pay');
  // a rental added while already underway with a payment link (0074) is paid here after signing, on trip
  const live = !!b.link_due;
  if (!live && ['confirmed', 'on_rent', 'returned', 'closed'].includes(b.status)) redirect(bookingPath(b.booking_number));
  if (b.status === 'offered') redirect(bookingPath(b.booking_number, 'offer'));
  if ((b.status === 'pending_payment' || live) && !b.agreement?.renter_signed_at) redirect(bookingPath(b.booking_number, 'sign'));
  // 0093: a car marked "no credit card needed" takes a debit card
  const debitOk = (await rpc('vehicle_takes_debit', { p_vehicle: b.vehicle_id }, { role: 'service_role' }).catch(() => false)) === true;
  const pushedBack = b.status === 'requested' && b.offers[b.offers.length - 1]?.status === 'withdrawn';
  // a confirmed account, and an email for the receipts before the first payment (0091)
  const gate = await accountGate(user.id, 'pay');
  // paid another way (0129): staff agreed e-Transfer, cash, a platform or the insurer; no card form, the way to pay instead
  const offline = (await rpc('renter_offline_pay_facts', { p_booking: b.id }, { role: 'service_role' }).catch(() => null)) as unknown as { rental_pay_method: string; deposit_pay_method: string; e_transfer_email: string | null; open_cents: number } | null;
  const payOffline = !!offline && offline.rental_pay_method !== 'card' && b.status === 'pending_payment' && !live;
  return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <header className="stack">
        <p className="pt-kicker">{live ? 'Your rental' : 'Step 3 of 3 · Pay'}</p>
        <h1 className="d2">{live ? 'Pay for your rental' : 'Pay to confirm'}</h1>
        <p className="muted">{carName(b)}, {when(b.pickup_at)} to {when(b.return_at)}</p>
      </header>
      {b.status !== 'pending_payment' && !live ? (
        <div className="pt-card pt-card--next" role="alert" data-testid="pay-pushed-back">
          <h2 className="d4">{pushedBack ? 'This car was just taken' : 'Nothing to pay'}</h2>
          <p>{pushedBack ? PUSH_BACK : 'This booking is not waiting for payment.'}</p>
          <p><Link prefetch={false} className="btn btn--primary" href={bookingPath(b.booking_number)}>Back to the booking</Link></p>
        </div>
      ) : (
        <div className="pt-split">
          {payOffline && offline ? (
          <section className="pt-card stack" aria-labelledby="pt-pay" data-testid="pay-offline"><h2 className="d4" id="pt-pay">How you pay</h2>
            {offline.rental_pay_method === 'e_transfer' ? <><p>Send an Interac e-Transfer of <b>{money(offline.open_cents, { cents: true })}</b> to <b>{offline.e_transfer_email}</b>, with <b>{b.booking_number}</b> as the message.</p><p className="small">We confirm your booking as soon as it arrives, by email.</p></>
              : offline.rental_pay_method === 'cash' ? <p>Pay <b>{money(offline.open_cents, { cents: true })}</b> in cash, as agreed with our team. We confirm your booking when it is received.</p>
              : offline.rental_pay_method === 'insurer' ? <p>Your insurer is billed for this rental: nothing to pay now. We confirm your booking shortly.</p>
              : offline.rental_pay_method === 'platform_payout' ? <p>This rental is paid on the platform you booked through: nothing to pay here. We confirm your booking shortly.</p>
              : <p>Pay <b>{money(offline.open_cents, { cents: true })}</b> as agreed with our team ({offline.rental_pay_method.replace(/_/g, ' ')}). We confirm your booking when it is received.</p>}
            <p className="small">{offline.deposit_pay_method === 'card' ? `The refundable deposit of ${money(b.deposit_cents)} is held on your credit card at pickup.` : offline.deposit_pay_method === 'none' ? 'No deposit on this booking.' : `The refundable deposit of ${money(b.deposit_cents)} is paid ${offline.deposit_pay_method === 'cash' ? 'in cash' : 'by e-Transfer'} and given back the same way.`}</p>
          </section>
          ) : (
          <section className="pt-card" aria-labelledby="pt-pay"><h2 className="d4" id="pt-pay">Card</h2>
            {gate.ok ? <PayForm number={b.booking_number} amountCents={b.renter_due_at_booking_cents} depositCents={b.deposit_cents} coverageOption={b.coverage_option} debitOk={debitOk} />
              : gate.reason === 'email_needed' ? <ReceiptEmail path={bookingPath(b.booking_number, 'pay')} />
              : <p className="alert alert--error" role="alert" data-testid="pay-unconfirmed"><span>{GATE_MESSAGE} <Link prefetch={false} className="link" href="/account/profile">Profile</Link></span></p>}
          </section>)}
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
