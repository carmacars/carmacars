import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { door } from '@/server/door';
import { clockLine, type ClockState } from './model';

// The clock on the home of a customer service, Fleet or Finance staff member (1061): Clock in or Clock out, the hours of
// today and the week; the location is never asked (remote work). Their hours are on My hours.
export async function ClockCard({ userId, aal }: { userId: string; aal: 'aal1' | 'aal2' | null }) {
  const s = await door<ClockState>(userId, 'ops_read', 'va_clock', {}, aal).catch(() => null);
  if (!s) return null;
  return (
    <section className="pt-card ad-card stack" data-testid="va-clock" aria-label="Clock in">
      <div className="row" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        <p className="small" data-testid="va-clock-line">{clockLine(s)}</p>
        <span className="ad-actions">
          {s.open ? <Act ops action="va_clock_out" label="Clock out" variant="primary" testId="va-clock-out" refresh={['/staff']} done="Clocked out." />
            : <Act ops action="va_clock_in" label="Clock in" variant="primary" testId="va-clock-in" refresh={['/staff']} done="Clocked in." />}
          <Link prefetch={false} className="link small" href="/staff/hours">My hours</Link>
        </span>
      </div>
    </section>
  );
}
