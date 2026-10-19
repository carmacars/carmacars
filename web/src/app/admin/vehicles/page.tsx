import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, BookingLink, Filters, PageHead, Search, Table, t } from '@/features/admin/ui';
import { door } from '@/server/door';
import '@/features/live/live.css';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Vehicles', path: '/admin/vehicles', noindex: true, description: 'The fleet.' });

type V = { id: string; fleet_number: string | null; name: string; plate: string | null; owner_name: string | null; management_mode: string; status: string; listing_status: string | null;
  daily_rate_cents: number | null; next_booking: { booking_number: string; pickup_at: string } | null; tracker_seen: string | null; in_arrears: boolean; on_fleet_policy: boolean; class: string | null;
  supply_type: string; supply_label: string; partner_id: string | null; retired_at: string | null; is_sample: boolean };

// The fleet (03-admin.md section 8.1).
export default async function Vehicles({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, user }, sp] = await Promise.all([page('/admin/vehicles'), searchParams]);
  const [all, settings, viewed] = await Promise.all([read<V[]>('vehicles'), door<{ sample_cars: number }>(user.id, 'ops_read', 'supply_settings').catch(() => ({ sample_cars: 0 })),
    read<Array<{ vehicle_id: string; car: string; views_today: number; views_7d: number; looking_now: number; requests_7d: number }>>('most_viewed', { days: 7, limit: 5 }).catch(() => [])]);
  const s = (sp.q ?? '').toLowerCase();
  const rows = all.filter((v) => (!sp.status || v.status === sp.status) && (!sp.mode || v.management_mode === sp.mode)
    && (!sp.supply || v.supply_type === sp.supply) && (sp.retired === 'show' ? true : sp.retired === 'only' ? !!v.retired_at : !v.retired_at) && (!s || `${v.name} ${v.plate} ${v.fleet_number} ${v.owner_name}`.toLowerCase().includes(s)));
  const statuses = [...new Set(all.map((v) => v.status))];
  return (
    <>
      <PageHead title="Vehicles" kicker={`${rows.length} of ${all.length}`}>
        <Search action="/admin/vehicles" value={sp.q} placeholder="Plate, model, owner" />
        <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/vehicles/new" data-testid="add-car-link">Add a car</Link>
        <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/vehicles/bulk-rates">Bulk rate change</Link>
        {settings.sample_cars > 0 && <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/vehicles/samples" data-testid="sample-cars-link">Sample cars ({settings.sample_cars})</Link>}
        <Act action="listing_start" label="Start a listing" variant="primary" fields={[{ name: 'plate', label: 'Plate', type: 'text' }, { name: 'vin', label: 'or VIN', type: 'text' }, { name: 'notes', label: 'Notes', type: 'text' }]} go="/admin/listings/{intake_id}" />
      </PageHead>
      <Filters base="/admin/vehicles" name="status" value={sp.status ?? ''} options={[['', 'All'], ...statuses.map((x) => [x, x.replace(/_/g, ' ')] as [string, string])]} sp={sp} />
      {sp.deleted && <p className="alert alert--ok" role="status"><span>The car was deleted.</span></p>}
      <Filters base="/admin/vehicles" name="supply" value={sp.supply ?? ''} options={[['', 'Every supplier'], ['program_owner', 'Program owners'], ['company', 'CarmaCars-owned'], ['partner', 'Partners']]} sp={sp} />
      <Filters base="/admin/vehicles" name="retired" value={sp.retired ?? ''} options={[['', 'In the fleet'], ['only', 'Retired'], ['show', 'All, retired too']]} sp={sp} />
      <Filters base="/admin/vehicles" name="mode" value={sp.mode ?? ''} options={[['', 'Any mode'], ['managed', 'Managed'], ['self_managed', 'Self-Managed'], ['turo_only', 'Turo-Only']]} sp={sp} />
      {viewed.length > 0 && (
        <details className="pt-card ad-card" data-testid="most-viewed-cars"><summary className="link">Most viewed cars this week</summary>
          <ol className="lt-list">{viewed.map((c) => <li key={c.vehicle_id}><Link prefetch={false} className="link" href={`/admin/vehicles/${c.vehicle_id}`}>{c.car}</Link> <span className="small muted">{c.views_7d} views, {c.views_today} today, {c.requests_7d} requests{c.looking_now ? `, ${c.looking_now} looking now` : ''}</span></li>)}</ol>
          <p className="small"><Link prefetch={false} className="link" href="/admin/live">Live visitors</Link></p>
        </details>)}
      <Table<V> testId="vehicles" caption="Vehicles" rows={rows} empty="No vehicles yet. Press Add a car to add one, or approve an owner application." cols={[
        { key: 'fleet_number', label: 'No.' },
        { key: 'name', label: 'Vehicle', render: (v) => <Link prefetch={false} className="link" href={`/admin/vehicles/${v.id}`}>{v.name}</Link> },
        { key: 'plate', label: 'Plate' }, { key: 'class', label: 'Class' }, { key: 'owner_name', label: 'Supplied by', render: (v) => <>{v.owner_name}<span className="small muted"> · {v.supply_label}</span></> },
        { key: 'management_mode', label: 'Mode', render: (v) => v.management_mode.replace(/_/g, ' ') },
        { key: 'status', label: 'Status', render: (v) => v.retired_at ? <Badge s="retired">Retired</Badge> : <Badge s={v.status} /> },
        { key: 'listing_status', label: 'Listing', render: (v) => v.listing_status ? <Badge s={v.listing_status} /> : null },
        { key: 'daily', label: 'Daily', num: true, render: (v) => $(v.daily_rate_cents) },
        { key: 'next', label: 'Next booking', render: (v) => v.next_booking ? <><BookingLink n={v.next_booking.booking_number} /> {t(v.next_booking.pickup_at)}</> : null },
        { key: 'tracker_seen', label: 'Tracker seen', render: (v) => t(v.tracker_seen) },
        { key: 'flags', label: 'Flags', render: (v) => <>{v.in_arrears && <span className="ad-flag ad-flag--red">arrears</span>}{v.on_fleet_policy && <span className="ad-flag">fleet policy</span>}</> }
      ]} />
    </>
  );
}
