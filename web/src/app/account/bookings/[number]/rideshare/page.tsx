import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { myBooking } from '@/server/portal/data';
import { bookingPath } from '@/features/portal/status';
import { rpc } from '@/lib/db/repo';
import { PrintButton } from '@/features/incident-cards/PrintButton';
import { Letters } from '@/features/rideshare/Letters';
import { RideshareForm } from '@/features/rideshare/RideshareForm';
import type { RideshareFacts } from '@/features/rideshare/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Rideshare documents', path: '/account/bookings', noindex: true, description: 'The documents a rideshare or delivery platform asks for, for this rental.' });

// r35a (1303): from the booking page's More menu: the renter picks the platforms and gets the rental agreement copy, the
// coverage letter and the vehicle letter (on the company letterhead, naming only the company). Our team is told.
export default async function RideshareDocs({ params }: { params: Promise<{ number: string }> }) {
  const { b, user } = await myBooking((await params).number, 'rideshare');
  const f = (await rpc('server_rideshare_docs', { p_by: user.id, p_booking: b.id }, { role: 'service_role' }).catch(() => null)) as unknown as RideshareFacts | null;
  return (
    <div className="stack" data-testid="renter-rideshare">
      <p className="rs-noprint"><Link prefetch={false} className="link" href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Link></p>
      <h1 className="d3 rs-noprint">Rideshare and delivery documents</h1>
      {!f || (!f.open && f.requests.length === 0) ? <p className="muted">These documents are made for a booked trip, from the offer you accepted until the return.</p> : <>
        <section className="pt-card stack rs-noprint">
          <p className="small">Driving for a rideshare or delivery platform with this car? Pick the platforms and we make the documents they usually ask for: a copy of your rental agreement, a proof of insurance and coverage letter, and a vehicle registration letter. Check each platform&apos;s own vehicle rules too.</p>
          {f.open && <RideshareForm number={b.booking_number} />}
        </section>
        {f.requests.length > 0 && <>
          <section className="pt-card stack rs-noprint" data-testid="rideshare-docs">
            <h2 className="d4">Your documents</h2>
            <ul className="small">
              <li>{f.agreement_document_id ? <Link prefetch={false} className="link" href={`/account/documents/${f.agreement_document_id}`} data-testid="rideshare-agreement">Rental agreement (copy)</Link> : 'Rental agreement: ready once you sign it'}</li>
              <li>Proof of insurance and coverage letter (below)</li>
              <li>Vehicle registration and ownership letter (below)</li>
            </ul>
            <p><PrintButton label="Print or save the letters as a PDF" testId="rideshare-print" /></p>
          </section>
          <Letters f={f} />
        </>}
      </>}
    </div>
  );
}
