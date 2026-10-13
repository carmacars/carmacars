import { Act } from '@/features/admin/Act';
import { Card, Kv, ago, t } from '@/features/admin/ui';

// The late-return panel (05-va.md section 3.4, procedure 8): the clock from the return time, the next step
// with its time, and the buttons. T13 and T14 are the same events the late-returns job sends, so a press
// after the job (or a second press) sends nothing more; a disable is a request an Admin approves.
export interface Late { booking_id: string; booking_number: string; status: string; return_at: string; now: string; late: boolean; minutes_late: number;
  renter: { name: string; mobile: string | null } | null; t13_at: string | null; t14_at: string | null; notice_minutes: number;
  steps: Array<{ at: string; label: string; done: boolean }>; calls: Array<{ at: string; note: string; by: string | null }>;
  tracker: { installed: boolean; reported_at: string | null; reporting: boolean } | null; disable: { status: string; created_at: string } | null;
  incident: { number: string; kind: string; status: string } | null }

export function LatePanel({ l, fleet, refresh }: { l: Late; fleet: boolean; refresh: string[] }) {
  const now = new Date(l.now).getTime();
  const P = { booking: l.booking_id };
  const t14Ready = l.minutes_late >= 120;
  const disableReady = Boolean(l.t14_at) && now - new Date(l.t14_at!).getTime() >= l.notice_minutes * 60_000;
  return (
    <Card title={<>Late return: <span className="ad-score--low">{ago(l.minutes_late)}</span></>} tone="warn" testId="late-panel"
      aside={l.renter?.mobile ? <a className="btn btn--ghost btn--sm" href={`tel:${l.renter.mobile.replace(/[^\d+]/g, '')}`}>Call {l.renter.name.split(' ')[0]}</a> : null}>
      <ol className="ad-steps">{l.steps.map((s) => {
        const due = !s.done && new Date(s.at).getTime() <= now;
        return <li key={s.label} className={s.done ? 'is-done' : due ? 'is-due' : ''}><span className="small">{t(s.at)}</span><span>{s.done ? '✓ ' : ''}<b>{s.label}</b></span></li>;
      })}</ol>
      <Kv rows={[['Return was due', t(l.return_at)], ['T13 sent', l.t13_at ? t(l.t13_at) : 'not yet'], ['T14 sent', l.t14_at ? t(l.t14_at) : 'not yet'],
        ['Tracker', !l.tracker?.installed ? 'none installed' : l.tracker.reporting ? `reporting (${t(l.tracker.reported_at)})` : `not reporting since ${t(l.tracker.reported_at)}`],
        ['Disable', l.disable ? `${l.disable.status.replace(/_/g, ' ')} (${t(l.disable.created_at)})` : 'not requested'],
        ['Incident', l.incident ? `${l.incident.number}, ${l.incident.status}` : 'none']]} />
      {l.calls.length > 0 && <ul className="small">{l.calls.map((c) => <li key={c.at}>{t(c.at)}: {c.note}{c.by ? ` (${c.by})` : ''}</li>)}</ul>}
      <div className="ad-actions">
        <Act action="late_call" payload={P} label="Log a call" testId="late-call" fields={[{ name: 'note', label: 'What happened', type: 'textarea', required: true }]} refresh={refresh} done="Call logged." />
        <Act action="late_t13" payload={P} label={l.t13_at ? 'T13 sent' : 'Send T13'} testId="late-t13" disabled={Boolean(l.t13_at)} refresh={refresh} done="T13 sent." />
        <Act action="late_t14" payload={P} label={l.t14_at ? 'T14 sent' : 'Send T14 (final notice)'} testId="late-t14" disabled={Boolean(l.t14_at) || !t14Ready}
          confirm="Send the final notice (T14)? The disable can be requested once the notice time has passed." refresh={refresh} done="T14 sent." />
        {fleet && <Act action="late_disable" payload={P} label="Request disable" variant="danger" testId="late-disable" disabled={!disableReady || Boolean(l.disable)}
          fields={[{ name: 'reason', label: 'Reason for the Admin', type: 'text', required: true, value: 'Not returned after the final notice' }]} refresh={refresh} done="Sent to an Admin for approval." />}
        {fleet && !l.incident && <Act action="late_incident" payload={P} label="Open an incident" testId="late-incident" fields={[{ name: 'note', label: 'What is known', type: 'textarea' }]} refresh={refresh} done="Incident opened." />}
      </div>
      {!t14Ready && <p className="small muted">T14 goes 2 hours after the return time. To offer an extension, write to the renter from the booking&apos;s messages.</p>}
    </Card>
  );
}
