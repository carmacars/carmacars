import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import Link from 'next/link';
import { $, Badge, BookingLink, Filters, MoreFilters, PageHead, Search, Table, t } from '@/features/admin/ui';
import { door } from '@/server/door';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Bookings', path: '/admin/bookings', noindex: true, description: 'Every booking.' });

const STATUSES: Array<[string, string]> = [['', 'All'], ['requested', 'Requested'], ['offered', 'Offered'], ['pending_payment', 'Signing and payment'], ['confirmed', 'Confirmed'], ['on_rent', 'On rent'], ['returned', 'Returned'], ['closed', 'Closed'], ['cancelled', 'Cancelled']];
type Row = { id: string; booking_number: string; status: string; awaiting_signature?: boolean; vehicle_name: string; renter_name: string; pickup_at: string; return_at: string; total_due_at_booking_cents: number; bill_to: string; blocks_calendar: boolean };

export default async function Bookings({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ list, user }, sp] = await Promise.all([page('/admin/bookings'), searchParams]);
  const status = sp.status ?? '';
  const res = await list<Row>('bookings', { eq: status ? { status } : {}, q: sp.q, order: 'pickup_at', limit: 200 });
  // by who supplies the car, or only the rentals added by hand (0046)
  const keep = sp.supply || sp.added ? new Set((await door<Array<{ id: string }>>(user.id, 'ops_read', 'bookings_by_supply', { supply: sp.supply ?? '', added: !!sp.added, status, limit: 2000 })).map((b) => b.id)) : null;
  const rows = keep ? res.rows.filter((r) => keep.has(r.id)) : res.rows;
  const count = keep ? rows.length : res.count;
  return (
    <>
      <PageHead title="Bookings" kicker={`${count} found`} purpose="Every booking, newest pickup first. Open one to see its trip, payments and documents."><Search action="/admin/bookings" value={sp.q} placeholder="Booking number, renter, plate" />
        <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/offers/new" data-testid="send-offer-link">Send an offer</Link>
        <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/bookings/new" data-testid="add-rental-link">Add a rental</Link></PageHead>
      <Filters base="/admin/bookings" name="status" value={status} options={STATUSES} sp={sp} />
      <MoreFilters active={!!(sp.supply || sp.added)}>
        <Filters base="/admin/bookings" name="supply" value={sp.supply ?? ''} options={[['', 'Every car'], ['program_owner', 'Program owners\' cars'], ['company', 'CarmaCars-owned'], ['partner', 'Partners\' cars']]} sp={sp} />
        <Filters base="/admin/bookings" name="added" value={sp.added ?? ''} options={[['', 'Every booking'], ['1', 'Added by hand']]} sp={sp} />
      </MoreFilters>
      <Table<Row> testId="bookings" caption="Bookings" rows={rows} cols={[
        { key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> },
        { key: 'status', label: 'Status', render: (r) => <Badge s={r.awaiting_signature ? 'awaiting_signature' : r.status} /> },
        { key: 'vehicle_name', label: 'Car' }, { key: 'renter_name', label: 'Renter' },
        { key: 'pickup_at', label: 'Pickup', render: (r) => t(r.pickup_at) }, { key: 'return_at', label: 'Return', render: (r) => t(r.return_at) },
        { key: 'total', label: 'Total', num: true, render: (r) => $(r.total_due_at_booking_cents) },
        { key: 'bill_to', label: 'Bill to' }, { key: 'blocks_calendar', label: 'Blocks' }
      ]} />
    </>
  );
}
