import Link from '@/components/Link';
import { CarCard } from '@/components/CarCard';
import type { CarRow } from '@/lib/types';
import { requestHref } from '@/features/vehicles/parts';
import { pickSimilar } from './steer';

// Release 36, part 1: a search page whose own list is empty never says so. It shows the cars ready to book now (the
// closest by price, popular cars last, rotated by the page; src/features/seo/steer.ts) and the "Request this exact
// car" box (the existing enquiry flow: a lead in Admin > Leads and the Sales queue).
export function ReadyCars({ cars, labels, want, pageKey, n = 6 }: { cars: CarRow[]; labels: Record<string, string>; want: string; pageKey: string; n?: number }) {
  const ready = pickSimilar([...cars].sort((a, b) => a.daily_rate_cents - b.daily_rate_cents), n, pageKey);
  return (
    <div data-testid="ready-cars">
      {ready.length > 0 && <>
        <p className="lead muted">Ready to book now, delivered or picked up in Toronto:</p>
        <ul className="fleet-grid fleet-grid--3">{ready.map((c) => <li key={c.slug}><CarCard c={c} labels={labels} /></li>)}</ul>
      </>}
      <RequestExact want={want} />
    </div>
  );
}

/** "Request this exact car": the reader names it, we look for it for their dates. Nothing is booked or charged. */
export function RequestExact({ want }: { want: string }) {
  return (
    <div className="vp-request" data-testid="request-exact">
      <div><h3 className="d4">Request this exact car</h3><p className="small muted">Tell us your dates and we look for {want} for you. Nothing is booked or charged.</p></div>
      <Link prefetch={false} className="btn btn--primary" href={requestHref(want)} rel="nofollow">Request it</Link>
    </div>
  );
}
