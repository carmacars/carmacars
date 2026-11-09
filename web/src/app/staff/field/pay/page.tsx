import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { dollarsText, hoursText, methodWords } from '@/features/field-pay/model';
import { PayIdentityForm } from '@/features/field-portal/PayIdentityForm';
import type { PayIdentity } from '@/server/actions/field-work';
import { PayDetails } from '@/features/staff/PayDetails';
import type { PayDetailsView } from '@/features/staff/pay-details';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My pay', path: '/staff/field/pay', noindex: true, description: 'Your hours, pay statements and pay details.' });

type Shift = { id: string; started_at: string; ended_at: string | null; note: string | null; source: string; minutes: number; day: string; edits: number;
  jobs: Array<{ id: string; kind: string; booking_number: string | null; vehicle: string | null }> | null };
type Hours = { period: { start: string; end: string; label: string; pay_day_note: string };
  so_far: { hours: string; minutes: number; rate_cents: number; wage_cents: number; overtime_cents: number; commission_cents: number; vacation_cents: number; gross_cents: number };
  recent: Shift[]; statements: Array<{ id: string; period_label: string; statement_number: string | null; hours: string; gross_cents: number; status: string; paid_on: string | null; method: string | null }> };

const day = (s: string) => new Date(`${s}T12:00:00Z`).toLocaleDateString('en-CA', { timeZone: 'UTC', weekday: 'short', month: 'short', day: 'numeric' });
const clock = (iso: string) => new Date(iso).toLocaleTimeString('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' });

// My pay (r35 part X; 0165, 0730, 0931): the pay details step first while it is not done, then this period's hours and pay, the recent
// shifts and the statements, and how you are paid. Clock in and out is on Today, with the shift.
export default async function MyPay() {
  const { user } = await requireStaff('field', '/staff/field/pay');
  const [h, pid, payout] = await Promise.all([door<Hours>(user.id, 'ops_read', 'field_hours'), door<PayIdentity>(user.id, 'field_read', 'my_pay_identity'),
    door<PayDetailsView>(user.id, 'field_read', 'my_pay_details').catch(() => null)]);
  const s = h.so_far;
  return (
    <>
      <header className="fp-hello"><h1>My pay</h1><p>{h.period.label}</p></header>
      {!pid.complete && <PayIdentityForm v={pid} />}
      <section className="fd-card" aria-labelledby="hrs-so" data-testid="hours-so-far">
        <h2 className="fd-section-h" id="hrs-so">This pay period so far</h2>
        <p className="fp-big">{hoursText(s.minutes)}</p>
        <p className="small">At {dollarsText(s.rate_cents)} an hour: {dollarsText(s.wage_cents)}{s.overtime_cents > 0 ? `, overtime ${dollarsText(s.overtime_cents)}` : ''}{s.commission_cents > 0 ? `, commissions approved so far ${dollarsText(s.commission_cents)}` : ''}{s.vacation_cents > 0 ? `, vacation pay ${dollarsText(s.vacation_cents)}` : ''}. Total {dollarsText(s.gross_cents)} before any deduction.</p>
        <p className="small muted">{h.period.pay_day_note}.</p>
      </section>
      <section className="fd-card" aria-labelledby="hrs-st"><h2 className="fd-section-h" id="hrs-st">Pay statements</h2>
        {h.statements.length ? <ul className="fd-shots" data-testid="pay-statements">{h.statements.map((x) => (
          <li key={x.id}><span>{x.period_label} · {x.hours}</span>
            <span>{dollarsText(x.gross_cents)}, {x.status === 'paid' ? `paid ${x.paid_on ? day(x.paid_on) : ''}${x.method ? ` by ${methodWords(x.method)}` : ''}` : 'to be paid'} · <a className="link" href={`/files/pay_statement/${x.id}`} data-testid={`statement-${x.id}`}>PDF</a></span></li>))}</ul>
          : <p className="small muted">Your first statement appears once an Admin approves the pay run for a finished period.</p>}
      </section>
      <section className="fd-card" aria-labelledby="hrs-recent"><h2 className="fd-section-h" id="hrs-recent">Recent hours</h2>
        {h.recent.length ? <ul className="fd-shots" data-testid="recent-shifts">{h.recent.map((x) => (
          <li key={x.id}><span>{day(x.day)}, {clock(x.started_at)} to {x.ended_at ? clock(x.ended_at) : 'now'}{x.source === 'manual' ? ' · entered by the office' : ''}{x.edits > 0 ? ' · changed by the office' : ''}</span>
            <span>{hoursText(x.minutes)}</span></li>))}</ul>
          : <p className="small muted">No hours in the last three weeks. Clock in on Today when you start.</p>}
        <p className="small muted">Forgot to clock out, or a time is wrong? Tell Fleet: they fix it and write down why.</p>
      </section>
      {pid.complete && <PayIdentityForm v={pid} />}
      <PayDetails portal="field" view={payout} />
    </>
  );
}
