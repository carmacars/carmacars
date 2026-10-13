import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { getFleet } from '@/lib/site';
import { group, nextStep, carName } from '@/features/portal/status';
import { TripRow, StatusBadge } from '@/features/portal/Blocks';
import { findBooking, myBookings, requireUser } from '@/server/portal/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Your trips', path: '/account', noindex: true, description: 'Your CarmaCars bookings, offers, agreements and payments.' });

// The portal's front door: the one next thing to do, then upcoming, current and past trips (section 7.1).
export default async function Account({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const user = await requireUser('/account');
  const [list, fleet, sp] = await Promise.all([myBookings(user), getFleet(), searchParams]);
  const photo = (slug: string | null) => fleet.find((c) => c.slug === slug)?.cover ?? null;
  const { current, upcoming, past, nearest } = group(list);
  const full = nearest ? await findBooking(user, nearest.booking_number) : null;
  const step = full ? nextStep(full) : null;
  return (
    <>
      {sp.welcome && <p className="alert alert--ok" role="status"><span className="alert__title">Account created</span><span>You are signed in.</span></p>}
      {sp.password && <p className="alert alert--ok" role="status"><span className="alert__title">Password saved</span><span>You are signed in with your new password.</span></p>}
      <h1 className="d2">Your trips</h1>
      {!list.length ? (
        <div className="pt-empty"><p className="d4">No trips yet.</p><p className="muted">Pick a car and dates and send a request. Nothing is charged until you approve an offer.</p><Link prefetch={false} className="btn btn--primary" href="/cars">Find a car</Link></div>
      ) : (
        <div className="pt-home">
          {full && step && (
            <section className="pt-card pt-card--next" aria-labelledby="pt-next" data-testid="next-step">
              <div className="pt-card__head"><p className="pt-kicker">Next step · {full.booking_number}</p><StatusBadge s={full.status} /></div>
              <h2 className="d3" id="pt-next">{step.title}</h2>
              <p>{carName(full)}. {step.note}</p>
              {step.href && <p><Link prefetch={false} className={`btn ${step.urgent ? 'btn--primary' : 'btn--ghost'}`} href={step.href}>{step.cta}</Link></p>}
            </section>
          )}
          {[['Current', current], ['Upcoming', upcoming], ['Past', past]].map(([title, items]) => (items as typeof list).length ? (
            <section key={title as string} className="stack" aria-labelledby={`pt-${title}`}>
              <h2 className="pt-section-title" id={`pt-${title}`}>{title as string}</h2>
              <ul className="pt-list">{(items as typeof list).map((b) => <TripRow key={b.id} b={b} photo={photo(b.slug)} />)}</ul>
            </section>
          ) : null)}
        </div>
      )}
    </>
  );
}
