import Link from 'next/link';
import { PortalCard, PortalIcon } from '@/components/portal-ui';

// The renter's discount codes (migration 0161): the ones issued to them (a game prize, a come-back offer, a code from staff),
// each with what it gives, its last day and how long is left. A code that ended in the last 14 days is shown as ended.
export type MyCode = { code: string; what: string; applies_to: string; valid_until: string | null; ends: string | null; days_left: number | null; status: 'open' | 'on_request' | 'expired' };

export const daysLeftText = (n: number | null) => (n === null ? '' : n === 0 ? 'ends today' : n === 1 ? 'ends tomorrow' : `${n} days left`);

export function MyCodes({ codes }: { codes: MyCode[] }) {
  if (!codes.length) return null;
  return (
    <PortalCard id="pt-codes" title="Your discount codes" testId="my-codes">
      <ul className="stack" style={{ listStyle: 'none', padding: 0, margin: 0 }}>
        {codes.map((c) => (
          <li key={c.code} className="stack" data-testid="my-code" data-status={c.status}>
            <div className="row" style={{ gap: 'var(--s-2)', alignItems: 'center' }}>
              <b>{c.code}</b>
              {c.status === 'open' && <span className="pu-pill pu-pill--live">{c.what}</span>}
              {c.status === 'on_request' && <span className="pu-pill pu-pill--ready">On a booking request</span>}
              {c.status === 'expired' && <span className="pu-pill pu-pill--muted">Ended</span>}
            </div>
            <p className="small">{c.what} {c.applies_to}.{' '}
              {c.status === 'expired' ? <>Ended {c.ends}.</> : c.ends ? <>Good until {c.ends} ({daysLeftText(c.days_left)}).</> : null}
            </p>
            {c.status === 'open' && <p><Link prefetch={false} className="btn btn--ghost btn--sm" href="/cars">Choose a car<PortalIcon name="arrow" size={18} /></Link> <span className="xs muted">Enter the code in the promo code box when you send your request.</span></p>}
          </li>
        ))}
      </ul>
    </PortalCard>
  );
}
