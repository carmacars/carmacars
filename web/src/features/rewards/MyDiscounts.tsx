import Link from '@/components/Link';
import { PortalCard } from '@/components/portal-ui';
import { LiveCountdown } from '@/components/portal-ui/live';
import { CopyLink } from '@/features/portal/CopyLink';
import { discountRows, type SavedDiscount } from './discounts';

// r40 (2423, the owner: "Let renters see their stored discounts"): every code the renter holds, on the portals' card,
// each with what it gives, that it comes off the rental charge only, its end (a live countdown under 30 days), its status
// (unused, on a request, used on booking #, expired) and Copy. Compact on /account: the codes still to use, three at most.
const PILL: Record<string, string> = { open: 'pu-pill pu-pill--live', on_request: 'pu-pill pu-pill--ready', used: 'pu-pill pu-pill--muted', expired: 'pu-pill pu-pill--muted' };

export function MyDiscounts({ list, compact, id = 'pt-discounts' }: { list: SavedDiscount[]; compact?: boolean; id?: string }) {
  const all = discountRows(list);
  const rows = compact ? all.filter((d) => d.status === 'open' || d.status === 'on_request').slice(0, 3) : all;
  if (compact && !rows.length) return null;
  const more = compact ? all.filter((d) => d.status === 'open' || d.status === 'on_request').length - rows.length : 0;
  return (
    <PortalCard id={id} title="Your discounts" testId={compact ? 'my-discounts-compact' : 'my-discounts'}
      action={compact ? <Link prefetch={false} className="link small" href="/account/rewards#pt-discounts">See all</Link> : undefined}>
      {rows.length ? (
        <ul className="stack" style={{ listStyle: 'none', padding: 0, margin: 0 }}>
          {rows.map((d) => (
            <li key={d.code} className="stack" style={{ gap: 'var(--s-1)' }} data-testid="my-discount" data-status={d.status} data-kind={d.kind}>
              <div className="row" style={{ gap: 'var(--s-2)', alignItems: 'center', flexWrap: 'wrap' }}>
                <b className="num" style={{ overflowWrap: 'anywhere' }}>{d.code}</b>
                <span className={PILL[d.status] ?? 'pu-pill'}>{d.state}</span>
                {d.copyable && <CopyLink url={d.code} label="Copy" done="Copied" ariaLabel={`Copy the code ${d.code}`} testId={`copy-${d.code}`} />}
              </div>
              <p className="small" style={{ margin: 0 }}><b>{d.what}</b> {d.applies_to}. <span className="muted">{d.source}.</span></p>
              <p className="xs muted" style={{ margin: 0 }}>{d.countdown && d.valid_until
                ? <>Ends {d.ends}, in <LiveCountdown until={d.valid_until} before="" after="no time: it has ended" initial={d.days_left === 0 ? 'less than a day' : `${d.days_left} ${d.days_left === 1 ? 'day' : 'days'}`} testId={`discount-countdown-${d.code}`} /></>
                : d.until}</p>
            </li>
          ))}
        </ul>
      ) : <p className="small muted" data-testid="my-discounts-empty">No discount codes yet. Turn 500 points into a code below, or earn them with rentals, reviews and referrals.</p>}
      {more > 0 && <p className="xs muted">{more} more on your Rewards page.</p>}
      <p className="xs muted" data-testid="discount-hint">Apply at checkout: when you send a request, pick it under <b>Use a saved discount</b> or type it in the promo code box. One code per booking, off the rental charge only.</p>
    </PortalCard>
  );
}
