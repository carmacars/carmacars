import Link from '@/components/Link';
import { Act, type Field } from '@/features/admin/Act';
import { Card, Kv, Table, t } from '@/features/admin/ui';
import { money } from '@/lib/format';
import './tracking.css';
import { FindPins } from './FindPins';
import { PATHS, chargeState, eventLabel, eventTone, feeLine, lotIssues, mapUrl, pathLabel, sealShort, sourceLabel, toldLine,
  type PoundFlag, type PoundLot, type TrackerEvent, type TrackerEvents as Data } from './events';

// Tracker events (migration 3320), below the Fleet tracking panel: the evidence record of every event (the map point, the
// speed, the time, the source, the charge and the clause, who was told) with Charge on a speeding record; the pound flags
// with the path Fleet records; the pound lots (an Admin edits them); and, for an Admin, the event settings. The same
// component on Admin > Cars > Fleet tracking and on the staff car map: the database says what this person may do.
const TONE = { red: 'ad-b--red', amber: 'ad-b--amber', grey: 'ad-b--grey' } as const;
const $ = (c: number | null | undefined) => (c == null ? '' : money(c, { cents: true }));

export function TrackerEventsPanel({ d, staff = false }: { d: Data | null; staff?: boolean }) {
  const R = [staff ? '/staff/fleet/map' : '/admin/vehicles/tracking'];
  const base = staff ? '/staff' : '/admin';
  if (!d) return <Card title="Tracker events" id="events" testId="tracker-events"><p className="alert alert--error" role="alert"><span>The tracker events could not be read. Reload the page.</span></p></Card>;
  const open = d.flags.filter((f) => f.status === 'open');
  const bookingLink = (n: string | null) => (n ? <Link prefetch={false} className="link" href={`${base}/bookings/${encodeURIComponent(n)}`}>{n}</Link> : <span className="muted">No rental</span>);
  const lotFields = (l?: PoundLot): Field[] => [
    { name: 'name', label: 'Name', type: 'text', required: true, value: l?.name ?? '' },
    { name: 'address', label: 'Address', type: 'text', required: true, value: l?.address ?? '', hint: 'The pin is found from the address when the latitude and longitude are left empty.' },
    { name: 'city', label: 'City', type: 'text', value: l?.city ?? '' },
    { name: 'phone', label: 'Phone', type: 'tel', value: l?.phone ?? '' },
    { name: 'hours', label: 'Hours', type: 'text', value: l?.hours ?? '', placeholder: 'Open 24 hours' },
    { name: 'serves', label: 'Who tows there', type: 'text', value: l?.serves ?? '', placeholder: 'Toronto Police: west' },
    { name: 'latitude', label: 'Pin: latitude', type: 'number', min: 41, max: 57, value: l?.latitude ?? '' },
    { name: 'longitude', label: 'Pin: longitude', type: 'number', min: -96, max: -74, value: l?.longitude ?? '' },
    { name: 'radius_m', label: 'Radius (m)', type: 'number', min: 30, max: 1000, value: l?.radius_m ?? '', hint: `Empty: ${d.settings.pound_radius_m} m, the setting.` },
    { name: 'notes', label: 'Notes', type: 'textarea', value: l?.notes ?? '' },
    { name: 'is_active', label: 'Flag cars parked here', type: 'bool', value: l?.is_active ?? true },
    { name: 'checked', label: 'I checked these details with the lot', type: 'bool', value: l?.checked ?? false }];
  const noPin = d.lots.filter((l) => l.is_active && l.latitude == null).length;

  return (
    <>
      <Card title={`Tracker events${d.events.length ? ` (${d.events.length})` : ''}`} id="events" testId="tracker-events">
        {!d.on && <p className="alert alert--warn" role="status" data-testid="events-off"><span><b>Tracker events are off.</b> Until they are on, the trackers only make the staff alerts above: no evidence records, no notices to renters or owners, no pound flags.{d.can.manage ? ' Turn them on under Tracker event settings once the trackers are installed.' : ' An Admin turns them on once the trackers are installed.'}</span></p>}
        <Table<TrackerEvent> testId="events" caption="Tracker events and their evidence" sort={false} rows={d.events}
          empty={d.on ? 'No tracker events yet. A speeding record, harsh driving, a car outside Ontario, a tampered or unplugged tracker and a car at a pound each show here with their evidence.' : 'No tracker events: they are off.'}
          cols={[
            { key: 'at', label: 'When', render: (e) => t(e.at) },
            { key: 'event', label: 'Event', className: 'wrap', render: (e) => <span className="te-ev"><span><span className={`ad-b ${TONE[eventTone(e)]}`} data-kind={e.kind}>{eventLabel(e)}</span></span>
              <span className="small muted">{e.vehicle}</span><span className="small">{bookingLink(e.booking_number)}</span></span> },
            { key: 'evidence', label: 'Evidence', className: 'wrap', render: (e) => <span className="te-ev">
              <span>{e.speed_kmh != null && e.kind !== 'pound' ? `${e.speed_kmh} km/h · ` : ''}{mapUrl(e) ? <a className="link" href={mapUrl(e)!} target="_blank" rel="noopener noreferrer">map point</a> : 'no position'}</span>
              <span className="small muted">{sourceLabel(e.source)}{e.device ? ` (${e.device})` : ''} · {e.readings} reading{e.readings === 1 ? '' : 's'}</span>
              <span className="small muted" title={e.sha256 ?? undefined}>Seal {sealShort(e.sha256)}{e.sealed ? '' : ' (still filling)'}</span></span> },
            { key: 'fee', label: 'Charge and clause', className: 'wrap', render: (e) => {
              const st = chargeState(e);
              return <span className="te-ev"><span>{feeLine(e, d.fees)}</span>{e.clause && <span className="small muted">Agreement {e.clause}</span>}
                <span className="small muted">Told: {toldLine(e).toLowerCase()}</span>
                <span className="te-act">
                  {st === 'charged' && <span className="ad-b ad-b--dark" data-testid="event-charged">Charged {$(e.line!.amount_cents)}</span>}
                  {st === 'waiting_evidence' && <span className="ad-b ad-b--amber">Charge waits for evidence</span>}
                  {st === 'pound' && <a className="link" href="#pound">Pound flags</a>}
                  {st === 'no_renter' && <span className="small muted">No rental then: nobody to charge</span>}
                  {st === 'can_charge' && !d.can.charge && <span className="small muted">An Admin or Finance charges it</span>}
                  {st === 'can_charge' && d.can.charge && <Act ops action="tracker_alert_charge" payload={{ alert_id: e.alert_id }} label={`Charge ${$(e.fee_cents)}`} variant="primary" refresh={R} done="Charged, with the evidence attached." testId={`charge-${e.id}`}
                    title={`Charge ${eventLabel(e).toLowerCase()}`}
                    confirm={`Add the speeding charge of ${$(e.fee_cents)} plus HST to booking ${e.booking_number}? The tracker's evidence record (${e.speed_kmh} km/h, ${t(e.at)}) is attached, and it is billed from the deposit first.`}
                    fields={[{ name: 'note', label: 'Note for the record (optional)', type: 'text' }]} />}
                </span></span>;
            } }]} />
        <p className="small muted">One event per car, kind and {d.settings.event_window_minutes} minutes, never a flood. Each record keeps the readings 5 minutes each side and is sealed 10 minutes after the event; the dispute pack carries it.</p>
      </Card>

      <Card title={`Pound flags${open.length ? ` (${open.length} open)` : ''}`} id="pound" testId="pound-flags" tone={open.length ? 'warn' : undefined}>
        <Table<PoundFlag> testId="flags" caption="Cars parked at a pound" sort={false} rows={d.flags}
          empty="No car has been flagged at a pound. A car whose tracker parks inside a lot's radius shows here, with a To do for Fleet."
          cols={[
            { key: 'since', label: 'Since', render: (f) => t(f.since) },
            { key: 'vehicle', label: 'Car', className: 'wrap', render: (f) => <span className="te-ev"><span>{f.vehicle}</span><span className="small">{bookingLink(f.booking_number)}</span></span> },
            { key: 'lot', label: 'Lot', className: 'wrap', render: (f) => <span className="te-ev"><span>{f.lot_name}</span><span className="small muted">{f.lot_address}</span>
              {(f.lot_phone || f.lot_hours) && <span className="small">{f.lot_phone && <a className="link" href={`tel:${f.lot_phone.replace(/[^0-9+]/g, '')}`}>{f.lot_phone}</a>}{f.lot_phone && f.lot_hours ? ' · ' : ''}{f.lot_hours}</span>}</span> },
            { key: 'status', label: 'Path', className: 'wrap', render: (f) => (f.status !== 'open'
              ? <span className="te-ev" data-status={f.status}><span>{pathLabel(f.path) || f.status}</span><span className="small muted">{f.note}{f.resolved_by ? ` (${f.resolved_by})` : ''}</span></span>
              : <span className="te-ev"><span><span className="ad-b ad-b--red" data-status="open">Open</span></span>
                <span className="te-act">{!d.can.resolve ? <span className="small muted">Fleet, Finance or an Admin records the path</span>
                  : <Act ops action="pound_flag_resolve" payload={{ id: f.id }} label="Record the path" variant="primary" refresh={R} done="Recorded." testId={`resolve-${f.id}`} title={`${f.vehicle} at ${f.lot_name}`}
                      fields={[
                        { name: 'path', label: 'What happened', type: 'select', required: true, options: f.booking_number ? PATHS : PATHS.filter(([k]) => k === 'no_charge' || k === 'not_a_pound'),
                          hint: f.booking_number ? `The non-return charge is ${$(d.fees.non_return)} and the theft recovery charge ${$(d.fees.theft_recovery)}, plus HST. The tracker's evidence record is attached by itself.` : 'No rental was under way, so there is nobody to charge.' },
                        { name: 'note', label: 'What happened, in a sentence (the renter sees it on a charge)', type: 'textarea', required: true },
                        ...(f.booking_number ? [
                          { name: 'cost_cents', label: 'Tow, impound and storage, at cost (from the receipts)', type: 'money' as const },
                          { name: 'cost_label', label: 'What the cost is', type: 'text' as const, placeholder: 'Tow and 2 days of storage' },
                          { name: 'police_report', label: 'Police report number (theft)', type: 'text' as const }] : [])]} />}</span></span>) }]} />
      </Card>

      <Card title={`Pound lots (${d.lots.length})`} id="pound-lots" testId="pound-lots"
        aside={d.can.manage ? <Act ops action="pound_lot_save" label="Add a lot" variant="primary" fields={lotFields()} refresh={R} done="Added." testId="lot-add" /> : undefined}>
        <p className="small muted">Known Ontario impound and pound lots. A car whose tracker parks within a lot&apos;s radius for {d.settings.pound_minutes} minutes is flagged. The first lots are the ones the Toronto and Peel police publish; check each with the lot before relying on it.</p>
        {d.can.manage && noPin > 0 && <FindPins count={noPin} refresh={R} />}
        <Table<PoundLot> testId="lots" caption="Pound lots" sort={false} rows={d.lots} empty="No pound lots yet. Add the first one."
          cols={[
            { key: 'name', label: 'Lot', className: 'wrap', render: (l) => <span className="te-ev"><span>{l.name}</span>{l.serves && <span className="small muted">{l.serves}</span>}</span> },
            { key: 'address', label: 'Address', className: 'wrap', render: (l) => <span className="te-ev">{l.address}</span> },
            { key: 'phone', label: 'Phone and hours', className: 'wrap', render: (l) => <span className="te-ev te-ev--short">
              <span>{l.phone ? <a className="link" href={`tel:${l.phone.replace(/[^0-9+]/g, '')}`}>{l.phone}</a> : <span className="muted">No phone on file</span>}</span>
              <span className="small">{l.hours ?? <span className="muted">Hours not on file</span>}</span></span> },
            { key: 'state', label: 'State', className: 'wrap', render: (l) => { const i = lotIssues(l); return <span className="te-ev te-ev--short">
              <span className="te-chips">{i.length ? i.map((x) => <span key={x} className={`ad-b ${x === 'Off' ? 'ad-b--light' : 'ad-b--amber'}`}>{x}</span>) : <span className="ad-b ad-b--dark">Ready</span>}</span>
              {d.can.manage && <span className="te-acts">
                <Act ops action="pound_lot_save" payload={{ id: l.id }} label="Edit" fields={lotFields(l)} refresh={R} done="Saved." testId={`lot-edit-${l.id}`} title={l.name} />
                <Act ops action="pound_lot_save" payload={{ id: l.id, remove: true }} label="Remove" variant="quiet" confirm={`Remove ${l.name} from the pound lots? A lot a flag names is switched off instead, so the flag keeps it.`} refresh={R} done="Removed." testId={`lot-remove-${l.id}`} /></span>}</span>; } }]} />
      </Card>

      {d.can.manage && <Card title="Tracker event settings" id="event-settings" testId="event-settings">
        <Act ops inline action="tracker_settings_save" label="Save the event settings" submitLabel="Save the event settings" refresh={R} done="Saved." testId="event-settings" fields={[
          { name: 'events_on', label: 'Tracker events: evidence records, renter and owner notices, speeding records, harsh driving, tampering and pound flags', type: 'bool', value: d.settings.events_on,
            hint: 'Off until the trackers are installed. Off, only the staff alerts above are made.' },
          { name: 'renter_notices', label: 'Tell the renter (what happened, the charge and the clause)', type: 'bool', value: d.settings.renter_notices },
          { name: 'owner_notices', label: 'Tell the car\'s owner (the event and the place, never the renter)', type: 'bool', value: d.settings.owner_notices },
          { name: 'event_window_minutes', label: 'One alert per car and kind in (minutes)', type: 'number', min: 5, max: 1440, required: true, value: d.settings.event_window_minutes },
          { name: 'harsh_on', label: 'Harsh driving', type: 'bool', value: d.settings.harsh_on },
          { name: 'harsh_count', label: 'Harsh driving: events in the window that make an alert', type: 'number', min: 1, max: 20, required: true, value: d.settings.harsh_count },
          { name: 'harsh_kmh_per_s', label: 'Harsh driving: change of speed that counts (km/h a second)', type: 'number', min: 5, max: 40, required: true, value: d.settings.harsh_kmh_per_s, hint: '14 is about 0.4 g. The tracker\'s own harsh driving alarms always count.' },
          { name: 'night_on', label: 'Alert staff and the owner when a car drives at night', type: 'bool', value: d.settings.night_on, hint: 'The rental agreement sets no curfew, so the renter is not told.' },
          { name: 'night_from', label: 'Night starts (HH:MM)', type: 'text', value: d.settings.night_from, placeholder: '00:00' },
          { name: 'night_to', label: 'Night ends (HH:MM)', type: 'text', value: d.settings.night_to, placeholder: '05:00' },
          { name: 'pound_radius_m', label: 'Pound lots: radius when a lot has none (m)', type: 'number', min: 30, max: 1000, required: true, value: d.settings.pound_radius_m },
          { name: 'pound_minutes', label: 'Pound lots: minutes parked before the flag', type: 'number', min: 0, max: 720, required: true, value: d.settings.pound_minutes },
          { name: 'ingest_per_minute', label: 'Tracker ingest: signed requests accepted a minute', type: 'number', min: 10, max: 6000, required: true, value: d.settings.ingest_per_minute }]} />
        <h3 className="h4 te-h">The charges</h3>
        <Kv rows={[
          ['Speeding over 180 km/h', `${$(d.fees.speeding_180)} plus HST`], ['Speeding over 220 km/h', `${$(d.fees.speeding_220)} plus HST`], ['Speeding over 300 km/h', `${$(d.fees.speeding_300)} plus HST`],
          ['Non-return', `${$(d.fees.non_return)} plus HST and the recovery costs`], ['Theft recovery', `${$(d.fees.theft_recovery)} plus HST and the costs`]]} />
        <p className="small muted">The amounts are Program settings (<Link prefetch={false} className="link" href="/admin/settings/program">Settings &gt; Program</Link>); the speeding alert level ({d.settings.speed_alert_kmh} km/h, a heads-up with no charge) is in Tracking settings above.</p>
      </Card>}
    </>
  );
}
