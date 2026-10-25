import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { Back } from '@/features/portal/Blocks';
import { bookingPath } from '@/features/portal/status';
import { myBooking, myTripPhotos } from '@/server/portal/data';
import { StepHeader } from '@/features/portal/trip';
import { HandoverReport } from '@/features/handover/HandoverReport';
import type { HandoverReportData } from '@/features/handover/types';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Photo report', path: '/account/bookings', noindex: true, description: 'The check-out and check-in of your rental: times, kilometres, fuel, photos and damage.' });

// The renter's photo report (migration 0130): the address the "Your rental has started" and "Returned" emails link to.
export default async function RenterReport({ params }: { params: Promise<{ number: string }> }) {
  const { user, b } = await myBooking((await params).number, 'condition-report');
  const photos = await myTripPhotos(user);
  const r = (await rpc('server_renter_handover_report', { p_booking: b.id, p_by: user.id }, { role: 'service_role' }).catch(() => null)) as unknown as HandoverReportData | null;
  if (!r?.booking_id) notFound();
  return (<>
    <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
    <StepHeader b={b} photo={photos[b.vehicle_id] ?? null} kicker="The check-out and the check-in, with every photo we took together" title="Photo report" />
    <HandoverReport r={r} staff={false} />
  </>);
}
