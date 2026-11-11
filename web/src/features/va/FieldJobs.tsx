import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { Badge, Card, PageHead, Table, t, label } from '@/features/admin/ui';
import { CarBoard, DayTimeline } from '@/features/va/FleetDay';
import { carBoard, type CalVehicle } from '@/features/va/carboard';
import { CarCell } from '@/features/admin/revamp/CarCell';
import { jobsText, type ShiftJobs } from '@/features/field-portal/model';
import { AvailabilityMini } from '@/features/field-portal/AvailabilityMini';
import { PARTS, WEEKDAYS, WEEKDAYS_SHORT, cell, halfHours } from '@/features/field-portal/shift-picker';

// The field jobs board (Fleet at /staff/fleet and an Admin at /admin/field-jobs; r35, 0880): who can be given a job (the academy
// state and next shift beside each name; the Admins always), the shifts field staff take, the next seven days with the days nobody
// works, the handovers and returns on those days, and every job of the next three days. Every action goes through ops_do.
type R = Record<string, unknown>;
export interface Person { id: string; name: string; admin: boolean; locked: boolean; eligible: boolean; next_shift: { starts_at: string; ends_at: string; on_now: boolean } | null;
  /** r35 SP (1770): availability, standing weekly shifts, shifts held in the next days and the minimum */
  availability?: { slots: string[]; note: string | null } | null; standing?: Array<{ id: string; words: string }>; claimed_ahead?: number; under_min?: boolean }
export interface Slot { id: string; starts_at: string; ends_at: string; capacity: number; note: string | null; people: Array<{ plan_id: string; staff_id: string; name: string }>;
  /** r35 S2 (1051): the jobs on the shift by kind */
  jobs?: ShiftJobs;
  /** r35 SP (1770): eligible people available (their grid) and free then; the people to ask (under their minimum) */
  available?: number; suggest?: Array<{ id: string; name: string; claimed: number }> }
export interface Board {
  staff: Person[]; slots: Slot[]; coverage: Array<{ day: string; slots: number; people: number }>;
  no_shift_days: Array<{ booking_id: string; booking_number: string; leg: string; at: string; day: string; vehicle_name: string; work_day: string | null }>;
  jobs: R[]; unscheduled: R[]; expiry: R[]; documents: R[];
  /** r35 SP (1770) */
  availability_grid?: { eligible: number; cells: Record<string, number> }; rules?: { min: number; ahead: number; alert_hours: number; standing_ahead: number };
}
const KIND: Record<string, string> = { handover: 'Handover', return_check_in: 'Return check-out' };
const dayWord = (d: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', weekday: 'short', month: 'short', day: 'numeric' }).format(new Date(`${d.slice(0, 10)}T12:00:00Z`));

export function FieldJobsBoard({ b, cal, now, photos, base }: { b: Board; cal: CalVehicle[]; now: number; photos: Record<string, string | undefined>; base: '/staff' | '/admin' }) {
  const page = base === '/staff' ? '/staff/fleet' : '/admin/field-jobs';
  const R = [page];
  const eligible = b.staff.filter((s) => s.eligible);
  const options = eligible.map((s) => [s.id, `${s.name}${s.admin ? ' (Admin)' : ''}${s.next_shift ? `, next shift ${t(s.next_shift.starts_at)}` : s.admin ? '' : ', no shift taken'}`] as [string, string]);
  const crew = b.staff.filter((s) => !s.admin);
  const crewOptions = crew.filter((s) => s.eligible).map((s) => [s.id, s.name] as [string, string]);
  // r35 S2 (1051): jobs belong to shifts; a job can be moved to another shift
  const slotOf = (id: unknown) => b.slots.find((s) => s.id === id);
  const slotOptions = b.slots.map((s) => [s.id, `${t(s.starts_at)} to ${t(s.ends_at)}${s.people.length ? `: ${s.people.map((p) => p.name).join(', ')}` : ': nobody yet'}`] as [string, string]);
  const under = crew.filter((s) => s.under_min);
  const late = (j: R) => !j.acknowledged_at && j.status === 'scheduled' && new Date(String(j.scheduled_at)).getTime() - now < 2 * 3600_000;
  const bookingHref = (n: unknown) => `${base}/bookings/${encodeURIComponent(String(n))}`;
  return (
    <div className="fj-board">
      <PageHead title="Field jobs" kicker={`${b.unscheduled.length} without a job · ${b.jobs.filter((j) => !j.assigned_to).length} unassigned`} purpose="Today's handovers, returns and moves by the clock, every car's state now, then every job of the next three days. Where every car is: Fleet map." />
      <p className="small muted" data-testid="fleet-auto-note">Handover and return jobs are made from each confirmed booking, at its times and place. Each job goes on a shift (the one covering its time, or that day&apos;s), and work lands only on days with shifts. The people on a shift share its jobs, least busy first; a shift nobody holds keeps its jobs for whoever claims it. Move a job to another shift, give it to a person on a shift that day, or change its time and place below.</p>
      {base === '/admin' && <p className="small" data-testid="admin-field-portal">Jobs given to you open on the <Link prefetch={false} className="link" href="/staff/field">field portal</Link>. You do not need a Fleet role: an Admin has every action here.</p>}
      {b.no_shift_days.length > 0 && (
        <div className="alert alert--warn" role="status" data-testid="no-shift-days">
          <p><b>{b.no_shift_days.length === 1 ? 'One handover or return falls' : `${b.no_shift_days.length} handovers and returns fall`} on a day with no shifts.</b> Someone must cover {b.no_shift_days.length === 1 ? 'it' : 'them'}, or the booking time must move.</p>
          <ul>{b.no_shift_days.map((w) => <li key={`${w.booking_id}-${w.leg}`}>{w.leg === 'handover' ? 'Handover' : 'Return'} <Link prefetch={false} className="link" href={bookingHref(w.booking_number)}>{w.booking_number}</Link>, {w.vehicle_name}, {t(w.at)}{w.work_day ? `: planned for ${dayWord(w.work_day)}` : ': no day with shifts to move it to'}</li>)}</ul>
        </div>
      )}
      <div className="va-cols">
        <DayTimeline jobs={b.jobs} now={now} />
        <CarBoard rows={carBoard(cal, now)} now={now} carHref={(id) => `${base}/vehicles/${id}`} />
      </div>
      <div className="stack">
        <Card title="Shifts, next seven days" testId="shifts">
          <ul className="fj-days" data-testid="coverage">{b.coverage.map((c) => (
            <li key={c.day} className={c.people === 0 ? 'is-empty' : undefined}><b>{dayWord(c.day)}</b><span>{c.people === 0 ? 'Nobody on a shift' : `${c.people} ${c.people === 1 ? 'person' : 'people'} on a shift`}</span><span className="small">{c.slots} open {c.slots === 1 ? 'slot' : 'slots'}</span></li>))}</ul>
          {b.availability_grid && <div data-testid="availability-grid"><p className="small"><b>Who is free when</b>: of {b.availability_grid.eligible} field {b.availability_grid.eligible === 1 ? 'person' : 'people'} who can take shifts, how many ticked each time. Publish where people are free.</p>
            <div className="sp-heat" role="table" aria-label="Field staff available by weekday and part of the day"><span aria-hidden="true" />{WEEKDAYS_SHORT.map((d) => <b key={d}>{d}</b>)}
              {PARTS.map((p) => [<b key={p.key}>{p.short}</b>, ...WEEKDAYS.map((w, i) => { const n = b.availability_grid!.cells[cell(i + 1, p.key)] ?? 0;
                return <span key={w + p.key} className={n ? undefined : 'is-none'} title={`${w} ${p.label.toLowerCase()}: ${n} available`}>{n}</span>; })])}</div></div>}
          {under.length > 0 && <p className="alert alert--warn" role="status" data-testid="under-min"><span><b>Under the minimum</b> ({b.rules?.min} shifts in the next {b.rules?.ahead} days): {under.map((p) => `${p.name} (${p.claimed_ahead ?? 0})`).join(', ')}. They have a To do and a reminder.</span></p>}
          <div className="ad-actions"><Act ops action="field_slot_publish" label="Publish shifts" variant="primary" testId="publish-shifts" fields={[
            { name: 'starts_at', label: 'First day, start', type: 'datetime', required: true }, { name: 'ends_at', label: 'First day, end', type: 'datetime', required: true },
            { name: 'capacity', label: 'How many people', type: 'number', required: true, min: 1, max: 50, value: 1 },
            { name: 'repeat_days', label: 'Same hours for this many days', type: 'number', min: 1, max: 14, value: 7 }, { name: 'note', label: 'Note', type: 'text' }]} refresh={R} done="Published. Field staff can take them." /></div>
          <Table rows={b.slots as unknown as R[]} empty="No open shifts. Publish the coming week so field staff can take them." cols={[
            { key: 'starts_at', label: 'When', className: 'fj-when', render: (r) => <>{t(r.starts_at)} to {t(r.ends_at)}</> },
            { key: 'jobs', label: 'Jobs on it', className: 'wrap', render: (r) => { const s = r as unknown as Slot; const w = jobsText(s.jobs); return w ? <span className={s.people.length ? undefined : 'ad-flag ad-flag--red'} data-testid="slot-jobs">{w}{s.people.length ? '' : ', nobody on it'}</span> : <span className="muted">none yet</span>; } },
            { key: 'available', label: 'Available', className: 'wrap', render: (r) => { const s = r as unknown as Slot; return <span data-testid="slot-available">{s.available ?? 0} free{s.suggest?.length ? <>{' · ask '}{s.suggest.map((p) => <Act key={p.id} ops action="field_shift_plan_add" payload={{ slot: s.id, staff: p.id }} label={`Add ${p.name}`} variant="quiet" testId={`suggest-${s.id}-${p.id}`} refresh={R} done="Added." />)}</> : null}</span>; } },
            { key: 'people', label: 'Taken', className: 'wrap', render: (r) => {
              const s = r as unknown as Slot;
              return <>{s.people.length} of {s.capacity}{s.people.length ? <>: {s.people.map((p, i) => <span key={p.plan_id}>{i ? ', ' : ''}{p.name} <Act ops action="field_shift_plan_cancel" payload={{ id: p.plan_id }} label="Remove" variant="quiet" confirm={`Take ${p.name} off this shift?`} refresh={R} /></span>)}</> : null}</>;
            } },
            { key: 'act', label: '', render: (r) => <span className="ad-actions">
              <Act ops action="field_shift_plan_add" payload={{ slot: r.id }} label="Add a person" fields={[{ name: 'staff', label: 'Field staff', type: 'select', required: true, options: crewOptions }]} refresh={R} />
              <Act ops action="field_slot_cancel" payload={{ id: r.id }} label="Cancel shift" variant="quiet" confirm="Cancel this shift for everyone on it?" refresh={R} /></span> }]} />
        </Card>
        <Card title="Field staff" testId="field-people">
          <Table rows={b.staff as unknown as R[]} empty="No field staff yet." cols={[
            { key: 'name', label: 'Name', render: (r) => <>{String(r.name)}{r.admin ? <span className="muted small"> · Admin</span> : null}</> },
            { key: 'locked', label: 'Academy', render: (r) => r.admin ? <span className="muted">not needed</span> : r.locked ? <span className="ad-flag ad-flag--red">not passed yet</span> : <span>passed or not required</span> },
            { key: 'next_shift', label: 'Next shift', render: (r) => { const n = r.next_shift as Person['next_shift']; return n ? <>{n.on_now ? 'on now, until ' : ''}{t(n.on_now ? n.ends_at : n.starts_at)}</> : <span className="muted">{r.admin ? 'none needed' : 'none taken'}</span>; } },
            // r35 SP (1770): when they can work, their standing shifts and the minimum
            { key: 'claimed_ahead', label: `Next ${b.rules?.ahead ?? 7} days`, render: (r) => r.admin ? null : <span className={r.under_min ? 'ad-flag ad-flag--red' : undefined} data-testid="claimed-ahead">{Number(r.claimed_ahead ?? 0)} of {b.rules?.min ?? 0}{r.under_min ? ', under' : ''}</span> },
            { key: 'availability', label: 'Usually free', className: 'wrap', render: (r) => { const p = r as unknown as Person; return p.admin ? null : <AvailabilityMini slots={p.availability?.slots} note={p.availability?.note} />; } },
            { key: 'standing', label: 'Standing shifts', className: 'wrap', render: (r) => { const p = r as unknown as Person; if (p.admin) return null; return <span className="ad-actions">
              {(p.standing ?? []).map((x) => <span key={x.id}>{x.words} <Act ops action="field_standing_end" payload={{ id: x.id }} label="End" variant="quiet" confirm={`End ${x.words} for ${p.name}? The shifts already claimed stay.`} refresh={R} /></span>)}
              {p.eligible && <Act ops action="field_standing_add" payload={{ staff: p.id }} label="Add standing" variant="quiet" testId={`standing-add-${p.id}`} refresh={R} done="Set. Matching shifts are claimed for them." fields={[
                { name: 'weekday', label: 'Every', type: 'select', required: true, value: '6', options: WEEKDAYS.map((w, i) => [String(i + 1), w] as [string, string]) },
                { name: 'start', label: 'From', type: 'select', required: true, value: '10:00', options: halfHours() }, { name: 'end', label: 'To', type: 'select', required: true, value: '18:00', options: halfHours() }]} />}</span>; } }]} />
        </Card>
        <Card title="Handovers and returns without a job" testId="unscheduled">
          <Table rows={b.unscheduled} rowKey={(r) => `${r.booking_id}-${r.leg}`} empty="Every handover and return has a job." cols={[
            { key: 'at', label: 'When', render: (r) => t(r.at) }, { key: 'leg', label: 'Job', render: (r) => KIND[String(r.leg)] ?? label(r.leg) },
            { key: 'booking_number', label: 'Booking', render: (r) => <Link prefetch={false} className="link" href={bookingHref(r.booking_number)}>{String(r.booking_number)}</Link> },
            { key: 'vehicle_name', label: 'Car', render: (r) => <CarCell name={r.vehicle_name} photo={photos[String(r.vehicle_id)]} /> }, { key: 'place', label: 'Place', className: 'wrap' },
            { key: 'act', label: '', render: (r) => <Act action="field_job_create" payload={{ booking: r.booking_id, vehicle: r.vehicle_id, kind: r.leg }} label="Schedule" variant="primary" testId={`schedule-${String(r.booking_number)}-${String(r.leg)}`} fields={[
              { name: 'assigned_to', label: 'Assigned to', type: 'select', options }, { name: 'scheduled_at', label: 'When', type: 'datetime', required: true, value: r.at },
              { name: 'place', label: 'Place', type: 'address', required: true, value: r.place ?? 'Our location' }, { name: 'instructions', label: 'Instructions', type: 'textarea' }]} refresh={R} done="Scheduled." /> }]} />
        </Card>
        <Card title="Jobs, next three days" testId="jobs">
          <Table rows={b.jobs} empty="No jobs." cols={[
            { key: 'scheduled_at', label: 'When', className: 'fj-when', render: (r) => <><span className={late(r) ? 'ad-late' : undefined}>{t(r.scheduled_at)}</span>{r.work_day ? <span className="muted small" data-testid="work-day"><br />planned for {dayWord(String(r.work_day))}</span> : null}{r.place ? <span className="muted small"><br />{String(r.place)}</span> : null}</> },
            { key: 'kind', label: 'Kind', render: (r) => <>{label(r.kind)}{r.auto_created ? <span className="muted small"> · made from the booking</span> : null}</> },
            { key: 'vehicle_name', label: 'Car', render: (r) => <CarCell name={r.vehicle_name} sub={r.booking_number} photo={photos[String(r.vehicle_id)]} /> },
            { key: 'shift_slot_id', label: 'Shift', className: 'wrap', render: (r) => { const s = slotOf(r.shift_slot_id); return s ? <span data-testid="job-shift">{t(s.starts_at)}</span> : <span className="muted">no shift</span>; } },
            { key: 'assignee_name', label: 'Field staff', render: (r) => r.assignee_name ? <>{String(r.assignee_name)} {r.acknowledged_at ? <span className="muted small">acknowledged</span> : <span className="ad-flag ad-flag--red">not acknowledged</span>}</> : <span className="ad-flag ad-flag--red">nobody</span> },
            { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> },
            { key: 'act', label: '', render: (r) => ['done', 'cancelled'].includes(String(r.status)) ? null : <span className="ad-actions">
              <Act ops action="field_job_assign" payload={{ id: r.id }} label={r.assigned_to ? 'Reassign' : 'Assign'} testId={`assign-${String(r.id)}`} fields={[{ name: 'to', label: 'Field staff on a shift that day, or an Admin', type: 'select', required: true, options }]} refresh={R} />
              {r.assigned_to ? <Act ops action="field_job_unassign" payload={{ id: r.id }} label="Unassign" testId={`unassign-${String(r.id)}`} fields={[{ name: 'tell', label: 'Tell them', hint: 'Send them the message that the job was taken off.', type: 'bool' }]} refresh={R} done="Taken off." /> : null}
              {slotOptions.length ? <Act ops action="field_job_shift" payload={{ id: r.id }} label="To a shift" testId={`to-shift-${String(r.id)}`} fields={[{ name: 'slot', label: 'Shift', type: 'select', required: true, options: slotOptions }]} refresh={R} done="Moved to the shift." /> : null}
              <Act ops action="field_job_reschedule" payload={{ id: r.id }} label="Move" fields={[{ name: 'scheduled_at', label: 'When', type: 'datetime', required: true, value: r.scheduled_at }, { name: 'place', label: 'Place', type: 'address', value: r.place ?? '' }]} refresh={R} />
              <Act ops action="field_job_cancel" payload={{ id: r.id }} label="Cancel" fields={[{ name: 'reason', label: 'Reason', type: 'text', required: true }]} refresh={R} /></span> }]} />
        </Card>
        <Card title="Expiry watch" id="expiry"><Table rows={b.expiry} empty="Nothing expiring." cols={[{ key: 'due_at', label: 'Due', render: (r) => t(r.due_at) }, { key: 'title', label: 'What', className: 'wrap' }, { key: 'vehicle_name', label: 'Car', render: (r) => <CarCell name={r.vehicle_name} photo={photos[String(r.vehicle_id)]} /> },
          { key: 'act', label: '', render: (r) => <Link prefetch={false} className="link" href={`${base}/tasks/${String(r.id)}`}>Open</Link> }]} /></Card>
        <Card title="Vehicle documents"><Table rows={b.documents} empty="No vehicle documents." cols={[{ key: 'created_at', label: 'Added', render: (r) => t(r.created_at) }, { key: 'kind', label: 'Kind', render: (r) => label(r.kind) }, { key: 'title', label: 'Title', className: 'wrap' },
          { key: 'vehicle_name', label: 'Car', render: (r) => <Link prefetch={false} className="link" href={`${base}/vehicles/${String(r.vehicle_id)}`}>{String(r.vehicle_name)}</Link> }]} /></Card>
      </div>
    </div>
  );
}
