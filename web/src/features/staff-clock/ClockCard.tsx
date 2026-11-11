import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { WaitTimer } from '@/components/portal-ui/WaitTimer';
import { door } from '@/server/door';
import { requestNow } from '@/features/va/lanes';
import { breaksWords, clockLine, type ClockState } from './model';
import { TrackingSignal } from './ActivityBeat';

// The clock on the home of a customer service, Fleet or Finance staff member (1061): Clock in or Clock out, the hours of
// today and the week; the location is never asked (remote work). Their hours are on My hours.
// 1800: Start break and End break next to the clock, the break's running timer (calm, then "late" past the reminder),
// today's breaks, and one line saying activity is counted while clocked in (the fact only). Never any idle figure here.
export async function ClockCard({ userId, aal }: { userId: string; aal: 'aal1' | 'aal2' | null }) {
  const s = await door<ClockState>(userId, 'ops_read', 'va_clock', {}, aal).catch(() => null);
  if (!s) return null;
  const b = s.break ?? null;
  const remind = s.settings?.break_reminder_minutes ?? 30;
  return (
    <section className="pt-card ad-card stack" data-testid="va-clock" aria-label="Clock in">
      <TrackingSignal tracking={!!s.tracking} nudgeMinutes={s.settings?.idle_nudge_minutes ?? 8} />
      <div className="row" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        <p className="small" data-testid="va-clock-line">{clockLine(s)}</p>
        <span className="ad-actions">
          {s.open && (b ? <Act ops action="va_break_end" label="End break" variant="primary" testId="va-break-end" refresh={['/staff']} done="Welcome back." />
            : <Act ops action="va_break_start" label="Start break" testId="va-break-start" refresh={['/staff']} done="Enjoy your break." submitLabel="Start break"
                fields={[{ name: 'reason', label: 'Reason (optional)', type: 'text', placeholder: 'Lunch, prayer, errand…' }]} />)}
          {s.open ? <Act ops action="va_clock_out" label="Clock out" variant={b ? 'ghost' : 'primary'} testId="va-clock-out" refresh={['/staff']} done="Clocked out." />
            : <Act ops action="va_clock_in" label="Clock in" variant="primary" testId="va-clock-in" refresh={['/staff']} done="Clocked in." />}
          <Link prefetch={false} className="link small" href="/staff/hours">My hours</Link>
        </span>
      </div>
      {b && <p className="small row" style={{ gap: 'var(--s-2)', alignItems: 'center' }} data-testid="va-break-now">
        On a break{b.reason ? ` (${b.reason})` : ''}: <WaitTimer since={b.started_at} targetMin={remind} now={requestNow()} label="On a break" testId="va-break-timer" /></p>}
      {b?.over && <p className="alert alert--warn small" role="status" data-testid="va-break-over">Your break has run past {remind} minutes. Press End break when you are back.</p>}
      {s.open && <p className="small muted" data-testid="va-breaks-today">Breaks today: {breaksWords(s.breaks_today)}.</p>}
      <p className="small muted" data-testid="va-clock-tracked">While you are clocked in and not on a break, the portal notes that you are active (never what you type, the pages or the screen).</p>
    </section>
  );
}
