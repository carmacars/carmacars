import { cache } from 'react';
import { JsonLd } from '@/components/JsonLd';
import { rpc } from '@/lib/db/repo';
import { siteUrl } from '@/lib/site';
import { reviewLd, type ReviewSummary } from './reviews-ld';

// Release 36, part 12: real reviews on every car and search page (migration 2002). A car's own reviews when it has
// some, else the fleet's; each with its source ("via Turo"); the rating markup only at the minimum count. Never
// written, never filled in: with no review at all, nothing shows.
export const getReviews = cache(async (vehicleId: string | null): Promise<ReviewSummary | null> => {
  try { return ((await rpc('review_summary', { p_vehicle: vehicleId as string })) ?? null) as unknown as ReviewSummary | null; } catch { return null; }
});
const month = (m: string) => new Intl.DateTimeFormat('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(m));

export function ReviewList({ s }: { s: ReviewSummary }) {
  return <ul className="linklist">{s.items.slice(0, 8).map((r, i) => (
    <li key={i}><p><b>{r.rating} out of 5</b>{r.title ? `: ${r.title}` : ''}</p>{r.body && <p className="small">{r.body}</p>}
      <p className="xs muted">{r.name ?? 'A renter'}, {month(r.month)}{s.scope === 'fleet' && r.vehicle_label ? `, ${r.vehicle_label}` : ''} <span className="badge badge--outline" data-testid="review-source">{r.source_label}</span></p>
      {r.rewarded && <p className="xs muted" data-testid="review-rewarded">Received reward points</p>}
      {r.reply && <p className="small muted">Our reply: {r.reply}</p>}</li>))}</ul>;
}

/** The fleet's reviews on a search page, with the business's rating markup. */
export async function SiteReviews({ look = 'hub' }: { look?: 'hub' | 'vehicle' }) {
  const s = await getReviews(null);
  if (!s || !s.count) return null;
  const ld = reviewLd(s);
  return (
    <section className={look === 'hub' ? 'car-sec landing__sec' : 'vp-sec'} aria-labelledby="h-site-reviews" data-testid="site-reviews">
      <h2 className={look === 'hub' ? 'd2' : 'd3'} id="h-site-reviews">What renters say</h2>
      <p className="small muted">{s.count} {s.count === 1 ? 'review' : 'reviews'} from CarmaCars renters{s.average !== null ? `, ${s.average} out of 5 on average` : ''}, each with where we received it.</p>
      <ReviewList s={s} />
      {ld && <JsonLd graph={[{ '@type': 'AutoRental', '@id': `${siteUrl()}/#business`, ...ld }]} />}
    </section>
  );
}
