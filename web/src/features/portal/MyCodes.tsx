import Link from 'next/link';

// The renter's discount codes (migration 0161): the ones issued to them (a game prize, a come-back offer, a code from staff),
// each with what it gives, its last day and how long is left. A code that ended in the last 14 days is shown as ended.
export type MyCode = { code: string; what: string; applies_to: string; valid_until: string | null; ends: string | null; days_left: number | null; status: 'open' | 'on_request' | 'expired' };

export const daysLeftText = (n: number | null) => (n === null ? '' : n === 0 ? 'ends today' : n === 1 ? 'ends tomorrow' : `${n} days left`);

export function MyCodes({ codes }: { codes: MyCode[] }) {
  if (!codes.length) return null;
  return (
    <section className="stack" aria-labelledby="pt-codes" data-testid="my-codes">
      <h2 className="pt-section-title" id="pt-codes">Your discount codes</h2>
      <ul className="pt-list">
        {codes.map((c) => (
          <li key={c.code} className="pt-card" data-testid="my-code" data-status={c.status}>
            <div className="row" style={{ gap: 'var(--s-2)' }}>
              <b>{c.code}</b>
              {c.status === 'open' && <span className="badge badge--dark">{c.what}</span>}
              {c.status === 'on_request' && <span className="badge badge--dark">On a booking request</span>}
              {c.status === 'expired' && <span className="badge badge--red">Ended</span>}
            </div>
            <p className="small">{c.what} {c.applies_to}.{' '}
              {c.status === 'expired' ? <>Ended {c.ends}.</> : c.ends ? <>Good until {c.ends} ({daysLeftText(c.days_left)}).</> : null}
            </p>
            {c.status === 'open' && <p><Link prefetch={false} className="btn btn--ghost" href="/cars">Choose a car</Link> <span className="xs muted">Enter the code in the promo code box when you send your request.</span></p>}
          </li>
        ))}
      </ul>
    </section>
  );
}
