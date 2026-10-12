import { rpc } from '@/lib/db/repo';
import { getSettings } from '@/lib/site';
import { MONTHS } from '@/lib/dates';

// Our renters' reviews (public_reviews, approved by staff), then Google reviews with
// "Reviews from Google" and a link to the profile (site_settings.google_place_id). Both have an
// honest empty state; nothing is invented and no rating is marked up as structured data.
type Review = { review_id: string; vehicle_label: string | null; rating: number; title: string | null; body: string | null; reviewer_first_name: string | null; review_month: string | null; staff_reply: string | null };

const Stars = ({ n }: { n: number }) => <span className="stars" role="img" aria-label={`${n} out of 5 stars`}>{'★'.repeat(Math.round(n))}{'☆'.repeat(5 - Math.round(n))}</span>;
const month = (iso: string | null) => (iso ? `${MONTHS[+iso.slice(5, 7) - 1]} ${iso.slice(0, 4)}` : '');

export async function Reviews({ vehicleId, limit = 6 }: { vehicleId?: string; limit?: number }) {
  const [s, rows] = await Promise.all([getSettings(), rpc('public_reviews', { p_vehicle: vehicleId, p_limit: limit, p_offset: 0 }) as unknown as Promise<Review[]>]);
  const link = s.google_place_id ? `https://www.google.com/maps/place/?q=place_id:${encodeURIComponent(s.google_place_id)}` : null;
  return (
    <div className="reviews">
      <div className="reviews__set">
        <section aria-label="Reviews from our renters" className="stack">
          {rows.length ? (
            <ul className="reviews__list">{rows.map((r) => (
              <li className="review" key={r.review_id}>
                <Stars n={r.rating} />
                <blockquote>{r.title && <p><b>{r.title}</b></p>}<p>{r.body}</p></blockquote>
                <p className="review__by"><b>{r.reviewer_first_name}</b><span className="muted small">{[r.vehicle_label, month(r.review_month)].filter(Boolean).join(', ')}</span></p>
                {r.staff_reply && <p className="small muted">Reply from {s.brand_name}: {r.staff_reply}</p>}
              </li>
            ))}</ul>
          ) : (
            <div className="reviews__empty"><p className="d4">No reviews from our renters yet.</p><p className="muted measure small">After each rental we ask the renter how it went. Reviews appear here once our team has checked them.</p></div>
          )}
        </section>
        <section aria-label="Google reviews">
          <div className="greviews">
            <div className="greviews__head"><p className="greviews__source">Reviews from <span className="glogo">Google</span></p></div>
            <div className="reviews__empty"><p className="d4">Google reviews will show here.</p><p className="muted measure small">They appear once our Google Business Profile is connected and has reviews. We show them as written, newest first, and never edit them.</p></div>
            <p className="xs muted greviews__foot">Reviews are written by Google users and shown through Google.{link && <> <a className="link" href={link} rel="noopener">See all reviews on Google</a></>}</p>
          </div>
        </section>
      </div>
    </div>
  );
}
