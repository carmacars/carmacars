import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { staffCtx } from '@/features/shared-pages/context';
import { PrintButton } from '@/features/incident-cards/PrintButton';
import { Letters } from '@/features/rideshare/Letters';
import type { RideshareFacts } from '@/features/rideshare/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Rideshare documents', path: '/staff', noindex: true, description: 'The rideshare documents the renter made for this booking.' });

// r35a (1303): the letters the renter made, as they see them (every staff function and an Admin).
export default async function StaffRideshare({ params }: { params: Promise<{ number: string }> }) {
  const n = decodeURIComponent((await params).number);
  const ctx = await staffCtx(`/staff/bookings/${n}/rideshare`);
  const f = await ctx.ops<RideshareFacts>('rideshare_docs', { booking: n }).catch(() => null);
  return (
    <div className="stack" data-testid="staff-rideshare">
      <p className="rs-noprint"><Link prefetch={false} className="link" href={`/staff/bookings/${encodeURIComponent(n)}`}>Booking {n}</Link></p>
      <h1 className="d3 rs-noprint">Rideshare documents</h1>
      {!f || f.requests.length === 0 ? <p className="muted">The renter has not made rideshare documents for this booking.</p> : <>
        <p className="small rs-noprint">Made for {f.requests.map((r) => r.labels.join(', ')).join('; ')}. <PrintButton label="Print" /></p>
        <Letters f={f} />
      </>}
    </div>
  );
}
