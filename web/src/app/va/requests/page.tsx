import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { $, ago, Badge, Filters, PageHead, Table, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Requests', path: '/va/requests', noindex: true, description: 'Booking requests and offers out.' });

type Req = { id: string; booking_number: string; status: string; state: string; vehicle: string; renter: string; returning: boolean; pickup_at: string; return_at: string; days: number;
  total_cents: number; waiting_minutes: number; offer_expires_at: string | null; flags: string[] };

// The requests inbox (05-va.md section 4.1, 03-admin.md section 3): oldest first; each opens the review-and-offer screen.
export default async function VaRequests({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([vaPage('/va/requests', ['cs', 'sales']), searchParams]);
  const all = await read<Req[]>('requests');
  const state = sp.state ?? '';
  const rows = all.filter((r) => !state || r.state === state);
  return (
    <>
      <PageHead title="Requests" kicker={`${all.filter((r) => r.status === 'requested').length} waiting`} />
      <Filters base="/va/requests" name="state" value={state} sp={sp} options={[['', 'All'], ['new', 'New'], ['waiting_on_renter', 'Waiting on the renter'], ['pushed_back', 'Pushed back'], ['offer_out', 'Offer out'], ['expired', 'Offer expired']]} />
      <Table<Req> testId="requests" caption="Booking requests" rows={rows} empty="No requests waiting." cols={[
        { key: 'waiting', label: 'Waiting', render: (r) => <span className={r.status === 'requested' && r.waiting_minutes > 120 ? 'ad-late' : undefined}>{ago(r.waiting_minutes)}</span> },
        { key: 'booking_number', label: 'Booking', render: (r) => <Link prefetch={false} className="link" href={`/va/bookings/${encodeURIComponent(r.booking_number)}`}>{r.booking_number}</Link> },
        { key: 'state', label: 'State', render: (r) => <Badge s={r.status}>{r.state.replace(/_/g, ' ')}</Badge> }, { key: 'vehicle', label: 'Car' },
        { key: 'pickup_at', label: 'Pickup', render: (r) => t(r.pickup_at) }, { key: 'return_at', label: 'Return', render: (r) => t(r.return_at) },
        { key: 'renter', label: 'Renter', render: (r) => <>{r.renter} <span className="muted small">{r.returning ? 'returning' : 'new'}</span></> },
        { key: 'total_cents', label: 'Total', num: true, render: (r) => $(r.total_cents) },
        { key: 'flags', label: 'Flags', className: 'wrap', render: (r) => r.flags.map((f) => <span key={f} className="ad-flag">{f}</span>) }]} />
    </>
  );
}
