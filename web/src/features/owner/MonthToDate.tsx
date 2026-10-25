import Link from 'next/link';
import { money } from '@/lib/format';
import { day, monthOf } from './Blocks';
import type { OwnerMonthToDate } from './types';

// The owner's month to date (0151): the statement this month would give today, marked provisional (bookings, revenue,
// fees, the expected payout), and the rentals still under way. An approved statement for the month is the final one and
// is linked instead. A plain section: the owner portal's design styles it (ow-mtd).
const LINE: Record<string, string> = { rental: 'Rental', turo_trip: 'Turo trip', fees_deducted: 'Fees', late_fee: 'Late fee', owner_cost: 'Cost', credit: 'Credit', kickback: 'Referral kickback' };
const c = (v: number | null | undefined) => money(Number(v ?? 0), { cents: true });

export function MonthToDate({ m }: { m: OwnerMonthToDate | null }) {
  if (!m) return null;
  if (m.final) {
    return (
      <section className="ow-mtd" aria-labelledby="mtd-t" data-testid="owner-mtd">
        <h2 className="d4" id="mtd-t">{monthOf(m.month)}</h2>
        <p>The statement for this month is approved: <Link prefetch={false} className="link" href={`/owner/statements/${m.statement_id}`}>{m.statement_number}</Link>, payout {c(m.payout_cents)} on {day(m.payout_date)}.</p>
      </section>
    );
  }
  const t = m.totals;
  return (
    <section className="ow-mtd" aria-labelledby="mtd-t" data-testid="owner-mtd">
      <h2 className="d4" id="mtd-t">{monthOf(m.month)} so far <span className="badge badge--outline" data-testid="owner-mtd-provisional">Provisional</span></h2>
      <p className="small muted">Worked out live from the rentals finished so far this month. The numbers can still change until CarmaCars approves the statement after the month ends.</p>
      {t ? (
        <dl className="pt-dl" data-testid="owner-mtd-totals">
          <div><dt>Owner Revenue</dt><dd>{c(t.owner_revenue_cents)}</dd></div>
          <div><dt>Revenue Share</dt><dd>{c(-t.revenue_share_cents)}</dd></div>
          {t.deductions_cents > 0 && <div><dt>Fees and deductions</dt><dd>{c(-t.deductions_cents)}</dd></div>}
          {t.kickbacks_earned_cents > 0 && <div><dt>Referral kickbacks</dt><dd>{c(t.kickbacks_earned_cents)}</dd></div>}
          {t.balance_brought_forward_cents !== 0 && <div><dt>Balance brought forward</dt><dd>{c(t.balance_brought_forward_cents)}</dd></div>}
          <div><dt><b>Expected payout</b></dt><dd className="pt-total" data-testid="owner-mtd-payout">{c(t.payout_cents)}{m.payout_date ? <span className="small muted"> on {day(m.payout_date)}</span> : null}</dd></div>
        </dl>
      ) : <p className="small">{m.unavailable ? 'The month so far cannot be worked out right now. Your approved statements are below.' : 'Nothing finished yet this month.'}</p>}
      {(m.vehicles ?? []).filter((v) => v.lines.length).map((v) => (
        <div key={v.vehicle_id} className="ow-mtd__car">
          <h3 className="pt-kicker">{v.name}{v.plate ? ` · ${v.plate}` : ''}</h3>
          <ul className="ow-rows">{v.lines.map((l, i) => (
            <li key={i}><span>{LINE[l.line_type] ?? l.line_type.replace(/_/g, ' ')}{l.booking_number ? ` · ${l.booking_number}` : ''}{l.starts_on ? ` · ${day(l.starts_on)} to ${day(l.ends_on)}` : ''}</span>
              <span className="ow-amount">{c(l.amount_cents)}</span></li>))}</ul>
        </div>))}
      {m.in_progress.length > 0 && (
        <div className="ow-mtd__live" data-testid="owner-mtd-live">
          <h3 className="pt-kicker">Still under way</h3>
          <ul className="ow-rows">{m.in_progress.map((b) => (
            <li key={b.booking_number}><span>{b.vehicle_name} · {b.booking_number}</span><span className="ow-meta"><span>{day(b.pickup_at)} to {day(b.return_at)}</span>
              <span>{b.status === 'on_rent' ? 'On rent' : 'Booked'}</span></span></li>))}</ul>
          <p className="small muted">These join the month once the car is back.</p>
        </div>)}
    </section>
  );
}
