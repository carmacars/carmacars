import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, BookingLink, Filters, PageHead, Search, Table, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Vehicles', path: '/admin/vehicles', noindex: true, description: 'The fleet.' });

type V = { id: string; fleet_number: string | null; name: string; plate: string | null; owner_name: string | null; management_mode: string; status: string; listing_status: string | null;
  daily_rate_cents: number | null; next_booking: { booking_number: string; pickup_at: string } | null; tracker_seen: string | null; in_arrears: boolean; on_fleet_policy: boolean; class: string | null };

// The fleet (03-admin.md section 8.1).
export default async function Vehicles({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/vehicles'), searchParams]);
  const all = await read<V[]>('vehicles');
  const s = (sp.q ?? '').toLowerCase();
  const rows = all.filter((v) => (!sp.status || v.status === sp.status) && (!sp.mode || v.management_mode === sp.mode) && (!s || `${v.name} ${v.plate} ${v.fleet_number} ${v.owner_name}`.toLowerCase().includes(s)));
  const statuses = [...new Set(all.map((v) => v.status))];
  return (
    <>
      <PageHead title="Vehicles" kicker={`${rows.length} of ${all.length}`}>
        <Search action="/admin/vehicles" value={sp.q} placeholder="Plate, model, owner" />
        <Link className="btn btn--ghost btn--sm" href="/admin/vehicles/bulk-rates">Bulk rate change</Link>
        <Act action="listing_start" label="Start a listing" variant="primary" fields={[{ name: 'plate', label: 'Plate', type: 'text' }, { name: 'vin', label: 'or VIN', type: 'text' }, { name: 'notes', label: 'Notes', type: 'text' }]} go="/admin/listings/{intake_id}" />
      </PageHead>
      <Filters base="/admin/vehicles" name="status" value={sp.status ?? ''} options={[['', 'All'], ...statuses.map((x) => [x, x.replace(/_/g, ' ')] as [string, string])]} sp={sp} />
      <Filters base="/admin/vehicles" name="mode" value={sp.mode ?? ''} options={[['', 'Any mode'], ['managed', 'Managed'], ['self_managed', 'Self-Managed'], ['turo_only', 'Turo-Only']]} sp={sp} />
      <Table<V> testId="vehicles" caption="Vehicles" rows={rows} empty="No vehicles yet." cols={[
        { key: 'fleet_number', label: 'No.' },
        { key: 'name', label: 'Vehicle', render: (v) => <Link className="link" href={`/admin/vehicles/${v.id}`}>{v.name}</Link> },
        { key: 'plate', label: 'Plate' }, { key: 'class', label: 'Class' }, { key: 'owner_name', label: 'Owner' },
        { key: 'management_mode', label: 'Mode', render: (v) => v.management_mode.replace(/_/g, ' ') },
        { key: 'status', label: 'Status', render: (v) => <Badge s={v.status} /> },
        { key: 'listing_status', label: 'Listing', render: (v) => v.listing_status ? <Badge s={v.listing_status} /> : null },
        { key: 'daily', label: 'Daily', num: true, render: (v) => $(v.daily_rate_cents) },
        { key: 'next', label: 'Next booking', render: (v) => v.next_booking ? <><BookingLink n={v.next_booking.booking_number} /> {t(v.next_booking.pickup_at)}</> : null },
        { key: 'tracker_seen', label: 'Tracker seen', render: (v) => t(v.tracker_seen) },
        { key: 'flags', label: 'Flags', render: (v) => <>{v.in_arrears && <span className="ad-flag ad-flag--red">arrears</span>}{v.on_fleet_policy && <span className="ad-flag">fleet policy</span>}</> }
      ]} />
    </>
  );
}
