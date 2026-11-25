import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { myBooking } from '@/server/portal/data';
import { bookingPath } from '@/features/portal/status';
import { renterCheckin } from '@/server/checkins';
import { PickTime } from '@/features/checkins/PickTime';
import { nextLine } from '@/features/checkins/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Check-in visit', path: '/account/bookings', noindex: true, description: 'Pick a time for the free monthly check-in visit of your rental car.' });

// Release 50 (4000): the renter of a long rental picks a time for the monthly check-in visit, at the office or by request.
export default async function CheckinPage({ params }: { params: Promise<{ number: string }> }) {
  const { b, user } = await myBooking((await params).number, 'check-in');
  const s = await renterCheckin(user.id, b.booking_number);
  const open = !!s.visit && ['due', 'booked'].includes(s.visit.status);
  return (
    <div className="stack" data-testid="renter-checkin">
      <p><Link prefetch={false} className="link" href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Link></p>
      <h1 className="d3">Check-in visit</h1>
      {!s.on ? <p className="muted" data-testid="checkin-off">This rental has no check-in visits. They are for rentals of about a month or longer.</p> : <>
        <section className="pt-card stack">
          <p className="d4" data-testid="checkin-line">{nextLine(s)}</p>
          <p className="small">About once a month we take a quick look at the car with you, about 15 minutes. It keeps the car in top shape and lets us catch maintenance early (oil, tires, brakes), before it becomes a problem on the road. It is free: there is nothing to pay, and it is a suggestion, not a requirement.</p>
        </section>
        {open ? <PickTime number={b.booking_number} s={s} /> : <p className="muted" data-testid="checkin-later">You can pick a time once the visit is close: we send you a reminder a few days before.</p>}
      </>}
    </div>
  );
}
