import { pageMeta } from '@/features/seo/meta';
import { bookingPath } from '@/features/portal/status';
import { Back } from '@/features/portal/Blocks';
import { ReviewForm } from '@/features/portal/ReviewForm';
import { getSettings } from '@/lib/site';
import { rpc } from '@/lib/db/repo';
import { ReviewHelper } from '@/features/reviews/ReviewHelper';
import { myBooking, reviewState } from '@/server/portal/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Review your rental', path: '/account/bookings', noindex: true, description: 'Rate your rental and tell the next renter how it went.' });

const STATUS: Record<string, string> = { pending: 'With our team, not published yet', published: 'Published on the car’s page', hidden: 'Not published' };

type Helper = { ok: boolean; first_name?: string; vehicle?: string | null; days?: number | null; delivered?: boolean; staff?: string[]; google_url?: string | null; reviewed?: boolean };

// The review request email's link (emails/src/links.mjs booking_review): a closed booking's renter rates it. Since 0138
// the review helper comes first (what they liked, a sentence, a draft to post on Google), the on-site review after it.
export default async function ReviewPage({ params }: { params: Promise<{ number: string }> }) {
  const { user, b } = await myBooking((await params).number, 'review');
  const [s, st] = await Promise.all([getSettings(), reviewState(user, b.id)]);
  // the review page's token (made for a booking on a trip, returned or closed); an Admin viewing as the renter reads none
  const token = await rpc('renter_review_token', { p_booking: b.id, p_by: user.id }, { role: 'service_role' }).catch(() => null) as string | null;
  const h = token ? ((await rpc('server_review_helper', { p_token: token }, { role: 'service_role', skipViewAs: true }).catch(() => null)) as unknown as Helper | null) : null;
  const google = h?.google_url ?? (s.google_place_id ? `https://search.google.com/local/writereview?placeid=${encodeURIComponent(s.google_place_id)}` : null);
  return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <h1 className="d2">Review your rental</h1>
      {token && h?.ok && !st.review && (
        <section className="pt-card" aria-label="Review us on Google" data-testid="review-helper-card">
          <h2 className="d4">Review us on Google</h2>
          <ReviewHelper token={token} firstName={h.first_name ?? ''} bookingNumber={b.booking_number} reviewed={!!h.reviewed}
            facts={{ vehicle: h.vehicle ?? null, days: h.days ?? null, delivered: !!h.delivered, staff: h.staff ?? [] }} googleUrl={google}
            directHref={`${bookingPath(b.booking_number)}#messages`} directLabel="Write to us about this booking" phone={s.phone_display ?? null} />
        </section>
      )}
      {token && h?.ok && !st.review && <h2 className="d4">Or review on our site</h2>}
      <section className="pt-card" aria-label="Your review">
        {st.review ? (
          <div className="stack" data-testid="review-left">
            <p><b aria-label={`${st.review.rating} out of 5 stars`}>{'★'.repeat(st.review.rating)}{'☆'.repeat(5 - st.review.rating)}</b> {st.review.title && <b>{st.review.title}</b>}</p>
            {st.review.body && <p>{st.review.body}</p>}
            <p className="small muted">Thank you. {STATUS[st.review.status] ?? st.review.status}.</p>
            {st.review.staff_reply && <p className="small"><b>Our reply:</b> {st.review.staff_reply}</p>}
            {google && st.review.status === 'pending' && <p><a className="btn btn--ghost" href={google} target="_blank" rel="noopener">Also review us on Google</a></p>}
          </div>
        ) : st.can_review ? <ReviewForm number={b.booking_number} googleUrl={google} />
          : <p>You can review this rental once it is complete and the car is back with us.</p>}
      </section>
    </>
  );
}
