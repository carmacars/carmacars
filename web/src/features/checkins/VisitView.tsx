import Link from '@/components/Link';
import { Card, Kv } from '@/features/admin/ui';
import { Act } from '@/features/admin/Act';
import { CheckinChecklist } from './Checklist';
import { BUCKETS, BUCKET_TONE, WHY_WORDS, dayWords, serviceWords, timeWords, torontoDay, type VisitRead } from './model';

// One check-in visit (release 50, migration 4000), the same in every staff portal: who and which car, when, and the
// checklist while it is open; what was found once done. Staff can book a time for the renter or skip it with the reason.
export function CheckinVisitView({ d, base, bookingHref }: { d: VisitRead; base: string; bookingHref: string | null }) {
  const v = d.visit;
  const refresh = [`${base}/check-ins`, `${base}/check-ins/${v?.id ?? ''}`];
  const open = !!v && (v.status === 'due' || v.status === 'booked');
  const slots: Array<[string, string]> = d.slots.slice(0, 60).map((s) => [s.at, `${dayWords(s.day)}, ${timeWords(s.at)}`]);
  return (
    <div className="stack" data-testid="checkin-visit">
      <Card title={d.car?.name ?? 'The car'} testId="checkin-visit-head" aside={v ? <span className={`ad-b ${BUCKET_TONE[v.bucket]}`}>{BUCKETS.find(([k]) => k === v.bucket)?.[1]}</span> : undefined}>
        <Kv rows={[
          ['Renter', d.renter?.name ? <>{d.renter.name}{d.renter.phone ? <> (<a className="link" href={`tel:${d.renter.phone}`}>{d.renter.phone}</a>)</> : null}</> : null],
          ['Booking', bookingHref ? <Link prefetch={false} className="link" href={bookingHref}>{d.booking.booking_number}</Link> : d.booking.booking_number],
          ['Plate', d.car?.plate ?? null],
          ['Why', d.why ? WHY_WORDS[d.why] : 'No check-in visits on this booking'],
          ['When', v ? v.time_words : null],
          ['Where', v && v.status === 'booked' ? v.place_words : null],
          ['Odometer now', d.car?.current_km ? `${d.car.current_km.toLocaleString('en-CA')} km` : null],
          ['Tire tread', d.car?.tread_mm !== null && d.car?.tread_mm !== undefined ? `${d.car.tread_mm} mm` : null],
          ['Next service', serviceWords(d.car?.next ?? null)],
          ['Next visit after this', d.next_on && !open ? `Around ${dayWords(d.next_on)}` : null]]} />
        {open && v && (
          <span className="ad-actions">
            {slots.length > 0 && <Act ops action="checkin_do" payload={{ op: 'book', id: v.id, place: 'office' }} label={v.status === 'booked' ? 'Change the time' : 'Book a time for the renter'} testId="checkin-staff-book" refresh={refresh} done="Booked: Fleet and the Admins are told."
              fields={[{ name: 'slot_at', label: 'Time', type: 'select', options: slots, required: true }]} />}
            <Act ops action="checkin_do" payload={{ op: 'skip', id: v.id }} label="Skip this month" testId="checkin-skip" refresh={refresh} done="Skipped: the next visit is a month on."
              fields={[{ name: 'reason', label: 'Why', type: 'text', required: true, placeholder: 'The renter is away this month' }]} />
          </span>)}
      </Card>
      {!v && d.on && d.booking.status === 'on_rent' && (
        <Card title="No visit open" testId="checkin-none">
          <p className="small">The next visit is around {d.next_on ? dayWords(d.next_on) : 'later'}. The renter dropped by? Start one now.</p>
          <Act ops action="checkin_do" payload={{ op: 'start', booking: d.booking.booking_number }} label="Start a visit now" testId="checkin-start" refresh={refresh} done="Started: reload to see the checklist." />
        </Card>)}
      {open && v && (
        <Card title="The checklist" testId="checkin-checklist-card">
          <CheckinChecklist visitId={v.id} bookingId={d.booking.id} currentKm={d.car?.current_km ?? null} next={d.car?.next ?? null} refresh={refresh} />
        </Card>)}
      {v && v.status === 'done' && (
        <Card title="What we found" testId="checkin-found">
          <Kv rows={[
            ['Done', v.done_at ? `${dayWords(torontoDay(v.done_at))}${v.done_by_name ? `, by ${v.done_by_name}` : ''}` : null],
            ['Odometer', v.odometer_km ? `${v.odometer_km.toLocaleString('en-CA')} km` : null],
            ['Damage', v.damage_found ? `Yes: ${v.damage_note ?? ''}` : 'No new damage'],
            ['Tire tread', v.tread_mm !== null ? `${v.tread_mm} mm` : null],
            ['Fluids', v.fluids_ok === null ? null : v.fluids_ok ? 'Look right' : 'To check'],
            ['Warning lights', v.warning_lights ?? 'None'],
            ['Next service then', v.next_service ? serviceWords(v.next_service) : null],
            ['Notes', v.notes ?? null],
            ['Photos', v.photos?.length ? `${v.photos.length} taken` : null]]} />
          {(v.task_id || v.damage_intake_id) && <p className="small">{v.task_id ? 'A Fleet To do is open for the maintenance. ' : ''}{v.damage_intake_id ? 'The damage is logged on the Damage tab for the Admins.' : ''}</p>}
        </Card>)}
      {d.history.length > 0 && (
        <Card title="Earlier visits" testId="checkin-history">
          <ul className="ci-list">{d.history.map((h) => (
            <li key={h.id} className="ci-row small"><span>{h.status === 'done' && h.done_at ? dayWords(torontoDay(h.done_at)) : `${h.status}, due ${dayWords(h.due_on)}`}</span>
              <span>{h.status === 'done' ? `${h.odometer_km?.toLocaleString('en-CA') ?? ''} km, ${h.damage_found ? 'damage found' : 'no new damage'}` : h.closed_reason ?? ''}</span></li>))}</ul>
        </Card>)}
    </div>
  );
}
