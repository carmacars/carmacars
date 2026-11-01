import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead, Search } from '@/features/admin/ui';
import { BookingRows, type BookingRow } from '@/features/bookings-now/BookingRows';
import { money } from '@/features/bookings-now/model';
import { BookingsNow } from '@/features/bookings-now/BookingsNow';
import { bookingCards, bookingsNow } from '@/server/bookings-now';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Bookings', path: '/staff/bookings', noindex: true, description: 'What is out, coming back and going out now, and find a booking.' });

type Row = { id: string; booking_number: string; status: string; vehicle_name: string; car_code: string | null; plate: string | null; renter_name: string | null; pickup_at: string; return_at: string; matched: string };
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
export default async function FindBooking({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user, aal, fn }, sp] = await Promise.all([vaPage('/staff/bookings'), searchParams]);
  const q = (sp.q ?? '').trim();
  const rows = q.length >= 3 ? await door<Row[]>(user.id, 'ops_read', 'bookings_search', { q, limit: 50, _va: fn }, aal).catch(() => [] as Row[]) : [];
  // Release 26 (0330): fleet and customer service open on Now (read-only; the database checks the function)
  const board = !q && (fn === 'fleet' || fn === 'cs') ? await bookingsNow(user.id, { va: fn, aal }).catch(() => null) : null;
  // Release 26 (0332): every office function sees the bookings they are credited with, sent the offer for or added (Sales:
  // "unable to see his bookings"), with the commission on each
  const mine = !q ? await door<MyRow[]>(user.id, 'ops_read', 'my_bookings', { _va: fn }, aal).catch(() => [] as MyRow[]) : [];
  const at = new Date().getTime();
  const ids = [...rows.map((r) => r.id), ...mine.map((r) => r.id)];
  const cards = ids.length ? await bookingCards(user.id, ids, { va: fn, aal }) : {};
  return (<>
    <PageHead title={board ? 'Bookings now' : 'Bookings'} purpose={board ? 'What is out, coming back, going out and owed, live. Toronto time. Search finds any booking; every search is logged.' : 'Search by booking number, renter or driver name, email, phone, plate or car code. Every search is logged.'}>
      <Search action="/staff/bookings" value={q} placeholder="CC-1042, name, email, phone, plate or car code" /></PageHead>
    {board && <BookingsNow initial={board} at={at} src={`/api/staff/bookings-now?va=${fn}`} base="/staff" />}
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
