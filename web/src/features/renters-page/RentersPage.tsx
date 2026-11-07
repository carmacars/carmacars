import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { Badge, Card, Kv, PageHead, Search, Table, d, t } from '@/features/admin/ui';
import { tabOf } from '@/features/admin/hubs';
import { Leads } from '@/app/admin/renters/Leads';
import type { PageCtx } from '@/features/shared-pages/context';

// r31 "Simple": one Renters page for Admin and staff. An Admin sees every renter (and the Leads tab); staff find a renter
// (05-va.md section 4.4): there is no customer list for them, at least 3 characters, at most 10 names, every search
// logged, and a record outside its window (no live booking, 90 days after, no open task) opens for 24 hours with a
// reason, also logged. The database decides both (admin_list renters, va_read find_renter and renter).
type Row = { id: string; legal_name: string; email: string | null; mobile: string | null; identity_status: string; is_blocked: boolean; created_at: string };
type Found = { renter_id: string; legal_name: string; last_booking_number: string | null; in_window: boolean };
type View = { id: string; legal_name: string; email: string | null; mobile: string | null; identity_status: string; is_blocked: boolean; access_until: string | null;
  bookings: Array<{ booking_number: string; status: string; pickup_at: string; return_at: string; vehicle: string }> };

export async function RentersPage({ ctx, sp }: { ctx: PageCtx; sp: Record<string, string | undefined> }) {
  return ctx.viewer.role === 'admin' ? AdminRenters({ ctx, sp }) : FindRenter({ ctx, sp });
}

async function AdminRenters({ ctx, sp }: { ctx: PageCtx; sp: Record<string, string | undefined> }) {
  // r27: Renter leads is the Leads tab here (/admin/leads redirects)
  if (tabOf(['renters', 'leads'] as const, sp.tab) === 'leads') return <Leads ctx={ctx} sp={sp} />;
  const { list } = ctx;
  const res = await list<Row>('renters', { q: sp.q, order: 'created_at', limit: 200 });
  return (
    <>
      <PageHead title="Renters" kicker={`${res.count} found`}>
        <Search action="/admin/renters" value={sp.q} placeholder="Name, email or phone" />
        <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/bookings/new">Add a rental</Link>
      </PageHead>
      <Table<Row> testId="renters" caption="Renters" rows={res.rows} empty={sp.q ? `No renter matches "${sp.q}". Search by part of the name, the email or the phone number.` : 'No renters yet. They appear here after their first booking request, or when you add a rental.'} cols={[
        { key: 'legal_name', label: 'Renter', render: (r) => <><Link prefetch={false} className="link" href={`/admin/renters/${r.id}`}>{r.legal_name}</Link> <Link prefetch={false} className="small link" href={`/admin/bookings?q=${encodeURIComponent(r.email ?? r.legal_name)}`}>bookings</Link></> },
        { key: 'email', label: 'Email' }, { key: 'mobile', label: 'Phone' },
        { key: 'identity_status', label: 'Identity', render: (r) => <Badge s={r.identity_status} /> },
        { key: 'is_blocked', label: 'Blocked', render: (r) => (r.is_blocked ? 'Yes' : 'No') },
        { key: 'created_at', label: 'Since', render: (r) => d(r.created_at) }
      ]} />
    </>
  );
}

async function FindRenter({ ctx, sp }: { ctx: PageCtx; sp: Record<string, string | undefined> }) {
  const { read } = ctx;
  const q = (sp.q ?? '').trim();
  const [found, view] = await Promise.all([
    q.length >= 3 ? read<Found[]>('find_renter', { q }).catch(() => [] as Found[]) : Promise.resolve([] as Found[]),
    sp.id && /^[0-9a-f-]{36}$/.test(sp.id) ? read<View | null>('renter', { id: sp.id }).catch(() => null) : Promise.resolve(null)]);
  return (<>
    <PageHead title="Find a renter" purpose="Search by name, email or booking number. Every search is logged, and a record outside its window opens for 24 hours with a reason."><Search action="/staff/renters" value={q} placeholder="Name, email or booking number" /></PageHead>
    {!q && !view && <p className="ad-empty" data-testid="renter-hint">Type at least 3 characters of a name, email or booking number, then press Enter. Press / to jump to the search box.</p>}
    {q && q.length < 3 && <p className="small muted">Type at least 3 characters.</p>}
    {q.length >= 3 && <Card title="Matches" testId="renter-matches"><Table rows={found as unknown as Array<Record<string, unknown>>} empty="Nobody matches." cols={[
      { key: 'legal_name', label: 'Name' }, { key: 'last_booking_number', label: 'Last booking' },
      { key: 'act', label: '', render: (r) => r.in_window ? <Link prefetch={false} className="link" href={`/staff/renters?q=${encodeURIComponent(q)}&id=${String(r.renter_id)}`}>Open</Link>
        : <Act action="open_renter" payload={{ renter: r.renter_id }} label="Open with a reason" testId={`open-${String(r.renter_id)}`} go={`/staff/renters?q=${encodeURIComponent(q)}&id=${String(r.renter_id)}`}
            fields={[{ name: 'reason', label: 'Why you need this record (kept in the access log)', type: 'text', required: true }]} /> }]} /></Card>}
    {view && <Card title={view.legal_name} testId="renter-view" aside={view.is_blocked ? <Badge s="blocked">Blocked</Badge> : null}>
      <Kv rows={[['Email', view.email ?? ''], ['Mobile', view.mobile ?? ''], ['Identity', view.identity_status.replace(/_/g, ' ')], ['Access', view.access_until ? `opened until ${t(view.access_until)}` : 'in window']]} />
      <Table rows={view.bookings as unknown as Array<Record<string, unknown>>} empty="No bookings." cols={[{ key: 'booking_number', label: 'Booking', render: (r) => <Link prefetch={false} className="link" href={`/staff/bookings/${encodeURIComponent(String(r.booking_number))}`}>{String(r.booking_number)}</Link> },
        { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'vehicle', label: 'Car' }, { key: 'pickup_at', label: 'Pickup', render: (r) => t(r.pickup_at) }]} />
    </Card>}
  </>);
}
