import Link from 'next/link';
import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { getFacts } from '@/lib/site';
import { when } from '@/features/agreement/model';
import { bookingPath, carName, offerChanges } from '@/features/portal/status';
import { Back, Dl, PriceBreakdown, placeText } from '@/features/portal/Blocks';
import { Countdown } from '@/features/portal/Countdown';
import { OfferActions } from '@/features/portal/OfferActions';
import { myBooking } from '@/server/portal/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Review your offer', path: '/account/bookings', noindex: true, description: 'Review the offer for your booking request: price, changes and expiry.' });

// Review the offer (02 section 4): the current version, what changed as before and after, the price,
// the time left, and the rule that an offer does not hold the car.
export default async function OfferPage({ params }: { params: Promise<{ number: string }> }) {
  const { b } = await myBooking((await params).number, 'offer');
  if (b.status === 'pending_payment') redirect(bookingPath(b.booking_number, b.agreement?.renter_signed_at ? 'pay' : 'sign'));
  const o = b.offers.find((x) => x.version === b.current_offer_version);
  const last = b.offers[b.offers.length - 1];
  const f = await getFacts();
  const c = (f as unknown as { cancellation?: { grace_bps: number; early_bps: number; mid_bps: number; late_bps: number; grace_hours: number; early_hours: number; late_hours: number } }).cancellation;
  const pc = (bps: number) => `${bps / 100}%`;
  const tiers = c ? [
    `Within ${c.grace_hours} hours of booking, and ${c.early_hours} hours or more before pickup: ${pc(c.grace_bps)} back`,
    `${c.early_hours} hours or more before pickup: ${pc(c.early_bps)} back`,
    `${c.late_hours} to ${c.early_hours} hours before pickup: ${pc(c.mid_bps)} back`,
    `Less than ${c.late_hours} hours before pickup: ${c.late_bps ? pc(c.late_bps) : 'no refund'}`
  ] : [];
  if (b.status !== 'offered' || !o || o.status !== 'sent') {
    const taken = last?.status === 'withdrawn' && b.status === 'requested';
    return (
      <>
        <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
        <h1 className="d2">{b.status === 'expired' || last?.status === 'expired' ? 'This offer has expired' : taken ? 'This offer was withdrawn' : 'No offer to review'}</h1>
        <div className="pt-card pt-card--next">
          <p>{b.status === 'expired' || last?.status === 'expired' ? 'The offer was not approved in time. Call or message us and we will send it again.'
            : taken ? 'Someone else confirmed this car for these dates first, or we changed the terms. Nothing was charged. We will send you a new offer.'
            : b.status === 'requested' ? 'We are preparing your offer. It arrives by email and here.' : 'This booking has moved on from the offer.'}</p>
          <p><Link className="btn btn--primary" href={bookingPath(b.booking_number)}>Back to the booking</Link></p>
        </div>
      </>
    );
  }
  const changes = offerChanges(b);
  const lines = (o.line_items ?? []).filter((l) => l.amount_cents !== 0 || l.charge_type === 'rental_charge');
  const substituted = o.vehicle && b.request.vehicle && `${o.vehicle.make} ${o.vehicle.model}` !== `${b.request.vehicle.make} ${b.request.vehicle.model}`;
  return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      {o.expires_at && <Countdown until={o.expires_at} label={`Offer open until ${when(o.expires_at)}`} />}
      <div className="pt-split">
        <div className="stack-lg">
          <header className="stack">
            <p className="pt-kicker">Offer, version {o.version}</p>
            <h1 className="d2">Your offer for the {o.vehicle ? `${o.vehicle.year} ${o.vehicle.make} ${o.vehicle.model}` : carName(b)}</h1>
          </header>
          <p className="pt-note" data-testid="offer-hold-rule"><b>This offer does not hold the car.</b> The car is reserved for you only once you approve, sign and pay. If someone else confirms it first, we will offer you another.</p>
          {o.message && <section className="pt-card" aria-labelledby="pt-msg"><h2 className="d4" id="pt-msg">Message from our team</h2><p>{o.message}</p></section>}
          {changes.length > 0 && (
            <section className="pt-card" aria-labelledby="pt-chg" data-testid="offer-changes"><h2 className="d4" id="pt-chg">What changed from your {b.offers.length > 1 ? 'last offer' : 'request'}</h2>
              <ul className="pt-changes">{changes.map((c) => <li key={c.label}><span className="small muted">{c.label}</span><span><del>{c.before}</del> <span className="vh">changed to</span> <ins>{c.after}</ins></span></li>)}</ul>
              {substituted && <p className="small">We offer a similar car because the one you asked for is not available.</p>}
            </section>
          )}
          <section className="pt-card" aria-labelledby="pt-trip"><h2 className="d4" id="pt-trip">Trip</h2>
            <Dl rows={[
              ['Pickup', `${when(o.pickup_at)}, ${placeText(b.pickup_place, b.pickup_method, true)}`],
              ['Return', `${when(o.return_at)}, ${placeText(b.return_place, b.return_method, false)}`],
              ['Length', `${o.billable_days} days`],
              ['Rate', b.booking_type === 'non_refundable' ? 'Non-refundable (10% off the rental charge)' : 'Standard: cancel under our policy'],
              ['Deposit at pickup', money(o.deposit_cents)],
              ['Kilometres', b.km_allowance_total ? `${b.km_allowance_total} km included, then ${money(b.overage_cents_per_km, { cents: true })} per km` : '']
            ]} />
          </section>
          <section className="pt-card" aria-labelledby="pt-cancel"><h2 className="d4" id="pt-cancel">If you cancel</h2>
            {b.booking_type === 'non_refundable' ? <p>This booking is non-refundable once confirmed.</p>
              : <><ul>{tiers.map((t) => <li key={t}>{t}</li>)}</ul><p className="small"><Link className="link" href="/cancellation-policy">Cancellation policy</Link></p></>}
          </section>
        </div>
        <aside className="pt-split__aside stack-lg">
          <section className="pt-card" aria-labelledby="pt-price"><h2 className="d4" id="pt-price">Price</h2>
            <PriceBreakdown lines={lines} hst={o.hst_cents} total={o.renter_due_cents} totalLabel="Total due at booking" insurer={o.insurer_share_cents || undefined} deposit={o.deposit_cents} />
            <OfferActions number={b.booking_number} version={o.version} />
          </section>
        </aside>
      </div>
    </>
  );
}
