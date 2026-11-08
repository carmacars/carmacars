import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { siteUrl } from '@/lib/site';
import { PageHead } from '@/features/admin/ui';
import { AccidentSheet } from '@/features/accident-card/AccidentCard';
import { PrintButton } from '@/features/incident-cards/PrintButton';
import type { AccidentCardData } from '@/features/accident-card/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Accident card', path: '/staff', noindex: true, description: 'The renter\'s accident card of a booking, to print.' });

// Release 35 (migration 0910): the renter's accident card of the booking (their coverage, never the fleet policy).
export default async function StaffAccidentCard({ params }: { params: Promise<{ number: string }> }) {
  const n = decodeURIComponent((await params).number);
  const { user, aal } = await vaPage(`/staff/bookings/${n}/accident-card`);
  const d = await door<AccidentCardData | null>(user.id, 'ops_read', 'accident_card', { booking: n }, aal).catch(() => null);
  if (!d?.booking_id) notFound();
  const base = `/staff/bookings/${encodeURIComponent(n)}`;
  return (<>
    <PageHead kicker={<><Link prefetch={false} className="link" href="/staff">Queue</Link> · <Link prefetch={false} className="link" href={base}>{n}</Link></>} title="Accident card" purpose="The renter's card for this booking: the steps after an accident and the coverage this booking uses.">
      <PrintButton label="Print the card" testId="print-accident-card" />
    </PageHead>
    <div className="ac-print"><AccidentSheet d={d} site={siteUrl()} /></div>
  </>);
}
