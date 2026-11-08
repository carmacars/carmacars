import { Act, type Field } from '@/features/admin/Act';
import { Card } from '@/features/admin/ui';
import { door } from '@/server/door';
import { overrideView, requestLine, type OverrideRead } from './override';

// The Admin override on a pickup or a return recorded by hand, the past trip, and the requests waiting for an Admin
// (migration 0770), on the booking page of the Admin and every staff portal and on the field job. Each check that stops
// the pickup or the return is listed in words; an Admin presses "Override and record" with the reason (one step), staff
// ask an Admin from the same place and the Admin approves in one tap (here, from the alert or the To do). The override
// is one-shot and scoped to this booking, this action and the checks listed (app.override_skips).
const now = () => new Date().toISOString();

function handoverFields(kind: 'pickup' | 'return'): Field[] {
  return [
    { name: 'at', label: kind === 'pickup' ? 'Actual pickup time' : 'Actual return time', type: 'datetime', value: now(), required: true, hint: 'Now, or earlier. Late return charges follow this time.' },
    { name: 'odometer_km', label: 'Odometer (km), if known', type: 'number', min: 0 },
    { name: 'fuel_pct', label: 'Fuel or charge (%), if known', type: 'number', min: 0, max: 100 },
    { name: 'reason', label: 'Why the trip must go ahead', type: 'text', required: true, wide: true, hint: 'Recorded on the booking and in the audit log. The photos and readings can be added later.' }
  ];
}

function pastFields(pickupAt: string, returnAt: string): Field[] {
  const ret = new Date(returnAt).getTime() < Date.now() ? returnAt : now();
  return [
    { name: 'pickup_at', label: 'Actual pickup time', type: 'datetime', value: pickupAt, required: true },
    { name: 'return_at', label: 'Actual return time', type: 'datetime', value: ret, required: true, hint: 'Late return charges follow this time.' },
    { name: 'odometer_out_km', label: 'Odometer at pickup (km), if known', type: 'number', min: 0 },
    { name: 'odometer_in_km', label: 'Odometer at return (km), if known', type: 'number', min: 0 },
    { name: 'fuel_out_pct', label: 'Fuel at pickup (%), if known', type: 'number', min: 0, max: 100 },
    { name: 'fuel_in_pct', label: 'Fuel at return (%), if known', type: 'number', min: 0, max: 100 },
    { name: 'reason', label: 'Why it is recorded now', type: 'text', required: true, wide: true, hint: 'For example: the trip happened and was never recorded. The photos can be added later.' }
  ];
}

export async function HandoverOverride({ booking, userId, aal, refresh }: { booking: string; userId: string; aal?: 'aal1' | 'aal2' | null; refresh: string[] }) {
  const r = await door<OverrideRead>(userId, 'ops_read', 'handover_blockers', { booking }, aal).catch(() => null);
  const v = overrideView(r);
  if (!r || !v.show) return null;
  return (
    <Card title={v.blocked ? v.heading : v.requests.length ? 'Waiting for an Admin' : 'Record a past trip'} testId="handover-override" tone={v.requests.length || v.blocked ? 'warn' : undefined}>
      <div className="stack">
        {v.requests.map((q) => (
          <div key={q.id} className="stack" data-testid={`override-request-${q.action}`}>
            <p className="small">{requestLine(q)}</p>
            <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
              {q.canDecide && <Act ops action="override_decide" payload={{ id: q.id, decision: 'approve' }} label="Approve" variant="primary" refresh={refresh} testId={`override-approve-${q.action}`}
                done={q.action === 'book_now' ? 'Booked: the renter has the Sign and pay link.' : 'Approved and recorded.'} />}
              {q.canDecide && <Act ops action="override_decide" payload={{ id: q.id, decision: 'decline' }} label="Decline" refresh={refresh} testId={`override-decline-${q.action}`}
                fields={[{ name: 'note', label: 'Why (the person who asked sees it on the booking)', type: 'text' }]} done="Declined. Nothing changed." />}
              {!q.canDecide && q.canCancel && <Act ops action="override_decide" payload={{ id: q.id, decision: 'cancel' }} label="Cancel the request" refresh={refresh} testId={`override-cancel-${q.action}`} done="Cancelled." />}
              {!q.canDecide && <span className="small muted">An Admin approves it in one tap from their alert or To do.</span>}
            </div>
          </div>))}
        {v.blocked && v.kind && <>
          <ul className="small" data-testid="override-blockers">{r.blockers.map((b) => <li key={b.code}>{b.label}</li>)}</ul>
          <p className="small muted">{r.admin
            ? 'When the trip must go ahead anyway: override these checks with the reason. Only these checks, for this booking, once. It is recorded on the booking and in the audit log, and Admins are told.'
            : 'When the trip must go ahead anyway: ask an Admin. They approve in one tap, and it is recorded with the time you enter here.'}</p>
          <Act ops action="handover_override" payload={{ booking: r.booking_id, kind: v.kind }} label={v.overrideLabel} variant={r.admin ? 'primary' : 'ghost'}
            fields={handoverFields(v.kind)} refresh={refresh} done={v.overrideDone} testId={`override-${v.kind}`} />
        </>}
        {v.pastTrip && <>
          <p className="small">The pickup and the return both happened but were never recorded: record the whole trip in one step. The booking lands in Returned so the deposit can be settled; km, fuel and photos can come later.</p>
          <Act ops action="handover_override" payload={{ booking: r.booking_id, kind: 'past_trip' }} label={v.pastLabel} fields={pastFields(r.pickup_at, r.return_at)}
            refresh={refresh} done={v.pastDone} testId="override-past-trip" />
        </>}
      </div>
    </Card>
  );
}
