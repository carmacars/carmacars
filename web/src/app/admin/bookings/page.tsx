import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import Link from 'next/link';
import { $, Badge, BookingLink, Filters, MoreFilters, PageHead, Search, Table, t } from '@/features/admin/ui';
import { door } from '@/server/door';
import { UnfinishedRentals } from '@/features/supply/UnfinishedRentals';
import type { DraftRow } from '@/server/actions/supply';
import { lateLabel } from '@/features/handover/late';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Bookings', path: '/admin/bookings', noindex: true, description: 'Every booking.' });

const STATUSES: Array<[string, string]> = [['', 'All'], ['requested', 'Requested'], ['offered', 'Offered'], ['pending_payment', 'Waiting for payment'], ['confirmed', 'Confirmed'], ['on_rent', 'On rent'], ['returned', 'Returned'], ['closed', 'Closed'], ['cancelled', 'Cancelled']];
type Row = { id: string; booking_number: string; status: string; awaiting_signature?: boolean; vehicle_name: string; renter_name: string; pickup_at: string; return_at: string; total_due_at_booking_cents: number; bill_to: string; blocks_calendar: boolean; checked_in_at?: string | null; minutes_late?: number | null };

export default async function Bookings({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ list, user }, sp] = await Promise.all([page('/admin/bookings'), searchParams]);
  const status = sp.status ?? '';
  // 0200: the search finds a booking by its number, the renter's or a driver's name, email, phone, plate or car code
  const q = (sp.q ?? '').trim();
  const found = q ? (await door<Array<{ id: string }>>(user.id, 'ops_read', 'bookings_search', { q, status, limit: 200 })).map((b) => b.id) : null;
  const byQ = (eq: Record<string, unknown>) => (found ? { ...eq, id: found.length ? found : ['00000000-0000-0000-0000-000000000000'] } : eq);
  const res = await list<Row>('bookings', { eq: byQ(status ? { status } : {}), order: 'pickup_at', limit: 200 });
  // by who supplies the car, or only the rentals added by hand (0046)
  const keep = sp.supply || sp.added ? new Set((await door<Array<{ id: string }>>(user.id, 'ops_read', 'bookings_by_supply', { supply: sp.supply ?? '', added: !!sp.added, status, limit: 2000 })).map((b) => b.id)) : null;
  const rows = keep ? res.rows.filter((r) => keep.has(r.id)) : res.rows;
  const drafts = await door<DraftRow[]>(user.id, 'ops_read', 'drafts', { kind: 'rental' }).catch(() => [] as DraftRow[]);
  // bookings waiting for payment (the renter accepted, has not paid): always listed first in All, never cut by the limit
  const waiting = status ? null : await list<Row>('bookings', { eq: byQ({ status: 'pending_payment' }), order: 'pickup_at', asc: true, limit: 200 });
  const waitingRows = waiting ? (keep ? waiting.rows.filter((r) => keep.has(r.id)) : waiting.rows) : [];
  const ids = new Set(waitingRows.map((r) => r.id));
  const listed = [...waitingRows, ...rows.filter((r) => !ids.has(r.id))];
  const count = keep ? listed.length : res.count;
  return (
    <>
      <PageHead title="Bookings" kicker={`${count} found`} purpose="Every booking, newest pickup first. Open one to see its trip, payments and documents."><Search action="/admin/bookings" value={sp.q} placeholder="Booking number, name, email, phone, plate or car code" />
        <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/offers/new" data-testid="send-offer-link">Send an offer</Link>
        <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/bookings/new" data-testid="add-rental-link">Add a rental</Link></PageHead>
      <UnfinishedRentals rows={drafts} base="/admin" />
      <Filters base="/admin/bookings" name="status" value={status} sp={sp}
        options={STATUSES.map(([k, l]) => [k, k === 'pending_payment' && waiting ? `${l} (${waitingRows.length})` : l] as [string, string])} />
      {waitingRows.length > 0 && <p className="small" data-testid="bookings-waiting-payment">{waitingRows.length === 1 ? '1 booking is' : `${waitingRows.length} bookings are`} waiting for payment: the renter accepted the offer and has not paid yet. They are listed first.</p>}
      <MoreFilters active={!!(sp.supply || sp.added)}>
        <Filters base="/admin/bookings" name="supply" value={sp.supply ?? ''} options={[['', 'Every car'], ['program_owner', 'Program owners\' cars'], ['company', 'CarmaCars-owned'], ['partner', 'Partners\' cars']]} sp={sp} />
        <Filters base="/admin/bookings" name="added" value={sp.added ?? ''} options={[['', 'Every booking'], ['1', 'Added by hand']]} sp={sp} />
      </MoreFilters>
      <Table<Row> testId="bookings" caption="Bookings" rows={listed} cols={[
        { key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> },
        { key: 'status', label: 'Status', render: (r) => { const late = lateLabel(r); return <>{r.status === 'pending_payment' ? <Badge s="pending_payment">{r.awaiting_signature ? 'Waiting for signature and payment' : 'Waiting for payment'}</Badge> : <Badge s={r.awaiting_signature ? 'awaiting_signature' : r.status} />}{late && <> <span className="ad-late small" data-testid="list-late">{late}</span></>}</>; } },
        { key: 'vehicle_name', label: 'Car' }, { key: 'renter_name', label: 'Renter' },
        { key: 'pickup_at', label: 'Pickup', render: (r) => t(r.pickup_at) }, { key: 'return_at', label: 'Return', render: (r) => t(r.return_at) },
        { key: 'total', label: 'Total', num: true, render: (r) => $(r.total_due_at_booking_cents) },
        { key: 'bill_to', label: 'Bill to' }, { key: 'blocks_calendar', label: 'Blocks' }
      ]} />
    </>
  );
}
