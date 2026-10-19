import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Badge, BookingLink, Card, Kv, PageHead, Table, d, t } from '@/features/admin/ui';
import { VisitorTimeline, type TimelineData } from '@/features/live/VisitorTimeline';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Renter', path: '/admin/renters', noindex: true, description: 'One renter: details, bookings and visits on the site.' });

type R = { id: string; name: string; email: string | null; mobile: string | null; identity_status: string; created_at: string; city: string | null; is_blocked: boolean;
  bookings: Array<{ number: string; status: string; pickup_at: string; return_at: string; car: string }>; timeline: TimelineData };

// People > Renters > a renter (migration 0060): the record, the bookings, and what they looked at on the site and their chats.
export default async function Renter({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read } = await page(`/admin/renters/${id}`);
  const r = await read<R>('renter_live', { renter_id: id }).catch(() => null);
  if (!r) notFound();
  return (
    <>
      <PageHead title={r.name} kicker="Renter"><Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/renters">All renters</Link></PageHead>
      <div className="ad-cols ad-cols--2">
        <div className="stack">
          <Card title="Details"><Kv rows={[['Email', r.email ?? ''], ['Phone', r.mobile ?? ''], ['City', r.city ?? ''], ['Identity', <Badge key="i" s={r.identity_status} />], ['Blocked', r.is_blocked ? 'Yes' : 'No'], ['Since', d(r.created_at)]]} /></Card>
          <Card title="Bookings"><Table rows={r.bookings} rowKey={(b) => b.number} empty="No bookings yet." cols={[{ key: 'number', label: 'Booking', render: (b) => <BookingLink n={b.number} /> },
            { key: 'car', label: 'Car' }, { key: 'status', label: 'Status', render: (b) => <Badge s={b.status} /> }, { key: 'pickup_at', label: 'Pickup', render: (b) => t(b.pickup_at) }]} /></Card>
        </div>
        <Card title="On the site" testId="renter-visits"><VisitorTimeline t={r.timeline} chatBase="/admin/chat" /></Card>
      </div>
    </>
  );
}
