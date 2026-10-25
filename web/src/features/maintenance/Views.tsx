import Link from 'next/link';
import type { ReactNode } from 'react';
import { Act } from '@/features/admin/Act';
import { $, Card, Kv, Table, d, t } from '@/features/admin/ui';
import { RecordService } from './RecordService';
import {
  BILLING_LABEL, KMD_SOURCE, READING_SOURCE, SEASON_LABEL, SEASONS, SHOWS, STATUS_LABEL, STATUS_TONE, chipText, dueWords, filterCars, kmText,
  type CarMaintenance, type Item, type Overview, type Payer, type ServiceRecord, type Status, type TireSet
} from './model';
import './maintenance.css';

// The maintenance tracker's screens (migration 0089): the fleet overview (Admin and Fleet), the car's Maintenance tab
// (Admin's car page and Fleet's car view) and the parts they share. Every change goes through the door's ops calls.
export function StatusBadge({ s, children }: { s: Status; children?: ReactNode }) {
  return <span className={`ad-b ${STATUS_TONE[s]}`} data-status={s}>{children ?? STATUS_LABEL[s]}</span>;
}

const PAYER_WORD: Record<Payer, string> = { company: 'CarmaCars', owner: 'Owner', claim: 'Claim', renter: 'Renter', none: 'No charge' };

function nextDue(i: Item): string {
  if (i.status === 'off') return '';
  const parts = [i.next_due_km ? kmText(i.next_due_km) : '', i.next_due_on ? d(i.next_due_on) : ''].filter(Boolean);
  return parts.join(' or ');
}

/** The fleet overview: every car with its status chips, most urgent first, with filters and the record pop-up. */
export function FleetMaintenance({ data, base, sp }: { data: Overview; base: '/admin' | '/va'; sp: Record<string, string | undefined> }) {
  const show = sp.show ?? '';
  const rows = filterCars(data.cars, { show, item: sp.item, q: sp.q, sort: sp.sort });
  const counts = {
    overdue: data.cars.filter((c) => c.overdue > 0).length, soon: data.cars.filter((c) => c.due_soon > 0 && c.overdue === 0).length,
    unknown: data.cars.filter((c) => c.unknown > 0).length, ok: data.cars.filter((c) => c.worst === 'ok').length
  };
  const href = (q: Record<string, string>) => { const u = new URLSearchParams(Object.entries({ ...sp, ...q }).filter(([, v]) => v) as Array<[string, string]>); const s = u.toString(); return s ? `${base}/maintenance?${s}` : `${base}/maintenance`; };
  const carHref = (id: string) => base === '/admin' ? `/admin/vehicles/${id}?tab=maintenance` : `/va/vehicles/${id}#maintenance`;
  const auto = sp.record && /^[0-9a-f-]{36}$/.test(sp.record) ? sp.record : null;
  return (
    <div className="stack" data-testid="maint-overview">
      <ul className="mt-tally" aria-label="Cars by service status">
        <li><Link prefetch={false} href={href({ show: 'overdue' })} className="mt-tally__a" data-testid="tally-overdue"><b className="num">{counts.overdue}</b> overdue</Link></li>
        <li><Link prefetch={false} href={href({ show: 'due_soon' })} className="mt-tally__a"><b className="num">{counts.soon}</b> due soon</Link></li>
        <li><Link prefetch={false} href={href({ show: 'unknown' })} className="mt-tally__a"><b className="num">{counts.unknown}</b> with no record yet</Link></li>
        <li><Link prefetch={false} href={href({ show: 'ok' })} className="mt-tally__a"><b className="num">{counts.ok}</b> all OK</Link></li>
        {data.to_bill > 0 && <li><Link prefetch={false} href={href({ show: 'bill' })} className="mt-tally__a"><b className="num">{data.to_bill}</b> to bill</Link></li>}
      </ul>
      <form className="mt-filters" action={`${base}/maintenance`} role="search" data-testid="maint-filters">
        <div className="field"><label className="label" htmlFor="mt-show">Show</label>
          <select className="select" id="mt-show" name="show" defaultValue={show}>{SHOWS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
        <div className="field"><label className="label" htmlFor="mt-item">Service item</label>
          <select className="select" id="mt-item" name="item" defaultValue={sp.item ?? ''}><option value="">Any</option>{data.items.map((i) => <option key={i.code} value={i.code}>{i.label}</option>)}</select></div>
        <div className="field"><label className="label" htmlFor="mt-sort">Sort</label>
          <select className="select" id="mt-sort" name="sort" defaultValue={sp.sort ?? ''}><option value="">Most urgent first</option><option value="due">Next due date</option><option value="km">Odometer, highest first</option><option value="name">Name</option></select></div>
        <div className="field"><label className="label" htmlFor="mt-q">Car, plate or owner</label><input className="input" id="mt-q" name="q" type="search" defaultValue={sp.q ?? ''} /></div>
        <button className="btn btn--ghost btn--sm" type="submit">Apply</button>
      </form>
      {show === 'bill' ? <p className="small" data-testid="maint-bill-help">Services recorded and not billed yet are on each car&apos;s Maintenance tab, under Service history, with <b>Bill now</b>. The cars with one are listed here.</p> : null}
      {rows.length === 0 ? <p className="ad-empty" data-testid="maint-empty">{data.cars.length ? 'No car matches these filters.' : 'No cars to track yet. Real cars appear here as soon as they are added (sample cars are left out).'}</p> : (
        <ul className="mt-cars" data-testid="maint-cars">{rows.map((c) => (
          <li key={c.vehicle_id} className={`mt-car is-${c.worst}`} data-testid={`maint-car-${c.vehicle_id}`} data-worst={c.worst}>
            <div className="mt-car__head">
              <div>
                <Link prefetch={false} className="link mt-car__name" href={carHref(c.vehicle_id)}>{c.name}</Link>
                <span className="small muted"> {[c.plate, c.fleet_number, c.owner_name].filter(Boolean).join(' · ')}</span>
              </div>
              <StatusBadge s={c.worst}>{c.worst === 'overdue' ? `${c.overdue} overdue` : c.worst === 'due_soon' ? `${c.due_soon} due soon` : c.worst === 'unknown' ? 'Record the last service' : 'All OK'}</StatusBadge>
            </div>
            <p className="small mt-car__next">{c.next && c.next.status !== 'ok' ? <><b>{c.next.label}</b>: {c.next.detail}{c.next.due_on ? ` (${dueWords(c.next.due_on, data.today)})` : ''}</>
              : c.next ? <>Next: <b>{c.next.label}</b>{c.next.due_on ? `, ${dueWords(c.next.due_on, data.today)}` : ''}</> : c.unknown ? `${c.unknown} items with no record yet` : 'Nothing due'}</p>
            <p className="small muted">{[c.current_km ? kmText(c.current_km) : 'Odometer unknown', c.km_per_day ? `${Math.round(c.km_per_day)} km a day` : '', c.tires ? `${SEASON_LABEL[c.tires.season]} tires${c.tires.tread_mm ? ` ${c.tires.tread_mm} mm` : ''}` : 'Tires not on file',
              c.last_service_on ? `last service ${d(c.last_service_on)}` : ''].filter(Boolean).join(' · ')}</p>
            {(c.chips ?? []).some((x) => x.status === 'overdue' || x.status === 'due_soon') || c.unknown > 0 ? <ul className="mt-chips" aria-label={`Service items of ${c.name}`}>{(c.chips ?? []).filter((x) => x.status === 'overdue' || x.status === 'due_soon').map((x) => (
              <li key={x.code}><StatusBadge s={x.status}>{chipText(x)}</StatusBadge></li>))}
              {c.unknown > 0 && <li><StatusBadge s="unknown">{c.unknown} with no record yet</StatusBadge></li>}</ul> : null}
            <div className="ad-actions"><RecordService vehicleId={c.vehicle_id} variant={c.worst === 'overdue' || c.worst === 'due_soon' || c.worst === 'unknown' ? 'primary' : 'ghost'}
              label={c.worst === 'unknown' ? 'Record the last service' : 'Record a service'} testId={`record-${c.vehicle_id}`} autoOpen={auto === c.vehicle_id}
              only={c.worst === 'unknown' ? (c.chips ?? []).filter((x) => x.status === 'unknown' && !['tires', 'seasonal_swap'].includes(x.code)).map((x) => x.code) : undefined} />
              <Link prefetch={false} className="btn btn--ghost btn--sm" href={carHref(c.vehicle_id)}>Open</Link></div>
          </li>))}
        </ul>
      )}
    </div>
  );
}

/** One car's maintenance: status per item, the tires, the history with its bills, the odometer, and the car's own settings. */
export function CarMaintenancePanel({ m, base, autoRecord = false }: { m: CarMaintenance; base: '/admin' | '/va'; autoRecord?: boolean }) {
  const refresh = [`${base}/vehicles/${m.vehicle_id}`, `${base}/maintenance`];
  const P = { vehicle_id: m.vehicle_id };
  const items = m.items.filter((i) => i.active);
  const off = m.items.filter((i) => !i.active);
  const sets = m.tire_sets.filter((s) => !s.retired_on);
  const retired = m.tire_sets.filter((s) => s.retired_on);
  const doc = (id: string) => `${base}/documents/${id}`;
  if (!m.tracked) return <Card title="Maintenance" testId="car-maintenance"><p className="small muted">This car is a sample, retired or has left the fleet: its maintenance is not tracked.</p></Card>;
  return (
    <div className="stack" id="maintenance" data-testid="car-maintenance">
      {m.handover_block && <p className="alert alert--error" role="alert" data-testid="maint-handover-block"><span className="alert__title">Handover is refused</span><span>{m.handover_block}. Renew it and record it here.</span></p>}
      <Card title="Service status" testId="maint-items" aside={<RecordService vehicleId={m.vehicle_id} car={m} autoOpen={autoRecord} testId="record-service" />}>
        <div className="small mt-odo" data-testid="maint-odometer">Odometer <b>{kmText(m.current_km) || 'unknown'}</b>{m.km_per_day ? <> · about <b>{Math.round(m.km_per_day.rate)} km a day</b>, {KMD_SOURCE[m.km_per_day.source]}</> : null}
          {' '}<Act ops action="maint_reading_add" payload={P} label="Add a reading" title="Odometer reading" refresh={refresh} testId="maint-reading-add" fields={[
            { name: 'km', label: 'Odometer (km)', type: 'number', required: true, min: 1 }, { name: 'confirmed', label: 'Lower than the last reading: I checked it', type: 'bool' }]} done="Saved." /></div>
        <Table<Item & Record<string, unknown>> testId="maint-item-table" rows={items as Array<Item & Record<string, unknown>>} rowKey={(r) => r.code} caption="Service items" cols={[
          { key: 'label', label: 'Item', render: (r) => <span>{r.label}{r.rule_source !== 'default' ? <span className="small muted"> ({r.rule_source === 'car' ? 'this car' : 'class'} interval)</span> : null}</span> },
          { key: 'status', label: 'Status', render: (r) => <span data-testid={`status-${r.code}`} data-status={r.status}><StatusBadge s={r.status} /></span> },
          { key: 'last', label: 'Last done', render: (r) => r.last_done_on ? `${d(r.last_done_on)}${r.last_done_km ? `, ${kmText(r.last_done_km)}` : ''}` : <span className="muted">none</span> },
          { key: 'next', label: 'Next due', render: (r) => <span data-testid={`next-${r.code}`}>{nextDue(r) || <span className="muted">none</span>}</span> },
          { key: 'detail', label: 'Detail', className: 'wrap', render: (r) => <span className="small">{r.detail}{r.projected_due_on && r.next_due_km ? ` · at the current pace about ${d(r.projected_due_on)}` : ''}</span> },
          { key: 'act', label: '', render: (r) => <RecordService vehicleId={m.vehicle_id} car={m} only={[r.code]} label="Record" variant="ghost" testId={`record-${r.code}`} /> }]} />
        {off.length > 0 && <p className="small muted">Not tracked for this car: {off.map((i) => i.label).join(', ')}.</p>}
      </Card>
      <Card title="Tires" testId="maint-tires" aside={<Act ops action="maint_tire_save" payload={P} label="Add a tire set" refresh={refresh} testId="tire-add" fields={tireFields(null)} done="Saved." />}>
        {sets.length === 0 ? <p className="ad-empty">No tire set on file. Add the set on the car (and any set in storage) to track the tread, the age and the seasonal swap.</p> : (
          <Table<TireSet & Record<string, unknown>> testId="tire-sets" rows={sets as Array<TireSet & Record<string, unknown>>} caption="Tire sets" cols={[
            { key: 'season', label: 'Kind', render: (r) => <span><b>{SEASON_LABEL[r.season]}</b>{r.on_car ? <> <span className="ad-b ad-b--dark">On the car</span></> : null}</span> },
            { key: 'size', label: 'Size and brand', render: (r) => [r.size, r.brand, r.model].filter(Boolean).join(', ') || <span className="muted">none</span> },
            { key: 'tread_mm', label: 'Tread', num: true, render: (r) => r.tread_mm !== null ? `${r.tread_mm} mm` : '' },
            { key: 'made_on', label: 'Made or bought', render: (r) => d(r.made_on ?? r.purchased_on) },
            { key: 'storage_location', label: 'Stored at', render: (r) => r.on_car ? '' : r.storage_location ?? <span className="muted">not said</span> },
            { key: 'act', label: '', render: (r) => <span className="ad-actions">
              <Act ops action="maint_tire_save" payload={{ id: r.id }} label="Edit" title="Edit the tire set" refresh={refresh} fields={tireFields(r)} done="Saved." testId={`tire-edit-${r.season}`} />
              {!r.on_car && <Act ops action="maint_tire_swap" payload={{ to_set_id: r.id }} label="Put on the car" title={`Swap to the ${SEASON_LABEL[r.season].toLowerCase()} set`} refresh={refresh} testId={`tire-swap-${r.season}`}
                fields={[{ name: 'swapped_on', label: 'Swapped on', type: 'date', value: m.today, required: true }, { name: 'odometer_km', label: 'Odometer (km)', type: 'number', value: m.current_km }, { name: 'storage_location', label: 'Where the removed set goes', type: 'address' }]} done="Swapped." />}
              <Act ops action="maint_tire_retire" payload={{ id: r.id }} label="Retire" title="Retire the tire set" refresh={refresh} fields={[{ name: 'reason', label: 'Why (worn out, sold, damaged)', required: true }]} />
            </span> }]} />
        )}
        {m.swaps.length > 0 && <><p className="pt-kicker">Swaps</p><ul className="small" data-testid="tire-swaps">{m.swaps.map((w, i) => <li key={i}>{d(w.swapped_on)}: {w.from ?? 'none'} to {w.to}{w.odometer_km ? ` at ${kmText(w.odometer_km)}` : ''}</li>)}</ul></>}
        {retired.length > 0 && <p className="small muted">Retired: {retired.map((s) => `${SEASON_LABEL[s.season]}${s.brand ? ` ${s.brand}` : ''} (${s.retired_reason ?? ''}, ${d(s.retired_on)})`).join('; ')}</p>}
      </Card>
      <Card title="Service history" testId="maint-history">
        <Table<ServiceRecord & Record<string, unknown>> testId="maint-records" rows={m.records as Array<ServiceRecord & Record<string, unknown>>} empty="No service recorded yet. Record the last oil change, brakes and tires once: the reminders work from them." caption="Service history" cols={[
          { key: 'done_on', label: 'Date', render: (r) => <span className={r.voided_at ? 'mt-void' : undefined}>{d(r.done_on)}</span> },
          { key: 'items', label: 'Work', className: 'wrap', render: (r) => <span className={r.voided_at ? 'mt-void' : undefined}>{r.items.map((i) => i.label + (i.expires_on ? ` (until ${d(i.expires_on)})` : '') + (i.tread_mm !== null ? ` (${i.tread_mm} mm)` : '')).join(', ') || 'Other work'}{r.notes ? <span className="small muted"> · {r.notes}</span> : null}</span> },
          { key: 'odometer_km', label: 'Odometer', num: true, render: (r) => r.odometer_km ? `${kmText(r.odometer_km)}${r.odometer_estimated ? ' (est.)' : ''}` : '' },
          { key: 'shop', label: 'Shop' },
          { key: 'cost', label: 'Cost', num: true, render: (r) => r.cost_cents + r.hst_cents ? $(r.cost_cents + r.hst_cents) : '' },
          { key: 'payer', label: 'Paid by', render: (r) => PAYER_WORD[r.payer] },
          { key: 'billing', label: 'Bill', className: 'wrap', render: (r) => r.voided_at ? <span className="small">Void: {r.void_reason}</span> : <span className="small">
            <span className={`ad-b ${r.billing_status === 'billed' ? 'ad-b--light' : r.billing_status === 'no_charge' ? 'ad-b--light' : 'ad-b--amber'}`}>{BILLING_LABEL[r.billing_status]}</span>
            {r.company_expense_id ? ' · company expense' : ''}{r.owner_deduction ? ` · owner cost, ${r.owner_deduction.status}` : ''}{r.claim_number ? ` · claim ${r.claim_number}` : ''}{r.booking_number ? ` · ${r.booking_number}` : ''}
            {r.source === 'expense' ? ' · from Expenses' : ''}{r.receipt_document_id ? <> · <a className="link" href={doc(r.receipt_document_id)} target="_blank" rel="noopener">receipt</a></> : null}</span> },
          { key: 'act', label: '', render: (r) => r.voided_at ? null : <span className="ad-actions">
            {(r.billing_status === 'not_billed' || (r.billing_status === 'needs_admin' && m.is_admin)) && <Act ops action="maint_bill" payload={{ id: r.id }} label="Bill now" title="Bill this service" refresh={refresh} testId={`bill-${r.id}`} done="Billed."
              fields={[{ name: 'cost_cents', label: 'Cost before HST', type: 'money', value: r.cost_cents, required: true }, { name: 'hst_cents', label: 'HST', type: 'money', value: r.hst_cents },
                { name: 'payer', label: 'Who pays', type: 'select', required: true, value: r.payer, options: m.payers },
                ...(m.claims.length ? [{ name: 'claim_id', label: 'Claim (if a claim pays)', type: 'select' as const, options: m.claims.map((c) => [c.id, c.claim_number] as [string, string]) }] : []),
                ...(m.bookings.length ? [{ name: 'booking_id', label: 'Rental (if the renter pays)', type: 'select' as const, options: m.bookings.map((b) => [b.id, b.booking_number] as [string, string]) }] : [])]} />}
            <Act ops action="maint_void" payload={{ id: r.id }} label="Void" title="Void this service record" variant="quiet" refresh={refresh} testId={`void-${r.id}`}
              confirm="The timers go back to the service before. A company expense is voided and an open owner cost is waived; a bill already on a statement or a claim stays (the void is refused)."
              fields={[{ name: 'reason', label: 'Reason', required: true }]} />
          </span> }]} />
      </Card>
      <div className="ad-cols ad-cols--2">
        <Card title="Odometer readings" testId="maint-readings">
          <Table rows={m.readings as unknown as Array<Record<string, unknown>>} empty="No readings yet. They come from handovers, returns, field staff moves, listing photos, services and readings added by hand." caption="Odometer readings" cols={[
            { key: 'read_at', label: 'When', render: (r) => <span className={r.voided_at ? 'mt-void' : undefined}>{t(r.read_at)}</span> }, { key: 'km', label: 'Km', num: true, render: (r) => kmText(Number(r.km)) },
            { key: 'source', label: 'From', render: (r) => READING_SOURCE[String(r.source)] ?? String(r.source) },
            { key: 'act', label: '', render: (r) => m.can_settings && !r.voided_at ? <Act ops action="maint_reading_void" payload={{ id: r.id }} label="Void" variant="quiet" refresh={refresh} fields={[{ name: 'reason', label: 'Why (a typo, the wrong car)', required: true }]} /> : r.voided_at ? <span className="small muted">void</span> : null }]} />
        </Card>
        <Card title="Intervals for this car" testId="maint-car-rules">
          <p className="small muted">Each item follows this car&apos;s own interval, else its class&apos;s ({m.class ?? 'none'}), else the default in Settings, Maintenance. Whichever of km and months comes first is due.</p>
          <Kv rows={items.filter((i) => i.interval_km || i.interval_months).slice(0, 20).map((i) => [i.label, [i.interval_km ? kmText(i.interval_km) : '', i.interval_months ? `${i.interval_months} months` : ''].filter(Boolean).join(' or ')] as [string, string])} />
          {m.can_settings && <div className="ad-actions">
            <Act ops action="maint_rule_save" payload={P} label="Set an interval for this car" refresh={refresh} testId="car-rule" done="Saved." fields={[
              { name: 'item_code', label: 'Item', type: 'select', required: true, options: m.items.map((i) => [i.code, i.label] as [string, string]) },
              { name: 'interval_km', label: 'Every (km; 0: not by km)', type: 'number', min: 0 }, { name: 'interval_months', label: 'Every (months; 0: not by date)', type: 'number', min: 0 },
              { name: 'due_soon_km', label: 'Due soon (km before)', type: 'number', min: 0 }, { name: 'due_soon_days', label: 'Due soon (days before)', type: 'number', min: 0 },
              { name: 'active', label: 'Tracked for this car', type: 'select', options: [['true', 'Yes'], ['false', 'No, turn it off for this car']] },
              { name: 'block_bookings_when_overdue', label: 'Block new bookings when overdue', type: 'select', options: [['true', 'Yes'], ['false', 'No']] }]} />
          </div>}
          {m.rules.length > 0 && <ul className="small" data-testid="car-rules">{m.rules.map((r) => (
            <li key={String(r.id)}>{m.items.find((i) => i.code === r.item_code)?.label}: {[r.interval_km !== null ? `${String(r.interval_km)} km` : '', r.interval_months !== null ? `${String(r.interval_months)} months` : '', r.active === false ? 'off' : ''].filter(Boolean).join(', ') || 'thresholds only'}
              {m.can_settings && <> <Act ops action="maint_rule_delete" payload={{ id: r.id }} label="Remove" variant="quiet" refresh={refresh} /></>}</li>))}</ul>}
        </Card>
      </div>
    </div>
  );
}

function tireFields(s: TireSet | null) {
  return [
    { name: 'season', label: 'Kind', type: 'select' as const, required: true, value: s?.season ?? 'all_season', options: SEASONS },
    { name: 'size', label: 'Size', value: s?.size, placeholder: '225/45R17' }, { name: 'brand', label: 'Brand', value: s?.brand }, { name: 'model', label: 'Model', value: s?.model },
    { name: 'tread_mm', label: 'Tread depth (mm)', type: 'number' as const, value: s?.tread_mm, min: 0, max: 20 },
    { name: 'made_on', label: 'Made (DOT date)', type: 'date' as const, value: s?.made_on }, { name: 'purchased_on', label: 'Bought on', type: 'date' as const, value: s?.purchased_on },
    { name: 'storage_location', label: 'Stored at (when off the car)', type: 'address' as const, value: s?.storage_location }, { name: 'on_car', label: 'On the car now', type: 'bool' as const, value: s ? s.on_car : true },
    { name: 'notes', label: 'Notes', type: 'textarea' as const, value: s?.notes }
  ];
}
