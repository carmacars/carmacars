import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { getFleet, getSettings } from '@/lib/site';
import { group, nextStep, bookingPath } from '@/features/portal/status';
import { currentUser, findBooking, myBookings, myTripPhotos, requireUser } from '@/server/portal/data';
import { redirect } from 'next/navigation';
import { pendingToken } from '@/server/capture';
import { rpc } from '@/lib/db/repo';
import { when } from '@/features/agreement/model';
import { LinkedNotice } from '@/features/portal/LinkedNotice';
import { More, PageHeader } from '@/features/portal/Chrome';
import { NextStepBox, PastTripCard, TripCard, TripHero, tripPhoto } from '@/features/portal/trip';
import { EmptyState, PortalIcon } from '@/components/portal-ui';

type Links = { verified: boolean; new: Array<{ kind: string; detail: string | null; booking_number: string | null }>; driver_trips: Array<{ booking_number: string; status: string; pickup_at: string; return_at: string; vehicle_name: string; accepted: boolean }> };

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Your trips', path: '/account', noindex: true, description: 'Your CarmaCars bookings, offers, agreements and payments.' });

// The portal's front door (redesign of October 24, 2026): the nearest trip as a hero with the car's photo, its clock and
// the one next thing to do, then the other current and upcoming trips, then past trips with "Book again".
export default async function Account({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  // a browser that started a request without a sign-in (0090) sees what it made there; everything else needs the sign-in
  if (!(await currentUser()) && (await pendingToken())) redirect('/my-request');
  const user = await requireUser('/account');
  const [list, fleet, sp, links, photos, settings] = await Promise.all([myBookings(user), getFleet(), searchParams,
    // earlier requests attached when the address was confirmed, and trips as an additional driver (migration 0040)
    rpc('server_my_account_links', { p_user: user.id }, { role: 'service_role' }).then((x) => x as unknown as Links).catch(() => null),
    myTripPhotos(user), getSettings().catch(() => null)]);
  const cover = (slug: string | null) => fleet.find((c) => c.slug === slug)?.cover ?? null;
  const photo = (b: (typeof list)[number]) => tripPhoto(photos, b, cover(b.slug));
  const { current, upcoming, past, nearest } = group(list);
  const full = nearest ? await findBooking(user, nearest.booking_number) : null;
  const step = full ? nextStep(full) : null;
  const others = [...current, ...upcoming].filter((b) => b.id !== nearest?.id);
  return (
    <>
      {sp.welcome && <p className="alert alert--ok" role="status"><span className="alert__title">Account created</span><span>You are signed in.</span></p>}
      {sp.password && <p className="alert alert--ok" role="status"><span className="alert__title">Password saved</span><span>You are signed in with your new password.</span></p>}
      {links && links.new.length > 0 && <LinkedNotice bookings={links.new.filter((l) => l.kind === 'booking').map((l) => l.booking_number ?? '')} drivers={links.new.filter((l) => l.kind === 'driver').length} />}
      <PageHeader title="Your trips" purpose={list.length ? 'Your next trip first, with what to do next. Then your other trips.' : undefined}
        action={list.length ? <Link prefetch={false} className="btn btn--ghost btn--sm" href="/cars"><PortalIcon name="car" size={18} />Book a car</Link> : undefined} />
      {!list.length ? (
        <EmptyState title="No trips yet" testId="trips-empty" action={<Link prefetch={false} className="btn btn--primary" href="/cars">Find a car<PortalIcon name="arrow" size={18} /></Link>}>
          <p>Pick a car and dates and send a request. Nothing is charged until you approve an offer.</p>
        </EmptyState>
      ) : (
        <div className="pu-home">
          {full && step && (
            <TripHero b={full} photo={photo(full)} titleAs="h2" settings={settings} href={bookingPath(full.booking_number)}
              next={<NextStepBox step={step} kicker={`Next step · ${full.booking_number}`} testId="next-step" calm={!step.urgent} />} />
          )}
          {others.length > 0 && (
            <section className="stack" aria-labelledby="pt-more-trips">
              <h2 className="pu-section-title" id="pt-more-trips">{current.length + upcoming.length > 1 && current.some((b) => b.id !== nearest?.id) ? 'Current and upcoming' : 'Upcoming'}</h2>
              <ul className="pu-trips pu-trips--grid">{others.map((b) => <TripCard key={b.id} b={b} photo={photo(b)} />)}</ul>
            </section>
          )}
          {/* past trips fold away once there are other trips to show (portal cleanup, October 23, 2026) */}
          {past.length > 0 && (current.length + upcoming.length ? (
            <section className="stack" aria-labelledby="pt-Past"><More summary={<span id="pt-Past">Past trips ({past.length})</span>} testId="past-trips">
              <ul className="pu-trips pu-trips--grid">{past.map((b) => <PastTripCard key={b.id} b={b} photo={photo(b)} />)}</ul></More></section>
          ) : (
            <section className="stack" aria-labelledby="pt-Past">
              <h2 className="pu-section-title" id="pt-Past">Past trips</h2>
              <ul className="pu-trips pu-trips--grid">{past.map((b) => <PastTripCard key={b.id} b={b} photo={photo(b)} />)}</ul>
            </section>
          ))}
        </div>
      )}
      {links && links.driver_trips.length > 0 && (
        <section className="stack" aria-labelledby="pt-driver-trips" data-testid="driver-trips">
          <h2 className="pu-section-title" id="pt-driver-trips">Trips where you are a driver</h2>
          <ul className="pu-trips pu-trips--grid">{links.driver_trips.map((d) => <li key={d.booking_number} className="pu-panel"><b>{d.vehicle_name}</b><p className="small">{when(d.pickup_at)} to {when(d.return_at)} · booking {d.booking_number}</p><p className="small muted">{d.accepted ? 'You accepted the agreement.' : 'Use the link in your email from CarmaCars to accept the agreement before pickup.'}</p></li>)}</ul>
        </section>
      )}
    </>
  );
}
