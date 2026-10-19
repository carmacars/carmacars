import Link from 'next/link';
import '@/features/live/live.css';
import { CarInterest, type Interest } from '@/features/live/CarInterest';
import { notFound } from 'next/navigation';
import { Suspense } from 'react';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { MasterCalendar, type CalData } from '@/features/admin/MasterCalendar';
import { rangeFrom } from '@/features/admin/range';
import { $, Badge, BookingLink, Card, Kv, PageHead, Table, Tabs, t, d, label } from '@/features/admin/ui';

import { TRACKER_SOON } from '@/integrations/tracker/types';
import { DeleteCar } from '@/features/supply/DeleteCar';
import { door } from '@/server/door';
import { adminOwners } from '@/server/admin/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Vehicle', path: '/admin/vehicles', noindex: true, description: 'One vehicle: rates, fees, calendar, listing.' });

type R = Record<string, unknown>;
type V = R & { id: string; name: string; plate: string | null; vin: string; status: string; management_mode: string; class: string | null; colour: string | null; odometer_km: number | null;
  fleet_number: string | null; allows_18_to_20: boolean; bookings_enabled: boolean; is_sample: boolean; home_location: string | null; enrollment_date: string | null; exit_date: string | null;
  owner: { id: string; legal_name: string } | null; listing: R | null; rate_card: R | null; rate_history: R[]; fee_overrides: R[]; classes: string[];
  fee_types: Array<{ code: string; label: string; unit: string; default: { amount_cents: number | null; percent_bps: number | null; source: string } | null }>;
  coverage_prices: R[]; schedule: R | null; terms: R | null; documents: R[]; tracker: { device: R; status: R | null } | null; bookings: R[]; transitions: string[]; intake: R | null;
  supply_type: string; supply_label: string; partner: { id: string; business_name: string; partner_number: string; commission_bps: number | null } | null; commission_bps: number | null;
  commission_effective_bps: number | null; retired_at: string | null; retired_reason: string | null; delete_blockers: string[]; bookings_ahead: number };

// One vehicle (03-admin.md section 8.2).
export default async function Vehicle({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ id }, sp] = await Promise.all([params, searchParams]);
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read, list, user } = await page(`/admin/vehicles/${id}`);
  const v = await read<V | null>('vehicle', { id });
  if (!v) notFound();
  const tab = sp.tab ?? 'overview';
  const base = `/admin/vehicles/${id}`;
  const rc = v.rate_card ?? {};
  const P = { vehicle: id };
  const refresh = [base, '/admin/vehicles'];
  // interest in the car on the site (0060)
  const interest = tab === 'overview' ? await read<Interest>('vehicle_interest', { vehicle_id: id }).catch(() => null) : null;
  const classes = tab === 'overview' ? (await list<{ code: string; label: string }>('vehicle_classes', { eq: { is_active: true }, order: 'sort_order', asc: true })).rows : [];
  const cal = tab === 'calendar' ? await (async () => { const { from } = rangeFrom(sp.start, 'month'); return read<CalData>('calendar', { from: from.toISOString(), to: new Date(from.getTime() + 31 * 86_400_000).toISOString(), vehicle: id }); })() : null;
  const slug = v.listing?.slug ? String(v.listing.slug) : null;
  const [partners, owners] = tab === 'overview' ? await Promise.all([door<Array<{ id: string; business_name: string }>>(user.id, 'ops_read', 'partners').catch(() => []), adminOwners(user)]) : [[], []];
  // a car with no real photo shows sample photos on its listing (0054)
  const usingSamples = ((await door<Array<{ vehicle_id: string }>>(user.id, 'ops_read', 'vehicles_using_samples').catch(() => [])) ?? []).some((x) => x.vehicle_id === id);
  const supplier = v.supply_type === 'company' ? 'Company fleet'
    : v.supply_type === 'partner' && v.partner ? <Link prefetch={false} className="link" href={`/admin/partners/${v.partner.id}`}>{v.partner.business_name}</Link>
    : v.owner ? <Link prefetch={false} className="link" href={`/admin/owners/${v.owner.id}`}>{v.owner.legal_name}</Link> : 'no owner';
  return (
    <>
      <PageHead kicker={<><Link prefetch={false} className="link" href="/admin/vehicles">Vehicles</Link> · {v.fleet_number ?? ''} {v.plate} · {supplier}</>}
        title={<>{v.name} {v.retired_at ? <Badge s="retired">Retired</Badge> : <Badge s={v.status} />}{usingSamples && <> <Badge s="needs_review">Using sample photos</Badge></>}</>}>
        {slug && v.listing?.status === 'published' && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`/cars/${slug}`} target="_blank">Public page</Link>}
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
          <Card title="Who supplies the car" testId="vehicle-supply">
            {sp.added && <p className="alert alert--ok" role="status"><span>Car added. Set its rates and start its listing when it is ready.</span></p>}
            <Kv rows={[['Supplied by', <span key="s" data-testid="vehicle-supply-label">{v.supply_label}</span>], ...(v.supply_type === 'partner' ? [['Partner', supplier] as [string, React.ReactNode],
              ['Commission', `${(v.commission_effective_bps ?? 0) / 100}%${v.commission_bps == null ? ' (the partner\'s)' : ' (this car\'s own)'}`] as [string, React.ReactNode]] : []),
              ['Revenue to CarmaCars', v.supply_type === 'company' ? '100%: no owner, no owner statement, fees or payouts' : v.supply_type === 'partner' ? 'The commission; the partner gets the rest' : 'The Revenue Share in the owner\'s schedule']]} />
            <div className="ad-actions">
              {v.supply_type === 'partner' && <Act ops action="vehicle_set_commission" payload={{ vehicle_id: id }} label="Commission for this car" testId="vehicle-commission" refresh={refresh}
                fields={[{ name: 'commission_bps', label: 'Commission (empty: the partner\'s)', type: 'percent', value: v.commission_bps }]} />}
              <Act ops action="vehicle_set_supply" payload={{ vehicle_id: id }} label="Change who supplies it" refresh={refresh} testId="vehicle-set-supply"
                confirm="Only for a car with no booking under way and no owner schedule or invoices. Bookings already made keep their split."
                fields={[{ name: 'supply_type', label: 'Supplied by', type: 'select', required: true, value: v.supply_type, options: [['program_owner', 'A program owner'], ['company', 'CarmaCars (company fleet)'], ['partner', 'A partner rental company']] },
                  { name: 'partner_id', label: 'Partner (for a partner car)', type: 'select', options: partners.map((x) => [x.id, x.business_name] as [string, string]) },
                  { name: 'commission_bps', label: 'Commission (partner car; empty: the partner\'s)', type: 'percent' },
                  { name: 'owner_id', label: 'Owner (for a program owner\'s car)', type: 'select', options: owners.map((o) => [o.owner_id, o.legal_name] as [string, string]) }]} />
            </div>
          </Card>
          <Card title="Retire or delete" testId="vehicle-retire-card">
            {v.retired_at ? <>
              <p className="small" data-testid="vehicle-retired">Retired on {d(v.retired_at)}: {v.retired_reason}. It takes no bookings and is off the calendars; its bookings, statements and payments stay.</p>
              <div className="ad-actions"><Act ops action="vehicle_restore" payload={{ vehicle_id: id }} label="Restore" confirm="The car takes bookings again. Publish its listing again when it is ready." refresh={refresh} testId="vehicle-restore" /></div>
            </> : <>
              <p className="small muted">Retire a car that leaves the fleet: its listing is unpublished and it leaves the calendars from now on, and everything it earned stays. {v.bookings_ahead > 0 ? `First cancel or move its ${v.bookings_ahead} confirmed booking(s) ahead.` : ''}</p>
              <div className="ad-actions"><Act ops action="vehicle_retire" payload={{ vehicle_id: id }} label="Retire this car" variant="danger" refresh={refresh} testId="vehicle-retire"
                fields={[{ name: 'reason', label: 'Reason (sold, returned to the owner, written off)', type: 'text', required: true }]} /></div>
            </>}
            <DeleteCar vehicleId={id} name={v.name} plate={v.plate} blockers={v.delete_blockers} />
          </Card>
          <Card title="Bookings"><Table rows={v.bookings} empty="No bookings in the last 120 days." cols={[{ key: 'booking_number', label: 'Booking', render: (r) => <BookingLink n={r.booking_number} /> }, { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'pickup_at', label: 'Pickup', render: (r) => t(r.pickup_at) }, { key: 'return_at', label: 'Return', render: (r) => t(r.return_at) }, { key: 'renter', label: 'Renter' }, { key: 'total_cents', label: 'Total', num: true, render: (r) => $(r.total_cents) }]} /></Card>
          <Card title="Interest on the site" testId="vehicle-interest"><CarInterest i={interest} /></Card>
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
            <p className="small"><Link prefetch={false} className="link" href="/admin/settings/coverage">Edit the coverage price table</Link></p></Card>
        </div>
      )}
      {tab === 'calendar' && <div className="small" data-testid="vehicle-turnaround">Turnaround between trips on this car: <b>{v.turnaround_block_minutes == null ? 'as in Program settings' : `${String(v.turnaround_block_minutes)} minutes`}</b>{' '}
        <Act action="vehicle_turnaround" payload={{ vehicle: id }} label="Change" title="Turnaround between trips on this car" fields={[{ name: 'minutes', label: 'Minutes (empty: Program settings)', type: 'number', value: v.turnaround_block_minutes ?? '', hint: 'The time held between two trips on this car: the cleaning block after each trip, and the gap before the next pickup. It is not added twice.' }]} done="Saved." testId="turnaround-change" /></div>}
      {tab === 'calendar' && cal && <Suspense><MasterCalendar initial={cal} vehicleId={id} defaultView="month" /></Suspense>}
      {tab === 'listing' && (
        <div className="ad-cols ad-cols--2">
          <Card title="Listing">
            {usingSamples && <p className="alert alert--warn" role="note" data-testid="vehicle-using-samples"><span className="alert__title">Using sample photos</span><span>This car has no real photos yet, so its listing shows sample photos, marked &quot;Sample photo&quot; on the site. It can be published as it is. Real photos replace the samples as soon as they are approved. <Link prefetch={false} className="link" href="/admin/settings/sample-photos">Sample photos</Link></span></p>}
            {v.listing ? <Kv rows={[['Status', <Badge key="s" s={String(v.listing.status)} />], ['Address', slug ? <Link prefetch={false} key="l" className="link" href={`/cars/${slug}`}>/cars/{slug}</Link> : ''], ['Headline', String(v.listing.headline ?? '')], ['Published', t(v.listing.published_at)], ['Unpublished', `${t(v.listing.unpublished_at)} ${String(v.listing.unpublished_reason ?? '')}`], ['Sample car', v.is_sample ? 'Yes: a placeholder, hidden from search engines' : 'No']]} /> : <p className="small muted">No listing yet.</p>}
            <div className="ad-actions">
              {v.intake && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`/admin/listings/${String(v.intake.id)}`}>Open the listing review</Link>}
              {!v.intake && <Act action="listing_start" payload={{ vehicle_id: id }} label="Start a listing" go="/admin/listings/{intake_id}" />}
              {v.listing && v.listing.status !== 'published' && <Act action="listing_publish" payload={P} label="Publish" variant="primary" refresh={refresh} />}
              {v.is_sample && <Act action="vehicle_sample" payload={{ ...P, is_sample: false }} label="Not a sample" confirm="This car is real: its page goes into search results and the sitemap." refresh={refresh} testId="vehicle-sample-clear" />}
              {v.listing?.status === 'published' && <Act action="listing_unlist" payload={P} label="Unlist" variant="danger" refresh={refresh} fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }, { name: 'to_path', label: 'Redirect to (empty: the model page or 410)', type: 'text' }]} />}
            </div>
          </Card>
        </div>
      )}
      {tab === 'records' && (
        <div className="ad-cols ad-cols--2">
          <Card title={v.supply_type === 'program_owner' ? 'Owner terms' : 'Terms'}><Kv rows={[[v.supply_type === 'program_owner' ? 'Owner' : 'Supplied by', v.supply_type === 'program_owner' ? v.owner?.legal_name ?? '' : v.supply_type === 'partner' ? v.partner?.business_name ?? '' : 'CarmaCars'], ['Schedule', v.schedule ? String(v.schedule.schedule_number ?? '') : 'none'], ['Insurance Fee', $(v.terms?.insurance_fee_cents)], ['Tracker Fee', $(v.terms?.tracker_fee_cents)], ['Revenue Share', v.terms?.revenue_share_bps !== undefined ? `${Number(v.terms?.revenue_share_bps) / 100}%` : '']]} />
            {v.terms && <Act action="fee_change_notice" payload={P} label="Fee change notice" fields={[{ name: 'insurance_fee_cents', label: 'New Insurance Fee', type: 'money', required: true, value: v.terms.insurance_fee_cents }, { name: 'tracker_fee_cents', label: 'New Tracker Fee', type: 'money', required: true, value: v.terms.tracker_fee_cents }, { name: 'effective_from', label: 'Effective (30 days or more ahead)', type: 'date', required: true }, { name: 'reason', label: 'Reason', type: 'text' }]} refresh={refresh} />}</Card>
          <Card title="Tracker">{v.tracker ? <Kv rows={[['Device', String(v.tracker.device.serial_number ?? '')], ['Last seen', t(v.tracker.device.last_seen_at)], ['Speed', v.tracker.status ? `${String(v.tracker.status.speed_kmh)} km/h` : ''], ['Ignition', v.tracker.status ? (v.tracker.status.ignition_on ? 'on' : 'off') : ''], ['Locked', v.tracker.status ? String(v.tracker.status.locked) : '']]} /> : <p className="small muted">No tracker installed.</p>}
            <p className="small" data-testid="tracker-coming-soon"><b>Coming soon:</b> {TRACKER_SOON}</p></Card>
          <Card title="Documents"><Table rows={v.documents} empty="No documents." cols={[{ key: 'title', label: 'Title' }, { key: 'kind', label: 'Kind' }, { key: 'created_at', label: 'Added', render: (r) => t(r.created_at) }]} /></Card>
        </div>
      )}
    </>
  );
}
