'use client';
import { useState, useTransition } from 'react';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { periodSendNow } from '@/server/actions/supply';

export type PeriodRow = { seq: number; starts_at: string; ends_at: string; days: number; amount_cents: number; status: 'upcoming' | 'opening' | 'issued' | 'cancelled';
  issued_at: string | null; attempts: number; last_error: string | null; sends_on: string | null; agreement: { number: string; status: string; signed_at: string | null } | null };

const AGREEMENT: Record<string, string> = { open: 'sent, not signed yet', signed: 'signed', completed: 'signed', superseded: 'signed (earlier period)', voided: 'replaced' };

/** The periods of a long rental (0148): each with its own agreement, sent lead days before it starts, and its share. */
export function BookingPeriods({ rows, booking }: { rows: PeriodRow[]; booking: string }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<string | null>(null);
  if (rows.length < 2) return null;
  const next = rows.find((r) => r.status === 'upcoming');
  return (
    <section className="pt-card ad-card stack" aria-labelledby="periods-h" data-testid="booking-periods">
      <h2 className="d4" id="periods-h">Monthly periods ({rows.length})</h2>
      <p className="small muted">A rental this long is cut into periods. Each later period gets its own version of the agreement (CarmaCars&apos; and Blind Spot&apos;s), sent to the renter to sign a few days before it starts, with what is due for it.</p>
      <div className="ad-table-wrap" tabIndex={0} role="region" aria-label="The periods (scrolls sideways)"><table className="ad-table"><caption className="sr-only">Periods</caption>
        <thead><tr><th scope="col">Period</th><th scope="col">Dates</th><th scope="col">Days</th><th scope="col">Share</th><th scope="col">Agreement</th></tr></thead>
        <tbody>{rows.map((r) => (
          <tr key={r.seq} data-testid="period-row">
            <td>{r.seq}</td><td>{when(r.starts_at, false)} to {when(r.ends_at, false)}</td><td>{r.days}</td><td>{money(r.amount_cents)}</td>
            <td>{r.status === 'cancelled' ? 'Cancelled' : r.status === 'upcoming' ? `Sent on ${when(r.sends_on, false)}${r.attempts ? ` (not made: ${r.last_error ?? 'try again'})` : ''}`
              : r.status === 'opening' ? 'Being made' : r.agreement ? `${r.agreement.number}: ${AGREEMENT[r.agreement.status] ?? r.agreement.status}` : r.seq === 1 ? 'The booking\'s agreement' : 'Sent'}</td>
          </tr>))}</tbody></table></div>
      {next && <p className="row"><button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid="period-send-now"
        onClick={() => start(async () => { const r = await periodSendNow(booking); setMsg(r.ok ? `The agreement for period ${r.data.seq} goes out within five minutes.` : r.message); })}>Send the agreement for period {next.seq} now</button>
        {msg && <span className="small" role="status">{msg}</span>}</p>}
    </section>
  );
}
