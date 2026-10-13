import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Act } from '@/features/admin/Act';
import { Badge, Card, Kv, PageHead, Search, Table, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Find a renter', path: '/va/renters', noindex: true, description: 'Look up a renter.' });

type Found = { renter_id: string; legal_name: string; last_booking_number: string | null; in_window: boolean };
type View = { id: string; legal_name: string; email: string | null; mobile: string | null; identity_status: string; is_blocked: boolean; access_until: string | null;
  bookings: Array<{ booking_number: string; status: string; pickup_at: string; return_at: string; vehicle: string }> };

// "Find a renter" (05-va.md section 4.4): there is no customer list. At least 3 characters, at most 10 names,
// every search logged; a record outside the window (no live booking, 90 days after, no open task) opens
// for 24 hours with a reason, also logged.
export default async function Renters({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { read } = await vaPage('/va/renters', ['cs', 'finance', 'fleet']);
  const q = (sp.q ?? '').trim();
  const [found, view] = await Promise.all([
    q.length >= 3 ? read<Found[]>('find_renter', { q }).catch(() => [] as Found[]) : Promise.resolve([] as Found[]),
    sp.id && /^[0-9a-f-]{36}$/.test(sp.id) ? read<View | null>('renter', { id: sp.id }).catch(() => null) : Promise.resolve(null)]);
  return (<>
    <PageHead title="Find a renter"><Search action="/va/renters" value={q} placeholder="Name, email or booking number" /></PageHead>
    {q && q.length < 3 && <p className="small muted">Type at least 3 characters.</p>}
    {q.length >= 3 && <Card title="Matches" testId="renter-matches"><Table rows={found as unknown as Array<Record<string, unknown>>} empty="Nobody matches." cols={[
      { key: 'legal_name', label: 'Name' }, { key: 'last_booking_number', label: 'Last booking' },
      { key: 'act', label: '', render: (r) => r.in_window ? <Link prefetch={false} className="link" href={`/va/renters?q=${encodeURIComponent(q)}&id=${String(r.renter_id)}`}>Open</Link>
        : <Act action="open_renter" payload={{ renter: r.renter_id }} label="Open with a reason" testId={`open-${String(r.renter_id)}`} go={`/va/renters?q=${encodeURIComponent(q)}&id=${String(r.renter_id)}`}
            fields={[{ name: 'reason', label: 'Why you need this record (kept in the access log)', type: 'text', required: true }]} /> }]} /></Card>}
    {view && <Card title={view.legal_name} testId="renter-view" aside={view.is_blocked ? <Badge s="blocked">Blocked</Badge> : null}>
      <Kv rows={[['Email', view.email ?? ''], ['Mobile', view.mobile ?? ''], ['Identity', view.identity_status.replace(/_/g, ' ')], ['Access', view.access_until ? `opened until ${t(view.access_until)}` : 'in window']]} />
      <Table rows={view.bookings as unknown as Array<Record<string, unknown>>} empty="No bookings." cols={[{ key: 'booking_number', label: 'Booking', render: (r) => <Link prefetch={false} className="link" href={`/va/bookings/${encodeURIComponent(String(r.booking_number))}`}>{String(r.booking_number)}</Link> },
        { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'vehicle', label: 'Car' }, { key: 'pickup_at', label: 'Pickup', render: (r) => t(r.pickup_at) }]} />
    </Card>}
  </>);
}
