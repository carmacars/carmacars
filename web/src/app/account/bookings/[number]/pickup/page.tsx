import { pageMeta } from '@/features/seo/meta';
import { myBooking } from '@/server/portal/data';
import { bookingPath } from '@/features/portal/status';
import { HandoverOneScreen } from '@/features/handover/HandoverOneScreen';
import Link from '@/components/Link';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Check in', path: '/account/bookings', noindex: true, description: 'Check the car in yourself at pickup.' });

// 0545: the renter's own check-in at pickup: one screen, many photos at once with the suggested angles, km, fuel and
// the time. Recorded at once when the booking is ready to go out; otherwise a team member confirms it.
export default async function SelfPickup({ params }: { params: Promise<{ number: string }> }) {
  const { b } = await myBooking((await params).number, 'pickup');
  const signed = b.agreement?.status === 'signed' || b.agreement?.status === 'completed';
  return (
    <div className="stack" data-testid="self-pickup">
      <p><Link prefetch={false} className="link" href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Link></p>
      <h1 className="d3">Check in your car</h1>
      <p>Take the photos yourself when you get the car: pick them all at once from your camera roll. We add ours if anything is missing.</p>
      {!signed && b.status !== 'on_rent' && <p className="alert alert--warn" role="status"><span>Sign the rental agreement first: <Link prefetch={false} className="link" href={bookingPath(b.booking_number, 'sign')}>sign now</Link>.</span></p>}
      {b.status === 'on_rent' ? <p className="pt-ok" role="status">You are checked in. You can add photos from the photo report.</p>
        : <HandoverOneScreen booking={b.id} number={b.booking_number} kind="pickup" who="renter" />}
    </div>
  );
}
