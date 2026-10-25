import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { getFleet } from '@/lib/site';
import { awaitingSignature, group, nextStep, carName } from '@/features/portal/status';
import { TripRow, StatusBadge } from '@/features/portal/Blocks';
import { currentUser, findBooking, myBookings, requireUser } from '@/server/portal/data';
import { redirect } from 'next/navigation';
import { pendingToken } from '@/server/capture';
import { rpc } from '@/lib/db/repo';
import { when } from '@/features/agreement/model';
import { LinkedNotice } from '@/features/portal/LinkedNotice';
import { More, PageHeader } from '@/features/portal/Chrome';
import { MyCodes, type MyCode } from '@/features/portal/MyCodes';

type Links = { verified: boolean; new: Array<{ kind: string; detail: string | null; booking_number: string | null }>; driver_trips: Array<{ booking_number: string; status: string; pickup_at: string; return_at: string; vehicle_name: string; accepted: boolean }> };

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Your trips', path: '/account', noindex: true, description: 'Your CarmaCars bookings, offers, agreements and payments.' });

// The portal's front door: the one next thing to do, then upcoming, current and past trips (section 7.1).
export default async function Account({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  // a browser that started a request without a sign-in (0090) sees what it made there; everything else needs the sign-in
  if (!(await currentUser()) && (await pendingToken())) redirect('/my-request');
  const user = await requireUser('/account');
  const [list, fleet, sp, links, codes] = await Promise.all([myBookings(user), getFleet(), searchParams,
    // earlier requests attached when the address was confirmed, and trips as an additional driver (migration 0040)
    rpc('server_my_account_links', { p_user: user.id }, { role: 'service_role' }).then((x) => x as unknown as Links).catch(() => null),
    // the codes issued to this renter, with their end dates (migration 0161)
    rpc('server_my_promo_codes', { p_user: user.id }, { role: 'service_role' }).then((x) => x as unknown as MyCode[]).catch(() => [] as MyCode[])]);
  const photo = (slug: string | null) => fleet.find((c) => c.slug === slug)?.cover ?? null;
  const { current, upcoming, past, nearest } = group(list);
  const full = nearest ? await findBooking(user, nearest.booking_number) : null;
  const step = full ? nextStep(full) : null;
  return (
    <>
      {sp.welcome && <p className="alert alert--ok" role="status"><span className="alert__title">Account created</span><span>You are signed in.</span></p>}
      {sp.password && <p className="alert alert--ok" role="status"><span className="alert__title">Password saved</span><span>You are signed in with your new password.</span></p>}
      {links && links.new.length > 0 && <LinkedNotice bookings={links.new.filter((l) => l.kind === 'booking').map((l) => l.booking_number ?? '')} drivers={links.new.filter((l) => l.kind === 'driver').length} />}
      <PageHeader title="Your trips" purpose={list.length ? 'Your next step first, then current, upcoming and past trips.' : undefined} />
      {!list.length ? (
        <div className="pt-empty"><p className="d4">No trips yet.</p><p className="muted">Pick a car and dates and send a request. Nothing is charged until you approve an offer.</p><Link prefetch={false} className="btn btn--primary" href="/cars">Find a car</Link></div>
      ) : (
        <div className="pt-home">
          {full && step && (
            <section className="pt-card pt-card--next" aria-labelledby="pt-next" data-testid="next-step">
              <div className="pt-card__head"><p className="pt-kicker">Next step · {full.booking_number}</p><StatusBadge s={full.status} awaiting={awaitingSignature(full)} /></div>
              <h2 className="d3" id="pt-next">{step.title}</h2>
              <p>{carName(full)}. {step.note}</p>
              {step.href && <p><Link prefetch={false} className={`btn ${step.urgent ? 'btn--primary' : 'btn--ghost'}`} href={step.href}>{step.cta}</Link></p>}
            </section>
          )}
          {[['Current', current], ['Upcoming', upcoming]].map(([title, items]) => (items as typeof list).length ? (
            <section key={title as string} className="stack" aria-labelledby={`pt-${title}`}>
              <h2 className="pt-section-title" id={`pt-${title}`}>{title as string}</h2>
              <ul className="pt-list">{(items as typeof list).map((b) => <TripRow key={b.id} b={b} photo={photo(b.slug)} />)}</ul>
            </section>
          ) : null)}
          {/* past trips fold away once there are other trips to show (portal cleanup, October 23, 2026) */}
          {past.length > 0 && (current.length + upcoming.length ? (
            <section className="stack pt-home__full" aria-labelledby="pt-Past"><More summary={<span id="pt-Past">Past trips ({past.length})</span>} testId="past-trips">
              <ul className="pt-list">{past.map((b) => <TripRow key={b.id} b={b} photo={photo(b.slug)} />)}</ul></More></section>
          ) : (
            <section className="stack" aria-labelledby="pt-Past">
              <h2 className="pt-section-title" id="pt-Past">Past</h2>
              <ul className="pt-list">{past.map((b) => <TripRow key={b.id} b={b} photo={photo(b.slug)} />)}</ul>
            </section>
          ))}
        </div>
      )}
      <MyCodes codes={codes} />
      {links && links.driver_trips.length > 0 && (
        <section className="stack" aria-labelledby="pt-driver-trips" data-testid="driver-trips">
          <h2 className="pt-section-title" id="pt-driver-trips">Trips where you are a driver</h2>
          <ul className="pt-list">{links.driver_trips.map((d) => <li key={d.booking_number} className="pt-card"><b>{d.vehicle_name}</b><p className="small">{when(d.pickup_at)} to {when(d.return_at)} · booking {d.booking_number}</p><p className="small muted">{d.accepted ? 'You accepted the agreement.' : 'Use the link in your email from CarmaCars to accept the agreement before pickup.'}</p></li>)}</ul>
        </section>
      )}
    </>
  );
}
