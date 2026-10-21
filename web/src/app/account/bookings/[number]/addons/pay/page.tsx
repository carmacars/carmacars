import { pageMeta } from '@/features/seo/meta';
import { when } from '@/features/agreement/model';
import { bookingPath, carName } from '@/features/portal/status';
import { Back } from '@/features/portal/Blocks';
import { AddonPayForm } from '@/features/addons/AddonPayForm';
import { money } from '@/lib/format';
import { myBooking } from '@/server/portal/data';
import { unpaidAddons } from '@/server/portal/addon-payment';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Pay for your add-ons', path: '/account/bookings', noindex: true, description: 'Pay for the add-ons on your booking.' });

// Add-ons bought after booking with no card on file (migration 0079): what is due, and the card form.
export default async function AddonPayPage({ params }: { params: Promise<{ number: string }> }) {
  const { user, b } = await myBooking((await params).number, 'addons/pay');
  const u = await unpaidAddons(b.id, user.id);
  return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <header className="stack">
        <p className="pt-kicker">Your add-ons</p>
        <h1 className="d2">Pay for your add-ons</h1>
        <p className="muted">{carName(b)}, {when(b.pickup_at)} to {when(b.return_at)}</p>
      </header>
      {u.total_cents <= 0 ? (
        <div className="pt-card pt-card--next" role="status" data-testid="addon-pay-nothing">
          <h2 className="d4">Nothing to pay</h2><p>Every add-on on this booking is paid.</p>
          <p><a className="btn btn--primary" href={bookingPath(b.booking_number)}>Back to the booking</a></p>
        </div>
      ) : (
        <div className="pt-split">
          <section className="pt-card" aria-labelledby="ap-card"><h2 className="d4" id="ap-card">Card</h2>
            <AddonPayForm number={b.booking_number} amountCents={u.total_cents} />
          </section>
          <aside className="pt-split__aside pt-first">
            <section className="pt-card" aria-labelledby="ap-sum" data-testid="addon-pay-summary"><h2 className="d4" id="ap-sum">What you pay now</h2>
              <ul className="pt-list">{u.items.map((i) => <li key={i.booking_addon_id} className="pt-card__head"><span>{i.name}</span><span className="num">{money(i.total_cents, { cents: true })}</span></li>)}</ul>
              <p className="pt-card__head"><b>Total, HST included</b><b className="num">{money(u.total_cents, { cents: true })}</b></p>
            </section>
          </aside>
        </div>
      )}
    </>
  );
}
