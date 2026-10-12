import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { torontoParts } from '@/lib/dates';
import { bookingPath } from '@/features/portal/status';
import { Back } from '@/features/portal/Blocks';
import { ChangeForm } from '@/features/portal/SelfService';
import { myBooking } from '@/server/portal/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Change dates', path: '/account/bookings', noindex: true, description: 'Ask to change the dates of a confirmed booking.' });

const hm = (m: number) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;

// Date changes are not self-service: the renter sees the difference (my_booking_change_preview) and asks;
// staff approve, price and apply it (02 section 7.4).
export default async function ChangePage({ params }: { params: Promise<{ number: string }> }) {
  const { b } = await myBooking((await params).number, 'change');
  if (b.status !== 'confirmed') redirect(bookingPath(b.booking_number));
  const p = torontoParts(b.pickup_at), r = torontoParts(b.return_at);
  const open = b.change_requests.find((c) => ['requested', 'proposed', 'approved'].includes(c.status));
  return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <h1 className="d2">Ask to change dates</h1>
      <section className="pt-card" style={{ maxWidth: '40rem' }}>
        {open ? <p role="status">You already asked for a change ({open.status}). See it on the booking page.</p>
          : <ChangeForm number={b.booking_number} pickupDate={p.date} pickupTime={hm(p.minutes)} returnDate={r.date} returnTime={hm(r.minutes)} />}
      </section>
    </>
  );
}
