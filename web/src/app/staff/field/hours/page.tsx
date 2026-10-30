import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { ClockPanel, type OpenShift } from '@/features/field-pay/ClockPanel';
import { dollarsText, hoursText, methodWords } from '@/features/field-pay/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My hours', path: '/staff/field/hours', noindex: true, description: 'Clock in and out, your hours and your pay statements.' });

type Shift = { id: string; started_at: string; ended_at: string | null; note: string | null; source: string; minutes: number; open: boolean; day: string; locked: boolean; edits: number;
  jobs: Array<{ id: string; kind: string; booking_number: string | null; vehicle: string | null }> | null };
type Hours = { open: (OpenShift & Shift) | null; period: { start: string; end: string; label: string; pay_day_note: string };
  so_far: { hours: string; minutes: number; rate_cents: number; wage_cents: number; overtime_cents: number; commission_cents: number; vacation_cents: number; gross_cents: number };
  recent: Shift[]; statements: Array<{ id: string; period_label: string; statement_number: string | null; hours: string; gross_cents: number; status: string; paid_on: string | null; method: string | null }> };

const day = (s: string) => new Date(`${s}T12:00:00Z`).toLocaleDateString('en-CA', { timeZone: 'UTC', weekday: 'short', month: 'short', day: 'numeric' });
const clock = (iso: string) => new Date(iso).toLocaleTimeString('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' });

// /field/hours (0165): clock in and out, the hours of the last three weeks with the jobs done in each shift, the pay so far
// in this two-week period, and the pay statements. Fleet or an Admin fixes a forgotten clock-out; the edit is logged with its reason.
export default async function MyHours() {
  const { user } = await requireStaff('field', '/staff/field/hours');
  const h = await door<Hours>(user.id, 'ops_read', 'field_hours');
  const s = h.so_far;
  return (
    <div className="stack">
      <h1 className="d3">My hours</h1>
      <ClockPanel open={h.open} />
      <section className="fd-card" aria-labelledby="hrs-so" data-testid="hours-so-far">
        <h2 className="d4" id="hrs-so">This pay period so far</h2>
        <p className="small muted">{h.period.label}. {h.period.pay_day_note}.</p>
        <p className="fd-big">{hoursText(s.minutes)}</p>
        <p className="small">At {dollarsText(s.rate_cents)} an hour: {dollarsText(s.wage_cents)}{s.overtime_cents > 0 ? `, overtime ${dollarsText(s.overtime_cents)}` : ''}{s.commission_cents > 0 ? `, commissions approved so far ${dollarsText(s.commission_cents)}` : ''}{s.vacation_cents > 0 ? `, vacation pay ${dollarsText(s.vacation_cents)}` : ''}. Total {dollarsText(s.gross_cents)} before any deduction.</p>
      </section>
      <section className="fd-card" aria-labelledby="hrs-recent"><h2 className="d4" id="hrs-recent">Recent shifts</h2>
        {h.recent.length ? <ul className="fd-shots" data-testid="recent-shifts">{h.recent.map((x) => (
          <li key={x.id}><span>{day(x.day)}, {clock(x.started_at)} to {x.ended_at ? clock(x.ended_at) : 'now'}{x.note ? ` · ${x.note}` : ''}{x.source === 'manual' ? ' · entered by the office' : ''}{x.edits > 0 ? ' · changed by the office' : ''}
            {x.jobs && x.jobs.length > 0 && <span className="small muted"> · {x.jobs.length} job{x.jobs.length === 1 ? '' : 's'}: {x.jobs.map((j) => `${j.kind.replace(/_/g, ' ')}${j.booking_number ? ` ${j.booking_number}` : ''}`).join(', ')}</span>}</span>
            <span>{hoursText(x.minutes)}</span></li>))}</ul>
          : <p className="small muted">No shifts in the last three weeks. Tap Clock in when you start.</p>}
        <p className="small muted">Forgot to clock out, or a time is wrong? Tell Fleet: they fix it and write down why.</p>
      </section>
      <section className="fd-card" aria-labelledby="hrs-st"><h2 className="d4" id="hrs-st">Pay statements</h2>
        {h.statements.length ? <ul className="fd-shots" data-testid="pay-statements">{h.statements.map((x) => (
          <li key={x.id}><span>{x.period_label} · {x.hours} · {x.statement_number}</span>
            <span>{dollarsText(x.gross_cents)}, {x.status === 'paid' ? `paid ${x.paid_on ? day(x.paid_on) : ''}${x.method ? ` by ${methodWords(x.method)}` : ''}` : 'to be paid'} · <a className="link" href={`/files/pay_statement/${x.id}`} data-testid={`statement-${x.id}`}>PDF</a></span></li>))}</ul>
          : <p className="small muted">Your first statement appears once an Admin approves the pay run for a finished period.</p>}
      </section>
    </div>
  );
}
