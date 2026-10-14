import { pageMeta } from '@/features/seo/meta';
import { bookingPath } from '@/features/portal/status';
import { Back } from '@/features/portal/Blocks';
import { ReviewForm } from '@/features/portal/ReviewForm';
import { getSettings } from '@/lib/site';
import { myBooking, reviewState } from '@/server/portal/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Review your rental', path: '/account/bookings', noindex: true, description: 'Rate your rental and tell the next renter how it went.' });

const STATUS: Record<string, string> = { pending: 'With our team, not published yet', published: 'Published on the car’s page', hidden: 'Not published' };

// The review request email's link (emails/src/links.mjs booking_review): a closed booking's renter rates it.
export default async function ReviewPage({ params }: { params: Promise<{ number: string }> }) {
  const { user, b } = await myBooking((await params).number, 'review');
  const [s, st] = await Promise.all([getSettings(), reviewState(user, b.id)]);
  const google = s.google_place_id ? `https://search.google.com/local/writereview?placeid=${encodeURIComponent(s.google_place_id)}` : null;
  return (
    <>
      <Back href={bookingPath(b.booking_number)}>Booking {b.booking_number}</Back>
      <h1 className="d2">Review your rental</h1>
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
