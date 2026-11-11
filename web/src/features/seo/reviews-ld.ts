// Release 36 (migration 2002): real reviews on the public pages, as public.review_summary returns them (the site's
// published reviews and the reviews staff entered as received elsewhere, each with its source). Pure.

export interface ReviewItem { rating: number; title: string | null; body: string | null; name: string | null; month: string; reply: string | null; source: string; source_label: string; vehicle_label: string | null; rewarded?: boolean }
export interface ReviewSummary { scope: 'car' | 'fleet'; count: number; average: number | null; min_for_rating: number; items: ReviewItem[]; rentals?: number | null }

/** schema.org AggregateRating and Review for a summary: only real reviews, only at min_for_rating or more. */
export function reviewLd(s: ReviewSummary | null): { aggregateRating: object; review: object[] } | null {
  if (!s || s.count < s.min_for_rating || s.average === null || !s.items.length) return null;
  return {
    aggregateRating: { '@type': 'AggregateRating', ratingValue: String(s.average), reviewCount: s.count, bestRating: 5, worstRating: 1 },
    review: s.items.slice(0, 5).map((r) => ({ '@type': 'Review', author: { '@type': 'Person', name: r.name ?? 'Renter' }, datePublished: String(r.month).slice(0, 10),
      reviewRating: { '@type': 'Rating', ratingValue: r.rating, bestRating: 5, worstRating: 1 }, ...(r.body ? { reviewBody: r.body } : {}), ...(r.title ? { name: r.title } : {}),
      ...(r.source !== 'site' ? { publisher: { '@type': 'Organization', name: r.source_label.replace(/^via /, '') } } : {}) }))
  };
}
