import Link from '@/components/Link';
import { ListFilters } from '@/features/list-filters/ListFilters';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, BookingLink, Card, PageHead, Table, t } from '@/features/admin/ui';
import { SampleCarsToggle } from '@/features/supply/SampleCarsToggle';
import { door } from '@/server/door';
import '@/features/live/live.css';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Vehicles', path: '/admin/vehicles', noindex: true, description: 'The fleet.' });

type Gate = { code: string; label: string; action: string; who: string | null };
type NotPublic = { vehicle_id: string; name: string; status: string; gates: Gate[]; next: string | null; sample_photos: boolean };
type V = { id: string; fleet_number: string | null; name: string; plate: string | null; owner_name: string | null; management_mode: string; status: string; listing_status: string | null;
  daily_rate_cents: number | null; next_booking: { booking_number: string; pickup_at: string } | null; tracker_seen: string | null; in_arrears: boolean; on_fleet_policy: boolean; class: string | null;
  supply_type: string; supply_label: string; partner_id: string | null; retired_at: string | null; is_sample: boolean; seats?: number | null; seats_missing?: boolean;
  /** r43 (2690): the photo the site shows first: exterior, not_exterior (an inside photo) or none */ primary_photo?: 'exterior' | 'not_exterior' | 'none'; primary_not_exterior?: boolean };

// The fleet (03-admin.md section 8.1).
export default async function Vehicles({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, user }, sp] = await Promise.all([page('/admin/vehicles'), searchParams]);
  const [all, settings, viewed] = await Promise.all([read<V[]>('vehicles'), door<{ sample_cars: number }>(user.id, 'ops_read', 'supply_settings').catch(() => ({ sample_cars: 0 })),
    read<Array<{ vehicle_id: string; car: string; views_today: number; views_7d: number; looking_now: number; requests_7d: number }>>('most_viewed', { days: 7, limit: 5 }).catch(() => [])]);
  // 0065: the sample cars on the site, and why each real car is not on the site yet
  const [samples, notPublic] = await Promise.all([door<{ public: number; cars: number }>(user.id, 'ops_read', 'sample_cars_state').catch(() => null),
    door<NotPublic[]>(user.id, 'ops_read', 'cars_not_public').catch(() => [] as NotPublic[])]);
  const s = (sp.q ?? '').toLowerCase();
  const rows = all.filter((v) => (!sp.status || v.status === sp.status) && (!sp.mode || v.management_mode === sp.mode)
    && (!sp.supply || v.supply_type === sp.supply) && (sp.retired === 'show' ? true : sp.retired === 'only' ? !!v.retired_at : !v.retired_at) && (sp.photo !== 'not_exterior' || !!v.primary_not_exterior) && (!s || `${v.name} ${v.plate} ${v.fleet_number} ${v.owner_name} ${v.supply_type} ${v.management_mode} ${v.supply_type.replace(/_/g, ' ')} ${v.management_mode.replace(/_/g, ' ')}`.toLowerCase().includes(s)));
  // the five chips are the statuses most cars are in (the rest under More)
  const statuses = [...all.reduce((m, v) => m.set(v.status, (m.get(v.status) ?? 0) + 1), new Map<string, number>())].sort((a, z) => z[1] - a[1]).map(([x]) => x);
  return (
    <>
      <PageHead title="Vehicles" kicker={`${rows.length} of ${all.length}`} purpose="The fleet. Open a car for its rates, calendar, photos, documents and money.">
        <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/vehicles/new" data-testid="add-car-link">Add a car</Link>
        <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/vehicles/bulk-rates">Bulk rate change</Link>
        <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/vehicles/incident-cards" data-testid="incident-cards-link">Incident cards</Link>
        {settings.sample_cars > 0 && <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/vehicles/samples" data-testid="sample-cars-link">Sample cars ({settings.sample_cars})</Link>}
        {samples && <SampleCarsToggle publicCount={samples.public} compact />}
        <Act action="listing_start" label="Start a listing" variant="primary" fields={[{ name: 'plate', label: 'Plate', type: 'text' }, { name: 'vin', label: 'or VIN', type: 'vin' }, { name: 'notes', label: 'Notes', type: 'text' }]} go="/admin/listings/{intake_id}" />
      </PageHead>
      {/* 0400: the list and Fleet tracking are the two views of Cars */}
      <ListFilters id="admin-vehicles" base="/admin/vehicles" sp={sp} search={{ placeholder: 'Plate, model, owner, fleet number, supplier or mode' }}
        chips={{ name: 'status', label: 'Status', options: [['', 'All'], ...statuses.slice(0, 4).map((x) => [x, x.replace(/_/g, ' ')] as [string, string])] }} kept={['supply', 'mode', 'retired', 'photo']} />
      {sp.deleted && <p className="alert alert--ok" role="status"><span>The car was deleted.</span></p>}
      {notPublic.length > 0 && (
        <Card title={`Not on the site yet (${notPublic.length})`} testId="cars-not-public">
          <p className="small muted">Each real car with what is left before it is on the site, the next step first. A car without photos shows sample photos once it is listed.</p>
          <ul className="lt-list">{notPublic.map((c) => (
            <li key={c.vehicle_id} data-testid="car-not-public"><Link prefetch={false} className="link" href={`/admin/vehicles/${c.vehicle_id}`}>{c.name}</Link>{' '}
              <span className="small">Next: {c.next ?? 'nothing'}{c.gates.length > 1 ? ` (then ${c.gates.slice(1).map((g) => g.label.toLowerCase()).join(', ')})` : ''}</span>
              {c.sample_photos && <span className="ad-flag">sample photos</span>}</li>))}</ul>
        </Card>)}
      {viewed.length > 0 && (
        <details className="pt-card ad-card" data-testid="most-viewed-cars"><summary className="link">Most viewed cars this week</summary>
          <ol className="lt-list">{viewed.map((c) => <li key={c.vehicle_id}><Link prefetch={false} className="link" href={`/admin/vehicles/${c.vehicle_id}`}>{c.car}</Link> <span className="small muted">{c.views_7d} views, {c.views_today} today, {c.requests_7d} requests{c.looking_now ? `, ${c.looking_now} looking now` : ''}</span></li>)}</ol>
          <p className="small"><Link prefetch={false} className="link" href="/admin/visitors">Visitors</Link></p>
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
        { key: 'flags', label: 'Flags', render: (v) => <>{v.in_arrears && <span className="ad-flag ad-flag--red">arrears</span>}{v.on_fleet_policy && <span className="ad-flag">fleet policy</span>}{v.seats_missing && <span className="ad-flag ad-flag--red" data-testid="seats-missing" title="The seat count is not known: the 7+ seats filter cannot show it. Set the seats on the listing review, or confirm them on Today.">Seats missing</span>}{v.primary_not_exterior && <span className="ad-flag ad-flag--red" data-testid="primary-not-exterior" title="The photo shown first on the site is an inside photo: its front three-quarter outside photo is not on the site yet, or the car has none. Open the car and press Redo photos with Gemini, or check its plates.">Primary photo is not exterior</span>}</> }
      ]} />
      {/* r43 (2690): the cars whose first photo on the site is an inside one */}
      {(() => { const n = all.filter((v) => v.primary_not_exterior && !v.retired_at).length; return n > 0 || sp.photo ? (
        <p className="small" data-testid="primary-not-exterior-link">{sp.photo === 'not_exterior' ? <Link prefetch={false} className="link" href="/admin/vehicles">Show every car</Link>
          : <Link prefetch={false} className="link" href="/admin/vehicles?photo=not_exterior">Primary photo is not exterior ({n})</Link>}</p>) : null; })()}
      {/* r32: retired cars are a link (a saved view), not a filter */}
      <p className="small" data-testid="retired-cars-link">{sp.retired ? <Link prefetch={false} className="link" href="/admin/vehicles">Back to the fleet</Link>
        : <Link prefetch={false} className="link" href="/admin/vehicles?retired=only">Retired cars</Link>}</p>
    </>
  );
}
