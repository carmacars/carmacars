import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { torontoParts } from '@/lib/dates';
import { when } from '@/features/agreement/model';
import { bookingPath } from '@/features/portal/status';
import { Back } from '@/features/portal/Blocks';
import { ExtendForm } from '@/features/portal/SelfService';
import { myBooking } from '@/server/portal/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Extend your rental', path: '/account/bookings', noindex: true, description: 'Ask for more time with the car and pay for it.' });

const hm = (m: number) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;

// Extend (02 section 7.5): preview from public.my_extension_preview, request, then pay once approved.
export default async function ExtendPage({ params }: { params: Promise<{ number: string }> }) {
  const { b } = await myBooking((await params).number, 'extend');
  if (!['confirmed', 'on_rent'].includes(b.status)) redirect(bookingPath(b.booking_number));
  const r = torontoParts(b.return_at);
  const open = b.extensions.find((e) => ['requested', 'approved'].includes(e.status));
  return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <h1 className="d2">Extend your rental</h1>
      <p className="lead">Current return: {when(b.return_at)}. Ask before then; one rental is at most 30 days.</p>
      <section className="pt-card" style={{ maxWidth: '40rem' }}>
        {open?.status === 'requested' ? <p role="status">Your request to return on {when(open.new_return_at)} is with our team. Once approved, you pay for it here.</p>
          : <ExtendForm number={b.booking_number} returnDate={r.date} returnTime={hm(Math.round(r.minutes / 30) * 30 % 1440)} approved={open?.status === 'approved' ? { id: open.id, total_cents: open.total_cents ?? 0, new_return_at: open.new_return_at } : null} />}
      </section>
    </>
  );
}
