import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { $, Badge, BookingLink, Filters, PageHead, Search, Table, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Bookings', path: '/admin/bookings', noindex: true, description: 'Every booking.' });

const STATUSES: Array<[string, string]> = [['', 'All'], ['requested', 'Requested'], ['offered', 'Offered'], ['pending_payment', 'Signing and payment'], ['confirmed', 'Confirmed'], ['on_rent', 'On rent'], ['returned', 'Returned'], ['closed', 'Closed'], ['cancelled', 'Cancelled']];
type Row = { id: string; booking_number: string; status: string; vehicle_name: string; renter_name: string; pickup_at: string; return_at: string; total_due_at_booking_cents: number; bill_to: string; blocks_calendar: boolean };

export default async function Bookings({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ list }, sp] = await Promise.all([page('/admin/bookings'), searchParams]);
  const status = sp.status ?? '';
  const { rows, count } = await list<Row>('bookings', { eq: status ? { status } : {}, q: sp.q, order: 'pickup_at', limit: 200 });
  return (
    <>
      <PageHead title="Bookings" kicker={`${count} found`}><Search action="/admin/bookings" value={sp.q} placeholder="Booking number, renter, plate" /></PageHead>
      <Filters base="/admin/bookings" name="status" value={status} options={STATUSES} sp={sp} />
      <Table<Row> testId="bookings" caption="Bookings" rows={rows} cols={[
        { key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> },
        { key: 'status', label: 'Status', render: (r) => <Badge s={r.status} /> },
        { key: 'vehicle_name', label: 'Car' }, { key: 'renter_name', label: 'Renter' },
        { key: 'pickup_at', label: 'Pickup', render: (r) => t(r.pickup_at) }, { key: 'return_at', label: 'Return', render: (r) => t(r.return_at) },
        { key: 'total', label: 'Total', num: true, render: (r) => $(r.total_due_at_booking_cents) },
        { key: 'bill_to', label: 'Bill to' }, { key: 'blocks_calendar', label: 'Blocks' }
      ]} />
    </>
  );
}
