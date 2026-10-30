import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { Badge, PageHead, Search, Table, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Find a booking', path: '/staff/bookings', noindex: true, description: 'Find a booking.' });

type Row = { id: string; booking_number: string; status: string; vehicle_name: string; car_code: string | null; plate: string | null; renter_name: string | null; pickup_at: string; return_at: string; matched: string };
const MATCHED: Record<string, string> = { number: 'Booking number', renter: 'Renter', driver: 'Driver', email: 'Email', phone: 'Phone', plate: 'Plate', car_code: 'Car code' };

// Find a booking (0200): by its number (CC-1042, cc1042 or 1042), the renter's or a driver's name, an email, a phone
// number, a plate or a car code. Every search is logged, as Find a renter.
export default async function FindBooking({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user, aal, fn }, sp] = await Promise.all([vaPage('/staff/bookings'), searchParams]);
  const q = (sp.q ?? '').trim();
  const rows = q.length >= 3 ? await door<Row[]>(user.id, 'ops_read', 'bookings_search', { q, limit: 50, _va: fn }, aal).catch(() => [] as Row[]) : [];
  return (<>
    <PageHead title="Find a booking" purpose="Search by booking number, renter or driver name, email, phone, plate or car code. Every search is logged.">
      <Search action="/staff/bookings" value={q} placeholder="CC-1042, name, email, phone, plate or car code" /></PageHead>
    {!q && <p className="ad-empty" data-testid="booking-search-hint">Type at least 3 characters, then press Enter.</p>}
    {q && q.length < 3 && <p className="small muted">Type at least 3 characters.</p>}
    {q.length >= 3 && <Table<Row> testId="booking-search" caption="Bookings found" rows={rows} empty={`Nothing matches "${q}".`} cols={[
      { key: 'booking_number', label: 'Booking', render: (r) => <Link prefetch={false} className="link" href={`/staff/bookings/${encodeURIComponent(r.booking_number)}`}>{r.booking_number}</Link> },
      { key: 'status', label: 'Status', render: (r) => <Badge s={r.status} /> },
      { key: 'vehicle_name', label: 'Car', render: (r) => [r.vehicle_name, r.car_code, r.plate].filter(Boolean).join(' · ') },
      { key: 'renter_name', label: 'Renter' },
      { key: 'pickup_at', label: 'Pickup', render: (r) => t(r.pickup_at) },
      { key: 'matched', label: 'Found by', render: (r) => MATCHED[r.matched] ?? r.matched }]} />}
  </>);
}
