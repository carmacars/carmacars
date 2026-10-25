import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { getSettings } from '@/lib/site';
import { ReviewHelper } from '@/features/reviews/ReviewHelper';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Review your trip', path: '/review', noindex: true, description: 'Tell other renters how your trip went.' });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
interface Helper { ok: boolean; first_name?: string; booking_number?: string; vehicle?: string | null; days?: number | null; delivered?: boolean; staff?: string[];
  google_url?: string | null; reviewed?: boolean; returned?: boolean }

// The review request's link (migration 0138): the renter's review page without sign-in, by the request's token. It shows
// only their first name and their booking's car, length and handover. Opening it changes nothing (mail scanners open
// links); "I already left a review" is a button.
export default async function ReviewByLink({ params, searchParams }: { params: Promise<{ token: string }>; searchParams: Promise<{ done?: string }> }) {
  const [{ token }, sp, s] = await Promise.all([params, searchParams, getSettings()]);
  const h: Helper = UUID.test(token) ? ((await rpc('server_review_helper', { p_token: token }, { role: 'service_role', skipViewAs: true })) as unknown as Helper) : { ok: false };
  const contact = s.public_email ? `mailto:${s.public_email}?subject=${encodeURIComponent(`Booking ${h.booking_number ?? ''}`)}` : '/contact';
  return (
    <section className="section">
      <div className="wrap stack" style={{ maxWidth: '42rem' }}>
        {!h.ok ? (<>
          <h1 className="d2">This link does not work</h1>
          <p className="lead">It may be incomplete. Use the button in the email or text again{s.public_email ? <>, or write to <a className="link" href={`mailto:${s.public_email}`}>{s.public_email}</a></> : null}.</p>
        </>) : (<>
          <h1 className="d2">How was your trip, {h.first_name}?</h1>
          <p className="lead">The {h.vehicle ?? 'car'}{h.days ? `, ${h.days === 1 ? '1 day' : `${h.days} days`}` : ''}. Three quick questions, then your review is ready to post on Google.</p>
          <ReviewHelper token={token} firstName={h.first_name ?? ''} bookingNumber={h.booking_number ?? ''} reviewed={!!h.reviewed} confirmDone={sp.done === '1'}
            facts={{ vehicle: h.vehicle ?? null, days: h.days ?? null, delivered: !!h.delivered, staff: h.staff ?? [] }} googleUrl={h.google_url ?? null}
            directHref={contact} directLabel="Tell us directly" phone={s.phone_display ?? null} />
        </>)}
        <p><Link className="link" href="/">Back to {s.brand_name}</Link></p>
      </div>
    </section>
  );
}
