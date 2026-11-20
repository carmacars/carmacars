'use client';
import Link from '@/components/Link';
import { useState, useTransition } from 'react';
import { OWNER_TRIP } from '@/features/request-history/model';
import { when } from '@/features/agreement/model';
import { DateInput } from '@/components/DateInput';
import { WhyDisabled } from '@/components/WhyDisabled';
import { useDoor } from './door';
import { fromLocalInput, toLocalInput } from './Act';
import { isCleaningJob, jobLabel, type JobEntry } from './calendar-fleet';
import type { Entry, Veh } from './MasterCalendar';

// The calendar's side panel (a drawer on a desktop, a sheet on a phone): what a bar or a job is, its booking, and for a
// block its end and removal; with no entry, the New block form. r48 ops: split out of MasterCalendar.tsx; a booking says
// Pickup (check-in) and Return (check-out) with the time the car actually came back, and the two end-of-trip jobs
// (Return check-out, Post-trip cleaning) open here.
const DAY = 86_400_000;
const REASONS: Array<[string, string]> = [['service', 'Service'], ['repair', 'Repair'], ['owner_unavailable', 'Owner unavailable'], ['cleaning', 'Cleaning'], ['exit', 'Exit'], ['turo_owner_use', 'Turo owner use'], ['admin', 'Admin']];

export function SidePanel({ sel, vehicles, onClose, onDone }: { sel: { entry?: Entry; job?: JobEntry; vehicle?: Veh; at?: number }; vehicles: Veh[]; onClose: () => void; onDone: () => void }) {
  const { act: adminAct, base } = useDoor();
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  const [conflicts, setConflicts] = useState<Array<{ booking_number: string }> | null>(null);
  const [f, setF] = useState(() => ({ vehicle: sel.vehicle?.id ?? vehicles[0]?.id ?? '', reason: 'service', starts_at: toLocalInput(new Date(sel.at ?? Date.now()).toISOString()), ends_at: toLocalInput(new Date((sel.at ?? Date.now()) + DAY).toISOString()), note: '', remove: '' }));
  const e = sel.entry;
  // r48 ops: a job chip (Return check-out, Post-trip cleaning, a field job)
  const job = sel.job ? jobLabel(sel.job) : e && isCleaningJob(e) ? jobLabel(e) : null;
  const trip = e?.type === 'booking';
  const run = (action: string, p: Record<string, unknown>) => start(async () => {
    setErr(null);
    const r = await adminAct<{ conflicts?: Array<{ booking_number: string }>; id?: string }>(action, p, ['/admin/calendar']);
    if (!r.ok) { setErr(r.message); return; }
    if (action === 'block_create' && !r.data.id && r.data.conflicts?.length) { setConflicts(r.data.conflicts); return; }
    onDone();
  });
  const blockBody = (force = false) => ({ vehicle: f.vehicle, reason: f.reason, starts_at: fromLocalInput(f.starts_at), ends_at: fromLocalInput(f.ends_at), note: f.note, force });
  return (
    <div className="mcal__panel" role="dialog" aria-labelledby="cal-side-t" data-testid="cal-panel">
      <div className="row" style={{ justifyContent: 'space-between' }}><h2 className="d4" id="cal-side-t">{job ? job.name : e ? (e.type === 'booking' ? e.booking_number : e.type === 'block' ? 'Calendar block' : e.type.replace(/_/g, ' ')) : 'New block'}</h2><button className="btn btn--quiet btn--sm" type="button" onClick={onClose}>Close</button></div>
      {e && (
        <dl className="pt-dl small">
          {/* r48 ops: a pickup is the check-in, a return the check-out, with the time the car actually came back */}
          <div><dt>{trip ? 'Pickup (check-in)' : 'From'}</dt><dd>{when(e.starts_at)}</dd></div>
          <div><dt>{trip ? 'Return (check-out)' : 'To'}</dt><dd data-testid="cal-return-time">{trip && e.returned_at ? <>{when(e.returned_at)} <span className="muted">(came back; due {when(e.ends_at ?? e.returned_at)})</span></> : e.ends_at ? <>{when(e.ends_at)}{trip ? <span className="muted"> (due)</span> : null}</> : 'until further notice'}</dd></div>
          {e.status && <div><dt>Status</dt><dd>{e.status.replace(/_/g, ' ')}{e.placeholder ? ', placeholder (never blocks, never handed over, never matched to a toll)' : e.blocks === false ? ', not blocking' : ''}</dd></div>}
          {!!e.clash?.length && <div><dt>Dates taken</dt><dd className="ad-late" data-testid="cal-clash">Clashes with {e.clash.join(', ')}{e.type === 'booking' && !['confirmed', 'on_rent'].includes(e.status ?? '') ? ': offer another car or other dates' : ''}</dd></div>}
          {e.booking_type === 'owner' && <div><dt>Kind</dt><dd data-testid="cal-owner-trip">{OWNER_TRIP}: the owner books their own car, no charge</dd></div>}
          {e.renter && <div><dt>Renter</dt><dd>{e.renter}</dd></div>}
          {e.insurer && <div><dt>Insurer</dt><dd>{e.insurer}{e.provisional ? ', dates provisional' : ''}</dd></div>}
          {e.reason && <div><dt>Reason</dt><dd>{e.reason.replace(/_/g, ' ')}</dd></div>}
          {e.note && <div><dt>Note</dt><dd>{e.note}</dd></div>}
          {e.assignee && <div><dt>Assigned</dt><dd>{e.assignee}</dd></div>}
        </dl>
      )}
      {sel.job && !e && (
        <dl className="pt-dl small" data-testid="cal-job">
          <div><dt>Job</dt><dd>{job!.name}</dd></div>
          <div><dt>{job!.done ? (job!.kind === 'checkout' ? 'Came back' : 'Done') : job!.kind === 'cleaning' ? 'Window' : 'Due'}</dt><dd>{job!.done && sel.job.done_at ? when(sel.job.done_at) : sel.job.ends_at && job!.kind === 'cleaning' ? `${when(sel.job.starts_at)} to ${when(sel.job.ends_at)}` : when(sel.job.starts_at)}</dd></div>
          <div><dt>Status</dt><dd>{job!.done ? 'Done' : (sel.job.status ?? 'scheduled').replace(/_/g, ' ')}</dd></div>
          {sel.job.for_booking && <div><dt>Booking</dt><dd>{sel.job.for_booking}</dd></div>}
          {sel.job.assignee && <div><dt>Assigned</dt><dd>{sel.job.assignee}</dd></div>}
          {sel.job.type === 'field_job' && sel.job.note && <div><dt>Note</dt><dd>{sel.job.note}</dd></div>}
        </dl>)}
      {sel.job && !e && sel.job.for_booking && <Link prefetch={false} className="btn btn--primary btn--sm" href={`${base}/bookings/${sel.job.for_booking}`}>Open the booking</Link>}
      {job?.kind === 'cleaning' && <p className="small muted">Post-trip cleaning is its own job, apart from the return check-out: the car is cleaned and checked clean before it goes out again.</p>}
      {e?.type === 'booking' && <Link prefetch={false} className="btn btn--primary btn--sm" href={`${base}/bookings/${e.booking_number}`}>Open the booking</Link>}
      {e?.type === 'block' && (
        <div className="stack">
          <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => run('block_end', { block: e.id })}>End now</button>
          {/* the cleaning block after a trip (migration 0040) is removed by Fleet, customer service or an Admin; it is not put back */}
          {e.reason === 'cleaning' && (e.note ?? '').startsWith('Cleaning after booking') && <p className="small muted" data-testid="cleaning-block">Added after the trip for cleaning. Remove it if the car is ready sooner.</p>}
          <form className="ad-form" onSubmit={(ev) => { ev.preventDefault(); run(e.reason === 'cleaning' && (e.note ?? '').startsWith('Cleaning after booking') ? 'turnaround_block_remove' : 'block_remove', { block: e.id, reason: f.remove }); }}>
            <div className="field"><label className="label" htmlFor="cal-rm">Reason for removing</label><input className="input" id="cal-rm" value={f.remove} onChange={(x) => setF({ ...f, remove: x.target.value })} required /></div>
            <><button className="btn btn--primary btn--sm ad-btn--danger" type="submit" disabled={pending || !f.remove.trim()} data-testid="block-remove" aria-describedby="why-mastercalendar-391">Remove the block</button><WhyDisabled id="why-mastercalendar-391" why={((!f.remove.trim())) ? 'Say why it is removed first' : null} /></>
          </form>
        </div>
      )}
      {!e && !sel.job && (
        <form className="ad-form" data-testid="block-form" onSubmit={(ev) => { ev.preventDefault(); run('block_create', blockBody()); }}>
          <div className="field"><label className="label" htmlFor="bk-v">Vehicle</label><select className="select" id="bk-v" value={f.vehicle} onChange={(x) => setF({ ...f, vehicle: x.target.value })}>{vehicles.map((v) => <option key={v.id} value={v.id}>{v.label} {v.plate ?? ''}</option>)}</select></div>
          <div className="field"><label className="label" htmlFor="bk-r">Reason</label><select className="select" id="bk-r" value={f.reason} onChange={(x) => setF({ ...f, reason: x.target.value })}>{REASONS.map(([a, b]) => <option key={a} value={a}>{b}</option>)}</select></div>
          <div className="field"><label className="label" htmlFor="bk-s">From</label><DateInput className="input" id="bk-s" type="datetime-local" value={f.starts_at} onChange={(x) => setF({ ...f, starts_at: x.target.value })} required /></div>
          <div className="field"><label className="label" htmlFor="bk-e">To (empty: until further notice)</label><DateInput className="input" id="bk-e" type="datetime-local" value={f.ends_at} onChange={(x) => setF({ ...f, ends_at: x.target.value })} /></div>
          <div className="field"><label className="label" htmlFor="bk-n">Note{f.reason === 'admin' ? ' (required)' : ''}</label><input className="input" id="bk-n" value={f.note} onChange={(x) => setF({ ...f, note: x.target.value })} /></div>
          {conflicts && <div className="ow-warn small"><b>Confirmed bookings in this range:</b> {conflicts.map((c) => c.booking_number).join(', ')}. Creating anyway raises an urgent fleet task for each.
            <button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={() => run('block_create', blockBody(true))}>Create anyway</button></div>}
          <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="block-create">{pending ? 'Working' : 'Create the block'}</button>
        </form>
      )}
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
    </div>
  );
}
