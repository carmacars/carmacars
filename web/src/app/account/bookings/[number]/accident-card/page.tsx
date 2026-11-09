import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { myBooking } from '@/server/portal/data';
import { bookingPath } from '@/features/portal/status';
import { rpc } from '@/lib/db/repo';
import { siteUrl } from '@/lib/site';
import { AccidentSheet } from '@/features/accident-card/AccidentCard';
import { PrintButton } from '@/features/incident-cards/PrintButton';
import type { AccidentCardData } from '@/features/accident-card/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Accident card', path: '/account/bookings', noindex: true, description: 'What to do after an accident, and the coverage of this booking. Print it for the glovebox.' });

// Release 35 (migration 0910): the renter's accident card for this booking, printable at the card's size.
export default async function RenterAccidentCard({ params }: { params: Promise<{ number: string }> }) {
  const { b, user } = await myBooking((await params).number, 'accident-card');
  const d = (await rpc('server_accident_card' as never, { p_booking: b.id, p_by: user.id } as never, { role: 'service_role' })) as unknown as AccidentCardData;
  return (
    <div className="stack" data-testid="renter-accident-card">
      <p><Link prefetch={false} className="link" href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Link></p>
      <h1 className="d3">Accident card</h1>
      <p>Keep it in the glovebox or on your phone. Print it on Letter paper and cut along the corner marks.</p>
      <p><PrintButton label="Print the card" testId="print-accident-card" /></p>
      <div className="ac-print"><AccidentSheet d={d} site={siteUrl()} /></div>
    </div>
  );
}
