import Link from 'next/link';
import { notFound } from 'next/navigation';
import { Suspense } from 'react';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { MasterCalendar, type CalData } from '@/features/admin/MasterCalendar';
import { rangeFrom } from '@/features/admin/range';
import { $, Badge, BookingLink, Card, Kv, PageHead, Table, Tabs, t, d, label } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Vehicle', path: '/admin/vehicles', noindex: true, description: 'One vehicle: rates, fees, calendar, listing.' });

type R = Record<string, unknown>;
type V = R & { id: string; name: string; plate: string | null; vin: string; status: string; management_mode: string; class: string | null; colour: string | null; odometer_km: number | null;
  fleet_number: string | null; allows_18_to_20: boolean; bookings_enabled: boolean; home_location: string | null; enrollment_date: string | null; exit_date: string | null;
  owner: { id: string; legal_name: string } | null; listing: R | null; rate_card: R | null; rate_history: R[]; fee_overrides: R[]; classes: string[];
  fee_types: Array<{ code: string; label: string; unit: string; default: { amount_cents: number | null; percent_bps: number | null; source: string } | null }>;
  coverage_prices: R[]; schedule: R | null; terms: R | null; documents: R[]; tracker: { device: R; status: R | null } | null; bookings: R[]; transitions: string[]; intake: R | null };

// One vehicle (03-admin.md section 8.2).
export default async function Vehicle({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ id }, sp] = await Promise.all([params, searchParams]);
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read, list } = await page(`/admin/vehicles/${id}`);
  const v = await read<V | null>('vehicle', { id });
  if (!v) notFound();
  const tab = sp.tab ?? 'overview';
  const base = `/admin/vehicles/${id}`;
  const rc = v.rate_card ?? {};
  const P = { vehicle: id };
  const refresh = [base, '/admin/vehicles'];
  const classes = tab === 'overview' ? (await list<{ code: string; label: string }>('vehicle_classes', { eq: { is_active: true }, order: 'sort_order', asc: true })).rows : [];
  const cal = tab === 'calendar' ? await (async () => { const { from } = rangeFrom(sp.start, 'month'); return read<CalData>('calendar', { from: from.toISOString(), to: new Date(from.getTime() + 31 * 86_400_000).toISOString(), vehicle: id }); })() : null;
  const slug = v.listing?.slug ? String(v.listing.slug) : null;
  return (
    <>
      <PageHead kicker={<><Link className="link" href="/admin/vehicles">Vehicles</Link> · {v.fleet_number ?? ''} {v.plate} · {v.owner ? <Link className="link" href={`/admin/owners/${v.owner.id}`}>{v.owner.legal_name}</Link> : 'no owner'}</>}
        title={<>{v.name} <Badge s={v.status} /></>}>
        {slug && v.listing?.status === 'published' && <Link className="btn btn--ghost btn--sm" href={`/cars/${slug}`} target="_blank">Public page</Link>}
      </PageHead>
      <Tabs current={`${base}?tab=${tab}`} items={[[`${base}?tab=overview`, 'Overview'], [`${base}?tab=rates`, 'Rates'], [`${base}?tab=fees`, 'Fees and coverage'], [`${base}?tab=calendar`, 'Calendar'], [`${base}?tab=listing`, 'Listing'], [`${base}?tab=records`, 'Owner, documents, tracker']]} />
      {tab === 'overview' && (
        <div className="ad-cols ad-cols--2">
          <Card title="Identity and status">
            <Kv rows={[['VIN', v.vin], ['Plate', v.plate ?? ''], ['Class', v.class ?? ''], ['Classes on the site', v.classes.join(', ')], ['Colour', v.colour ?? ''], ['Odometer', v.odometer_km ? `${v.odometer_km.toLocaleString('en-CA')} km` : ''],
              ['Mode', label(v.management_mode)], ['Enrolled', d(v.enrollment_date)], ['Exit date', d(v.exit_date)], ['Drivers 18 to 20', v.allows_18_to_20 ? 'Allowed' : 'Not allowed'], ['Bookings', v.bookings_enabled ? 'Open' : 'Closed']]} />
            <div className="ad-actions">
              {v.transitions.length > 0 && <Act action="vehicle_status" payload={P} label="Change status" fields={[{ name: 'status', label: 'New status', type: 'select', required: true, options: v.transitions.map((s) => [s, label(s)]) }]} refresh={refresh} />}
              <Act action="vehicle_classes" payload={P} label="Classes" fields={[{ name: 'classes', label: 'Classes (comma separated codes)', type: 'list', value: v.classes, hint: classes.map((c) => c.code).join(', ') }]} refresh={refresh} />
            </div>
          </Card>
          <Card title="Edit details">
            <Act inline action="vehicle_save" payload={P} nest="values" label="Save details" refresh={refresh} testId="vehicle-save" fields={[
              { name: 'plate', label: 'Plate', value: v.plate }, { name: 'colour', label: 'Colour', value: v.colour }, { name: 'odometer_km', label: 'Odometer (km)', type: 'number', value: v.odometer_km },
              { name: 'fleet_number', label: 'Fleet number', value: v.fleet_number }, { name: 'class', label: 'Deposit class', type: 'select', value: v.class, options: [['economy', 'Economy'], ['standard', 'Standard'], ['premium', 'Premium'], ['luxury', 'Luxury'], ['exotic', 'Exotic']] },
              { name: 'home_location', label: 'Home area', value: v.home_location }, { name: 'allows_18_to_20', label: 'Drivers aged 18 to 20 allowed', type: 'bool', value: v.allows_18_to_20 },
              { name: 'bookings_enabled', label: 'Open for bookings', type: 'bool', value: v.bookings_enabled }]} />
          </Card>
          <Card title="Bookings"><Table rows={v.bookings} empty="No bookings in the last 120 days." cols={[{ key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'pickup_at', label: 'Pickup', render: (r) => t(r.pickup_at) }, { key: 'return_at', label: 'Return', render: (r) => t(r.return_at) }, { key: 'renter', label: 'Renter' }, { key: 'total_cents', label: 'Total', num: true, render: (r) => $(r.total_cents) }]} /></Card>
        </div>
      )}
      {tab === 'rates' && (
        <div className="stack">
          <Card title="Rates from now" testId="rate-card">
            <p className="small muted">A new rate card starts at the time you choose; bookings already made keep their rates. The public car page updates when you save.</p>
            <Act inline action="rate_card" payload={P} label="Save the rates" testId="rate-form" refresh={refresh} done="New rates saved." fields={[
              { name: 'daily_rate_cents', label: 'Daily', type: 'money', required: true, value: rc.daily_rate_cents }, { name: 'weekend_rate_cents', label: 'Weekend (Friday and Saturday)', type: 'money', required: true, value: rc.weekend_rate_cents },
              { name: 'weekly_rate_cents', label: 'Weekly', type: 'money', required: true, value: rc.weekly_rate_cents }, { name: 'monthly_rate_cents', label: 'Monthly (30 days)', type: 'money', required: true, value: rc.monthly_rate_cents },
              { name: 'effective_from', label: 'Effective from (empty: now)', type: 'datetime' }]} />
            <Act action="rate_card" label="Kilometres, overage, deposit, delivery" title="Other rate card values" payload={{ ...P, daily_rate_cents: rc.daily_rate_cents, weekend_rate_cents: rc.weekend_rate_cents, weekly_rate_cents: rc.weekly_rate_cents, monthly_rate_cents: rc.monthly_rate_cents }} nest="other" refresh={refresh} fields={[
              { name: 'km_allowance_per_day', label: 'Kilometres a day (0 unlimited)', type: 'number', value: rc.km_allowance_per_day }, { name: 'overage_cents_per_km', label: 'Overage per km (cents)', type: 'number', value: rc.overage_cents_per_km },
              { name: 'deposit_cents', label: 'Deposit', type: 'money', value: rc.deposit_cents }, { name: 'delivery_fee_cents', label: 'Delivery fee (0 not offered)', type: 'money', value: rc.delivery_fee_cents }, { name: 'pickup_fee_cents', label: 'Pickup fee (0 not offered)', type: 'money', value: rc.pickup_fee_cents }]} />
          </Card>
          <Card title="Rate history"><Table rows={v.rate_history} cols={[{ key: 'effective_from', label: 'From', render: (r) => t(r.effective_from) }, { key: 'effective_to', label: 'To', render: (r) => t(r.effective_to) },
            { key: 'daily_rate_cents', label: 'Daily', num: true, render: (r) => $(r.daily_rate_cents) }, { key: 'weekend_rate_cents', label: 'Weekend', num: true, render: (r) => $(r.weekend_rate_cents) }, { key: 'weekly_rate_cents', label: 'Weekly', num: true, render: (r) => $(r.weekly_rate_cents) },
            { key: 'monthly_rate_cents', label: 'Monthly', num: true, render: (r) => $(r.monthly_rate_cents) }, { key: 'km_allowance_per_day', label: 'Km a day', num: true }, { key: 'deposit_cents', label: 'Deposit', num: true, render: (r) => $(r.deposit_cents) }, { key: 'set_by_name', label: 'Set by' }]} /></Card>
        </div>
      )}
      {tab === 'fees' && (
        <div className="stack">
          <Card title="Fees for this car" aside={<Act action="vehicle_deposit" payload={P} label="Deposit tier" fields={[{ name: 'amount_cents', label: 'Deposit', type: 'money', required: true, value: rc.deposit_cents }]} refresh={refresh} />}>
            <Table rows={v.fee_types} rowKey={(r) => r.code} cols={[{ key: 'label', label: 'Fee' }, { key: 'unit', label: 'Per' },
              { key: 'default', label: 'In force', num: true, render: (r) => r.default ? (r.default.amount_cents !== null ? $(r.default.amount_cents) : `${(r.default.percent_bps ?? 0) / 100}%`) : null },
              { key: 'source', label: 'From', render: (r) => r.default?.source ?? '' },
              { key: 'act', label: 'Change', render: (r) => <span className="ad-actions"><Act action="fee_override" payload={{ ...P, fee: r.code }} label="Set for this car" title={`${r.label} for this car`} refresh={refresh} fields={[{ name: 'amount_cents', label: 'Amount', type: 'money' }, { name: 'percent_bps', label: 'or percentage', type: 'percent' }, { name: 'reason', label: 'Reason', type: 'text', required: true }]} />
                {r.default?.source === 'vehicle' && <Act action="fee_override_end" payload={{ ...P, fee: r.code }} label="Back to default" refresh={refresh} />}</span> }]} />
          </Card>
          <Card title="Coverage prices (car or class)"><Table rows={v.coverage_prices} empty="The class table applies; set prices in Settings, Coverage." cols={[{ key: 'age_band', label: 'Age band' }, { key: 'amount_cents', label: 'Price', num: true, render: (r) => $(r.amount_cents) }, { key: 'per_day', label: 'Per day' }, { key: 'class_code', label: 'Class' }, { key: 'effective_from', label: 'From' }]} />
            <p className="small"><Link className="link" href="/admin/settings/coverage">Edit the coverage price table</Link></p></Card>
        </div>
      )}
      {tab === 'calendar' && cal && <Suspense><MasterCalendar initial={cal} vehicleId={id} defaultView="month" /></Suspense>}
      {tab === 'listing' && (
        <div className="ad-cols ad-cols--2">
          <Card title="Listing">
            {v.listing ? <Kv rows={[['Status', <Badge key="s" s={String(v.listing.status)} />], ['Address', slug ? <Link key="l" className="link" href={`/cars/${slug}`}>/cars/{slug}</Link> : ''], ['Headline', String(v.listing.headline ?? '')], ['Published', t(v.listing.published_at)], ['Unpublished', `${t(v.listing.unpublished_at)} ${String(v.listing.unpublished_reason ?? '')}`]]} /> : <p className="small muted">No listing yet.</p>}
            <div className="ad-actions">
              {v.intake && <Link className="btn btn--ghost btn--sm" href={`/admin/listings/${String(v.intake.id)}`}>Open the listing review</Link>}
              {!v.intake && <Act action="listing_start" payload={{ vehicle_id: id }} label="Start a listing" go="/admin/listings/{intake_id}" />}
              {v.listing && v.listing.status !== 'published' && <Act action="listing_publish" payload={P} label="Publish" variant="primary" refresh={refresh} />}
              {v.listing?.status === 'published' && <Act action="listing_unlist" payload={P} label="Unlist" variant="danger" refresh={refresh} fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }, { name: 'to_path', label: 'Redirect to (empty: the model page or 410)', type: 'text' }]} />}
            </div>
          </Card>
        </div>
      )}
      {tab === 'records' && (
        <div className="ad-cols ad-cols--2">
          <Card title="Owner terms"><Kv rows={[['Owner', v.owner?.legal_name ?? ''], ['Schedule', v.schedule ? String(v.schedule.schedule_number ?? '') : 'none'], ['Insurance Fee', $(v.terms?.insurance_fee_cents)], ['Tracker Fee', $(v.terms?.tracker_fee_cents)], ['Revenue Share', v.terms?.revenue_share_bps !== undefined ? `${Number(v.terms?.revenue_share_bps) / 100}%` : '']]} />
            {v.terms && <Act action="fee_change_notice" payload={P} label="Fee change notice" fields={[{ name: 'insurance_fee_cents', label: 'New Insurance Fee', type: 'money', required: true, value: v.terms.insurance_fee_cents }, { name: 'tracker_fee_cents', label: 'New Tracker Fee', type: 'money', required: true, value: v.terms.tracker_fee_cents }, { name: 'effective_from', label: 'Effective (30 days or more ahead)', type: 'date', required: true }, { name: 'reason', label: 'Reason', type: 'text' }]} refresh={refresh} />}</Card>
          <Card title="Tracker">{v.tracker ? <Kv rows={[['Device', String(v.tracker.device.serial_number ?? '')], ['Last seen', t(v.tracker.device.last_seen_at)], ['Speed', v.tracker.status ? `${String(v.tracker.status.speed_kmh)} km/h` : ''], ['Ignition', v.tracker.status ? (v.tracker.status.ignition_on ? 'on' : 'off') : ''], ['Locked', v.tracker.status ? String(v.tracker.status.locked) : '']]} /> : <p className="small muted">No tracker installed.</p>}</Card>
          <Card title="Documents"><Table rows={v.documents} empty="No documents." cols={[{ key: 'title', label: 'Title' }, { key: 'kind', label: 'Kind' }, { key: 'created_at', label: 'Added', render: (r) => t(r.created_at) }]} /></Card>
        </div>
      )}
    </>
  );
}
