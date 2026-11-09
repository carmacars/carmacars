import Link from '@/components/Link';
import type { DraftRow } from '@/server/actions/supply';
import { PageHead, Search } from '@/features/admin/ui';
import { BookingRows, type BookingRow } from '@/features/bookings-now/BookingRows';
import { BookingsNow } from '@/features/bookings-now/BookingsNow';
import { BookingsHead } from '@/features/bookings-now/BookingsTabs';
import { money } from '@/features/bookings-now/model';
import { lateLabel } from '@/features/handover/late';
import { ListFilters } from '@/features/list-filters/ListFilters';
import { UnfinishedRentals } from '@/features/supply/UnfinishedRentals';
import { bookingCards, bookingsNow } from '@/server/bookings-now';
import { redirect } from 'next/navigation';
import type { PageCtx } from '@/features/shared-pages/context';

// r31 "Simple": one Bookings page for Admin and staff. Both open on Now (0330), live; an Admin also has All bookings by
// status (?view=all), staff find any booking with a logged search (0200) and see their own bookings with the commission
// (0332). The database decides what each function reads (Sales: no money, no renters' phones and emails).
export async function BookingsPage({ ctx, sp }: { ctx: PageCtx; sp: Record<string, string | undefined> }) {
  // called, not rendered as elements, so a redirect answers as one (not inside a streamed page)
  return ctx.viewer.role === 'admin' ? AdminBookings({ ctx, sp }) : FindBooking({ ctx, sp });
}

// Out now (0330): on rent, and confirmed with the pickup time passed and no check-in recorded, in one list (the owner:
// "some of the confirmed ones are on rent"). An old ?status=on_rent link opens it.
// r32: five chips, the ones that need action first; Closed and Cancelled are found with the search (or ?status=, kept)
const STATUSES: Array<[string, string]> = [['', 'All'], ['out', 'Out now'], ['confirmed', 'Booked'], ['returned', 'Returned'], ['cancelled', 'Cancelled']];
// requests, offers and bookings waiting for payment live under Requests and offers; an old ?status= for them still lists them here
type Row = { id: string; booking_number: string; status: string; awaiting_signature?: boolean; vehicle_name: string; renter_name: string; pickup_at: string; return_at: string; total_due_at_booking_cents: number; bill_to: string; blocks_calendar: boolean; checked_in_at?: string | null; minutes_late?: number | null };

// Bookings (Release 26, migration 0330). Now, the default: which cars are out and with whom, when each is due back and
// pays next, what goes out in the next 72 hours and whether it is ready, the money due and the free cars, live. All
// bookings (?view=all): the search and the list by status, as before. A link from before (?status=, ?q=, ?supply=,
// ?added=) opens All bookings with its filter.
async function AdminBookings({ ctx, sp }: { ctx: PageCtx; sp: Record<string, string | undefined> }) {
  const { list, user, ops } = ctx;
  if (sp.view !== 'all') {
    if (sp.status || sp.q || sp.supply || sp.added) {
      const q = new URLSearchParams(Object.entries(sp).filter(([, v]) => typeof v === 'string' && v) as Array<[string, string]>);
      q.set('view', 'all');
      redirect(`/admin/bookings?${q.toString()}`);
    }
    const [board, drafts] = await Promise.all([bookingsNow(user.id).catch(() => null),
      ops<DraftRow[]>('drafts', { kind: 'rental' }).catch(() => [] as DraftRow[])]);
    // the clock the page is drawn at: the browser starts from it, so its first render matches this one
    const at = new Date().getTime();
    // 0910, 1063: trips past their return time and not closed (never picked up, on rent, or returned and not closed)
    const past = (await ops<{ rows: unknown[] }>('ended_trips', {}).catch(() => ({ rows: [] as unknown[] }))).rows.length;
    return (
      <>
        <BookingsHead current="now" lead="What is out, coming back, going out and owed, live. Toronto time." />
        {past > 0 && <p className="alert alert--warn" role="status" data-testid="past-trips-banner"><span>{past} {past === 1 ? 'trip has' : 'trips have'} ended and {past === 1 ? 'is' : 'are'} not closed. <Link prefetch={false} className="link" href="/admin/bookings/past-trips">Close ended trips</Link></span></p>}
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
  const found = q ? (await ops<Array<{ id: string }>>('bookings_search', { q, status: status === 'out' ? '' : status, limit: 200 })).map((b) => b.id) : null;
  // Bill to: the renter, or an insurer (in full or split)
  const billEq: Record<string, unknown> = sp.bill === 'renter' ? { bill_to: 'renter' } : sp.bill === 'insurer' ? { bill_to: ['insurer', 'split'] } : {};
  const byQ = (eq: Record<string, unknown>) => ({ ...billEq, ...(found ? { ...eq, id: found.length ? found : ['00000000-0000-0000-0000-000000000000'] } : eq) });
  const NONE = '00000000-0000-0000-0000-000000000000';
  const res = outIds
    ? await list<Row>('bookings', { eq: { ...billEq, id: (found ? outIds.filter((x) => found.includes(x)) : outIds).concat(NONE) }, order: 'return_at', asc: true, limit: 200 })
    : await list<Row>('bookings', { eq: byQ(status ? { status } : {}), order: 'pickup_at', limit: 200 });
  // by who supplies the car, or only the rentals added by hand (0046)
  const keep = sp.supply || sp.added ? new Set((await ops<Array<{ id: string }>>('bookings_by_supply', { supply: sp.supply ?? '', added: !!sp.added, status: status === 'out' ? '' : status, limit: 2000 })).map((b) => b.id)) : null;
  const rows = keep ? res.rows.filter((r) => keep.has(r.id)) : res.rows;
  const drafts = await ops<DraftRow[]>('drafts', { kind: 'rental' }).catch(() => [] as DraftRow[]);
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
      <ListFilters id="admin-bookings" base="/admin/bookings?view=all" sp={sp} search={{ placeholder: 'Booking number, name, email, phone, plate, car code or insurer', action: '/admin/bookings' }}
        chips={{ name: 'status', label: 'Status', options: STATUSES }} kept={['bill', 'supply', 'added']} />
      <UnfinishedRentals rows={drafts} base="/admin" />
      {waitingRows.length > 0 && <p className="small" data-testid="bookings-waiting-payment">{waitingRows.length === 1 ? '1 booking is' : `${waitingRows.length} bookings are`} booked with the payment due: the renter accepted the offer and has not paid yet. They are listed first.</p>}
      <BookingRows rows={listed.map((r) => ({ ...r, late: lateLabel(r) }))} cards={cards} base="/admin" at={at} empty={q ? `Nothing matches "${q}".` : 'No bookings with these filters.'} />
    </>
  );
}

type StaffRow = { id: string; booking_number: string; status: string; vehicle_name: string; car_code: string | null; plate: string | null; renter_name: string | null; pickup_at: string; return_at: string; matched: string };
type MyRow = BookingRow & { how: 'credited' | 'added' | 'offer'; commission: { status: string; amount_cents: number } | null };
const COMMISSION: Record<string, [string, 'red' | 'dark' | 'amber' | 'ok' | 'quiet']> = { accruing: ['counting this month', 'amber'], pending_approval: ['waiting for approval', 'amber'], approved: ['approved', 'ok'], paid: ['paid', 'ok'], reversed: ['reversed', 'quiet'], void: ['none', 'quiet'] };
function commissionTag(r: MyRow): Array<[string, 'red' | 'dark' | 'amber' | 'ok' | 'quiet']> {
  if (!r.commission) return [[r.how === 'credited' ? 'Commission: not earned yet' : r.how === 'added' ? 'Added by you' : 'Offered by you', 'quiet']];
  const [w, t] = COMMISSION[r.commission.status] ?? [r.commission.status, 'quiet' as const];
  return [[`Commission ${r.commission.amount_cents ? `${money(r.commission.amount_cents)} ` : ''}${w}`, t]];
}
const MATCHED: Record<string, string> = { number: 'Booking number', renter: 'Renter', driver: 'Driver', email: 'Email', phone: 'Phone', plate: 'Plate', car_code: 'Car code' };

// Find a booking (0200): by its number (CC-1042, cc1042 or 1042), the renter's or a driver's name, an email, a phone
// number, a plate or a car code. Every search is logged, as Find a renter.
async function FindBooking({ ctx, sp }: { ctx: PageCtx; sp: Record<string, string | undefined> }) {
  const { user, aal, ops } = ctx;
  const fn = ctx.viewer.role === 'staff' ? ctx.viewer.fn : null;
  const q = (sp.q ?? '').trim();
  const rows = q.length >= 3 ? await ops<StaffRow[]>('bookings_search', { q, limit: 50 }, true).catch(() => [] as StaffRow[]) : [];
  // Release 26 (0330): the office opens on Now (read-only; the database checks the function). r27 consolidation (0500):
  // every office role, as Admin: finance with the money, Sales without the money and without renters' phones and emails
  const board = !q ? await bookingsNow(user.id, { va: fn, aal }).catch(() => null) : null;
  // Release 26 (0332): every office function sees the bookings they are credited with, sent the offer for or added (Sales:
  // "unable to see his bookings"), with the commission on each
  const mine = !q ? await ops<MyRow[]>('my_bookings', {}, true).catch(() => [] as MyRow[]) : [];
  const at = new Date().getTime();
  const ids = [...rows.map((r) => r.id), ...mine.map((r) => r.id)];
  const cards = ids.length ? await bookingCards(user.id, ids, { va: fn, aal }) : {};
  return (<>
    <PageHead title={board ? 'Bookings now' : 'Bookings'} purpose={board ? 'What is out, coming back, going out and owed, live. Toronto time. Search finds any booking; every search is logged.' : 'Search by booking number, renter or driver name, email, phone, plate or car code. Every search is logged.'}>
      <Search action="/staff/bookings" value={q} placeholder="CC-1042, name, email, phone, plate or car code" />
      <Link prefetch={false} className="btn btn--primary btn--sm" href="/staff/bookings/new" data-testid="add-rental-link">Add a rental</Link></PageHead>
    {board && <BookingsNow initial={board} at={at} src={`/api/staff/bookings-now?va=${fn}`} base={fn === 'sales' ? null : '/staff'} />}
    {!q && (mine.length > 0 || !board) && (
      <section className="bn-sec" aria-labelledby="my-bk-h" data-testid="my-bookings">
        <header className="bn-sec__head"><h2 id="my-bk-h">My bookings <span className="bn-count">{mine.length}</span></h2><p className="bn-sec__note">Credited to you, offered by you or added by you, with your commission</p></header>
        <BookingRows rows={mine.map((r) => ({ ...r, tags: commissionTag(r) }))} cards={cards} base="/staff" at={at} testId="my-bookings-list" empty="No bookings of yours yet. Offers you send and rentals you add show up here." />
      </section>)}
    {!q && !board && <p className="ad-empty" data-testid="booking-search-hint">Search any booking: type at least 3 characters, then press Enter.</p>}
    {q && q.length < 3 && <p className="small muted">Type at least 3 characters.</p>}
    {q.length >= 3 && <BookingRows rows={rows.map((r) => ({ ...r, found: MATCHED[r.matched] ?? r.matched }))} cards={cards} base="/staff" at={at} testId="booking-search" empty={`Nothing matches "${q}".`} />}
  </>);
}
