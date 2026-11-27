import { pageMeta } from '@/features/seo/meta';
import { bookingPath } from '@/features/portal/status';
import { Back } from '@/features/portal/Blocks';
import { rpc } from '@/lib/db/repo';
import { myBooking } from '@/server/portal/data';
import { cardPayments } from '@/server/card-provider';
import { cardOn } from '@/features/money/card-pay';
import { PayOffline } from '@/features/money/PayOffline';
import { TipPicker } from '@/features/portal/TipPicker';
import type { TipOptions } from '@/features/money/tips';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add a tip', path: '/account/bookings', noindex: true, description: 'Thank the team who looked after your rental.' });

// r48 part 2 (3053): the after-trip email's and text's tip link (emails/src/links.mjs booking_tip): 10, 15 or 20% or an
// amount, paid by card. Signed in as the renter of the booking.
export default async function TipPage({ params }: { params: Promise<{ number: string }> }) {
  const { b } = await myBooking((await params).number, 'tip');
  const [o, card] = await Promise.all([(rpc('server_tip_options', { p_booking: b.id }, { role: 'service_role' }).catch(() => null)) as unknown as Promise<TipOptions | null>, cardPayments()]);
  return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <h1 className="d2">Thank the team</h1>
      {o?.on && !cardOn(card) ? <PayOffline card={card} reference={`${b.booking_number} tip`} title="Send a tip by e-Transfer" testId="tip-offline" />
        : o?.on ? <TipPicker number={b.booking_number} options={o} source="link" />
        : <p className="pt-card" data-testid="tip-off">A tip cannot be added to this booking. Thank you all the same!</p>}
    </>
  );
}
