import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Filters, MoreFilters, Search } from '@/features/admin/ui';
import { door } from '@/server/door';
import { UnfinishedRentals } from '@/features/supply/UnfinishedRentals';
import type { DraftRow } from '@/server/actions/supply';
import { lateLabel } from '@/features/handover/late';
import { redirect } from 'next/navigation';
import { BookingsHead } from '@/features/bookings-now/BookingsTabs';
import { BookingsNow } from '@/features/bookings-now/BookingsNow';
import { bookingCards, bookingsNow } from '@/server/bookings-now';
import { BookingRows } from '@/features/bookings-now/BookingRows';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Bookings', path: '/admin/bookings', noindex: true, description: 'What is out, coming back, going out and owed now, and every booking.' });

// Out now (0330): on rent, and confirmed with the pickup time passed and no check-out recorded, in one list (the owner:
// "some of the confirmed ones are on rent"). An old ?status=on_rent link opens it.
const STATUSES: Array<[string, string]> = [['', 'All'], ['out', 'Out now'], ['confirmed', 'Booked'], ['returned', 'Returned'], ['closed', 'Closed'], ['cancelled', 'Cancelled']];
// requests, offers and bookings waiting for payment live under Requests and offers; an old ?status= for them still lists them here
const BILL: Array<[string, string]> = [['', 'All'], ['renter', 'Renter'], ['insurer', 'Insurer']];
type Row = { id: string; booking_number: string; status: string; awaiting_signature?: boolean; vehicle_name: string; renter_name: string; pickup_at: string; return_at: string; total_due_at_booking_cents: number; bill_to: string; blocks_calendar: boolean; checked_in_at?: string | null; minutes_late?: number | null };

// Bookings (Release 26, migration 0330). Now, the default: which cars are out and with whom, when each is due back and
// pays next, what goes out in the next 72 hours and whether it is ready, the money due and the free cars, live. All
// bookings (?view=all): the search and the list by status, as before. A link from before (?status=, ?q=, ?supply=,
// ?added=) opens All bookings with its filter.
export default async function Bookings({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ list, user }, sp] = await Promise.all([page('/admin/bookings'), searchParams]);
  if (sp.view !== 'all') {
    if (sp.status || sp.q || sp.supply || sp.added) {
      const q = new URLSearchParams(Object.entries(sp).filter(([, v]) => typeof v === 'string' && v) as Array<[string, string]>);
      q.set('view', 'all');
      redirect(`/admin/bookings?${q.toString()}`);
    }
    const [board, drafts] = await Promise.all([bookingsNow(user.id).catch(() => null),
      door<DraftRow[]>(user.id, 'ops_read', 'drafts', { kind: 'rental' }).catch(() => [] as DraftRow[])]);
    // the clock the page is drawn at: the browser starts from it, so its first render matches this one
    const at = new Date().getTime();
    return (
      <>
        <BookingsHead current="now" lead="What is out, coming back, going out and owed, live. Toronto time." />
        <UnfinishedRentals rows={drafts} base="/admin" />
        <BookingsNow initial={board} at={at} src="/api/staff/bookings-now" base="/admin" />
      </>
    );
  }
  if (sp.status === 'on_rent') redirect(`/admin/bookings?${new URLSearchParams({ ...Object.fromEntries(Object.entries(sp).filter(([, v]) => typeof v === 'string') as Array<[string, string]>), status: 'out' }).toString()}`);
  const status = sp.status ?? '';
  // Out now: the ids the board lists as out
  const outIds = status === 'out' ? ((await bookingsNow(user.id).catch(() => null))?.out ?? []).map((r) => r.booking_id) : null;
  // 0200: the search finds a booking by its number, the renter's or a driver's name, email, phone, plate or car code
  const q = (sp.q ?? '').trim();
  const found = q ? (await door<Array<{ id: string }>>(user.id, 'ops_read', 'bookings_search', { q, status: status === 'out' ? '' : status, limit: 200 })).map((b) => b.id) : null;
  // Bill to: the renter, or an insurer (in full or split)
  const billEq: Record<string, unknown> = sp.bill === 'renter' ? { bill_to: 'renter' } : sp.bill === 'insurer' ? { bill_to: ['insurer', 'split'] } : {};
  const byQ = (eq: Record<string, unknown>) => ({ ...billEq, ...(found ? { ...eq, id: found.length ? found : ['00000000-0000-0000-0000-000000000000'] } : eq) });
  const NONE = '00000000-0000-0000-0000-000000000000';
  const res = outIds
    ? await list<Row>('bookings', { eq: { ...billEq, id: (found ? outIds.filter((x) => found.includes(x)) : outIds).concat(NONE) }, order: 'return_at', asc: true, limit: 200 })
    : await list<Row>('bookings', { eq: byQ(status ? { status } : {}), order: 'pickup_at', limit: 200 });
  // by who supplies the car, or only the rentals added by hand (0046)
  const keep = sp.supply || sp.added ? new Set((await door<Array<{ id: string }>>(user.id, 'ops_read', 'bookings_by_supply', { supply: sp.supply ?? '', added: !!sp.added, status: status === 'out' ? '' : status, limit: 2000 })).map((b) => b.id)) : null;
  const rows = keep ? res.rows.filter((r) => keep.has(r.id)) : res.rows;
  const drafts = await door<DraftRow[]>(user.id, 'ops_read', 'drafts', { kind: 'rental' }).catch(() => [] as DraftRow[]);
  // bookings waiting for payment (the renter accepted, has not paid): always listed first in All, never cut by the limit
  const waiting = status ? null : await list<Row>('bookings', { eq: byQ({ status: 'pending_payment' }), order: 'pickup_at', asc: true, limit: 200 });
  const waitingRows = waiting ? (keep ? waiting.rows.filter((r) => keep.has(r.id)) : waiting.rows) : [];
  const ids = new Set(waitingRows.map((r) => r.id));
  const listed = [...waitingRows, ...rows.filter((r) => !ids.has(r.id))];
  const count = keep ? listed.length : res.count;
  const cards = await bookingCards(user.id, listed.map((r) => r.id));
  const at = new Date().getTime();
  return (
    <>
      <BookingsHead current="all" lead={`${count} found. Every booking, newest pickup first; open one for its trip, payments and documents.`} />
      <section className="bk-filters" aria-label="Find and filter">
        {/* a search sent from here opens All bookings again (the page moves ?q= there) */}
        <Search action="/admin/bookings" value={sp.q} placeholder="Booking number, name, email, phone, plate or car code" />
        <div className="bk-filters__row"><span className="bk-filters__k">Status</span><Filters base="/admin/bookings?view=all" name="status" value={status} sp={sp} options={STATUSES} /></div>
        <div className="bk-filters__row"><span className="bk-filters__k">Bill to</span><Filters base="/admin/bookings?view=all" name="bill" value={sp.bill ?? ''} sp={sp} options={BILL} /></div>
        <MoreFilters active={!!(sp.supply || sp.added)}>
          <Filters base="/admin/bookings?view=all" name="supply" value={sp.supply ?? ''} options={[['', 'Every car'], ['program_owner', 'Program owners\' cars'], ['company', 'CarmaCars-owned'], ['partner', 'Partners\' cars']]} sp={sp} />
          <Filters base="/admin/bookings?view=all" name="added" value={sp.added ?? ''} options={[['', 'Every booking'], ['1', 'Added by hand']]} sp={sp} />
        </MoreFilters>
      </section>
      <UnfinishedRentals rows={drafts} base="/admin" />
      {waitingRows.length > 0 && <p className="small" data-testid="bookings-waiting-payment">{waitingRows.length === 1 ? '1 booking is' : `${waitingRows.length} bookings are`} waiting for payment: the renter accepted the offer and has not paid yet. They are listed first.</p>}
      <BookingRows rows={listed.map((r) => ({ ...r, late: lateLabel(r) }))} cards={cards} base="/admin" at={at} empty={q ? `Nothing matches "${q}".` : 'No bookings with these filters.'} />
    </>
  );
}
