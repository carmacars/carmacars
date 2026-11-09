import type { ReactNode } from 'react';
import Link from '@/components/Link';
import { $, Table, t } from '@/features/admin/ui';
import { PLAN, SORTS, timeLeft, type Countdown, type Countdowns as Data, type Level } from './model';

// Finance countdowns (release 35 part RR, migration 1010): on every booking with a deposit hold, a deposit owed back or a
// weekly, biweekly or monthly plan, the time left before the hold's authorization expires (and when the automatic
// re-authorization runs, 24 hours before), before the deposit return promised to the renter, and before the next rental
// payment (overdue once passed). Red within 24 hours or past, amber within 48. Soonest first, or sorted by one column.
const tone = (l: Level) => (l === 'red' ? 'ad-flag ad-flag--red' : l === 'amber' ? 'ad-b ad-b--amber' : undefined);

function Cell({ at, level, testId, now, children }: { at: string | null; level: Level; testId: string; now: number; children?: ReactNode }) {
  if (!at) return <span className="muted small">none</span>;
  return <span className="stack-xs"><span className={tone(level)} data-testid={testId} data-level={level ?? ''}>{timeLeft(at, now)}</span><span className="xs muted">{t(at)}</span>{children}</span>;
}

export function CountdownTable({ c, base, bookingBase, compact = false }: { c: Data; base?: string; bookingBase: string; compact?: boolean }) {
  const rows = compact ? c.rows.slice(0, 8) : c.rows;
  const now = Date.parse(c.now);
  return (
    <div className="stack" data-testid="finance-countdowns">
      {base && <p className="row small" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>Sort: {SORTS.map(([k, l]) => <Link key={k} prefetch={false} scroll={false} className={k === c.sort ? 'link ad-b' : 'link'} href={`${base}${base.includes('?') ? '&' : '?'}sort=${k}`} aria-current={k === c.sort ? 'true' : undefined}>{l}</Link>)}</p>}
      <Table<Countdown & Record<string, unknown>> testId="countdowns" rows={rows as Array<Countdown & Record<string, unknown>>} rowKey={(r) => r.booking_id}
        empty="No hold, deposit return or plan payment is coming up." cols={[
          { key: 'booking_number', label: 'Booking', render: (r) => <><Link prefetch={false} className="link" href={`${bookingBase}/${encodeURIComponent(r.booking_number)}?tab=money`}>{r.booking_number}</Link><br /><span className="xs muted">{r.plate ?? ''} {r.renter ?? ''}</span></> },
          { key: 'hold', label: 'Deposit hold expires', render: (r) => <Cell at={r.hold_expires_at} level={r.hold_level} testId={`cd-hold-${r.booking_number}`} now={now}>
            {r.reauth_at && <span className="xs">{r.reauth_running ? 'Re-authorizing now' : `Re-authorized automatically from ${t(r.reauth_at)}`}</span>}</Cell> },
          { key: 'return', label: 'Deposit back to the renter by', render: (r) => <Cell at={r.return_due_at} level={r.return_level} testId={`cd-return-${r.booking_number}`} now={now}>
            {r.return_due_at && <Link prefetch={false} className="xs link" href={`${bookingBase}/${encodeURIComponent(r.booking_number)}/deposit-review`}>Deposit review</Link>}</Cell> },
          { key: 'pay', label: 'Next rental payment', render: (r) => <Cell at={r.pay_due_at} level={r.pay_level} testId={`cd-pay-${r.booking_number}`} now={now}>
            {r.pay_due_at && <span className="xs">{r.pay_state === 'overdue' ? 'Overdue' : PLAN[r.pay_plan ?? ''] ?? r.pay_plan}{r.pay_cents ? `: ${$(r.pay_cents)}` : ''}</span>}</Cell> }]} />
      {compact && c.rows.length > rows.length && base && <p className="small"><Link prefetch={false} className="link" href={base}>All {c.rows.length} countdowns</Link></p>}
    </div>
  );
}
