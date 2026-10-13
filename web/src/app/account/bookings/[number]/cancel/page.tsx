import Link from 'next/link';
import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { bookingPath } from '@/features/portal/status';
import { Back, Dl } from '@/features/portal/Blocks';
import { CancelForm } from '@/features/portal/SelfService';
import { Withdraw } from '@/features/portal/Withdraw';
import { cancellationPreview, myBooking } from '@/server/portal/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Cancel booking', path: '/account/bookings', noindex: true, description: 'See the refund that applies and cancel your booking.' });

const TIER: Record<string, string> = { within_24h_of_booking: 'Within 24 hours of booking, 48 hours or more before pickup', notice_48h_plus: '48 hours or more before pickup', notice_24_to_48h: '24 to 48 hours before pickup', under_24h_or_after_start: 'Less than 24 hours before pickup', non_refundable: 'Non-refundable booking', carmacars_cancelled: 'Cancelled by CarmaCars' };

// Cancel (02 section 7.4): the three times, the tier and the refund from public.my_cancellation_preview,
// then type to confirm. Before confirmation a request is withdrawn instead (no money has moved).
export default async function CancelPage({ params }: { params: Promise<{ number: string }> }) {
  const { user, b } = await myBooking((await params).number, 'cancel');
  if (['requested', 'offered', 'pending_payment'].includes(b.status)) return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <h1 className="d2">Withdraw your request</h1>
      <div className="pt-card"><p>This booking is not confirmed yet and no money has moved.</p><Withdraw number={b.booking_number} /></div>
    </>
  );
  if (b.status === 'cancelled') return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <div className="pt-ok" role="status"><h1 className="d3">Booking cancelled</h1>
        <p>{b.cancellation?.refund_cents ? `Your refund of ${money(b.cancellation.refund_cents, { cents: true })} is sent to your card within 10 business days.` : 'No refund applies to this cancellation.'}</p>
        <p><Link prefetch={false} className="btn btn--primary" href="/account">Your trips</Link></p></div>
    </>
  );
  if (b.status !== 'confirmed') redirect(bookingPath(b.booking_number));
  const p = await cancellationPreview(user, b.id);
  return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <h1 className="d2">Cancel booking</h1>
      <div className="pt-split">
        <section className="pt-card" aria-labelledby="pt-refund" data-testid="cancel-preview"><h2 className="d4" id="pt-refund">What you get back</h2>
          {p.non_refundable && <p className="alert alert--warn" role="note"><span>This booking is non-refundable.</span></p>}
          {!p.non_refundable && p.refund_cents === 0 && <p className="alert alert--warn" role="note"><span>No refund applies.</span></p>}
          <Dl rows={[
            ['Booked', when(p.booking_made_at)],
            ['Now', when(p.received_at)],
            ['Pickup', when(p.start_at)],
            ['Rule that applies', <span key="t" data-testid="cancel-tier" data-tier={p.tier}>{TIER[p.tier] ?? p.tier} ({p.refund_bps / 100}%)</span>],
            ['Paid', money(p.total_paid_cents, { cents: true })],
            ['Refund', <b key="r" data-testid="cancel-refund">{money(p.refund_cents, { cents: true })}</b>],
            ['Kept by CarmaCars', money(p.retained_cents, { cents: true })],
            ['Refund sent by', p.refund_due_by ? when(`${p.refund_due_by}T12:00:00Z`, false) : '']
          ]} />
          <p className="small muted">The deposit is taken at pickup, so none is held now. <Link prefetch={false} className="link" href="/cancellation-policy">Cancellation policy</Link></p>
        </section>
        <aside className="pt-split__aside"><section className="pt-card" aria-labelledby="pt-confirm"><h2 className="d4" id="pt-confirm">Confirm</h2>
          {p.can_cancel ? <CancelForm number={b.booking_number} /> : <p>{p.message ?? 'This booking cannot be cancelled online. Call us.'}</p>}
        </section></aside>
      </div>
    </>
  );
}
