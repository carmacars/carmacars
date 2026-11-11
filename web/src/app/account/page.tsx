import Link from '@/components/Link';
import { incidentHref } from '@/features/incident-cards/digital';
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
import { MyCodes, type MyCode } from '@/features/portal/MyCodes';
import { PastTripCard, TripCard, TripHero, carTitle, ourAddress, tripPhoto } from '@/features/portal/trip';
import { placeText } from '@/features/portal/Blocks';
import { renterNow } from '@/features/portal/now';
import { NowPanel } from '@/features/portal-nav/NowPanel';
import { EmptyState, PortalIcon } from '@/components/portal-ui';
import { licenceState, renterMissing } from '@/features/portal/LicenceNotice';
import { quickLinks } from '@/features/portal/quick-links';
import { QuickLinks } from '@/features/portal/QuickLinks';
import { SignPayCard } from '@/features/portal/SignPayCard';
import { StillNeeded } from '@/features/portal/StillNeeded';
import { showNeeds, stillNeededOf } from '@/features/portal/still-needed';

type Links = { verified: boolean; new: Array<{ kind: string; detail: string | null; booking_number: string | null }>; driver_trips: Array<{ booking_number: string; status: string; pickup_at: string; return_at: string; vehicle_name: string; accepted: boolean }> };

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Your trips', path: '/account', noindex: true, description: 'Your CarmaCars bookings, offers, agreements and payments.' });

// The portal's front door (r27 portals): what to do now first (one sentence with the car, the time and the place, the
// one button, then Pay a balance, Extend, Message, Call), then the nearest trip with the car's photo and its clock, the
// other current and upcoming trips, then past trips with "Book again".
export default async function Account({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  // a browser that started a request without a sign-in (0090) sees what it made there; everything else needs the sign-in
  if (!(await currentUser()) && (await pendingToken())) redirect('/my-request');
  const user = await requireUser('/account');
  const [list, fleet, sp, links, photos, settings, codes] = await Promise.all([myBookings(user), getFleet(), searchParams,
    // earlier requests attached when the address was confirmed, and trips as an additional driver (migration 0040)
    rpc('server_my_account_links', { p_user: user.id }, { role: 'service_role' }).then((x) => x as unknown as Links).catch(() => null),
    myTripPhotos(user), getSettings().catch(() => null),
    // the codes issued to this renter, with their end dates (migration 0161)
    rpc('server_my_promo_codes', { p_user: user.id }, { role: 'service_role' }).then((x) => x as unknown as MyCode[]).catch(() => [] as MyCode[])]);
  const cover = (slug: string | null) => fleet.find((c) => c.slug === slug)?.cover ?? null;
  const photo = (b: (typeof list)[number]) => tripPhoto(photos, b, cover(b.slug));
  const { current, upcoming, past, nearest } = group(list);
  const full = nearest ? await findBooking(user, nearest.booking_number) : null;
  const step = full ? nextStep(full) : null;
  // what is still owing on the nearest trip after a change or a charge (tolls, damage, a late return: 0132), with Pay
  const balance = full && ['confirmed', 'on_rent', 'returned'].includes(full.status) && !full.link_due
    ? Number(((await rpc('renter_balance', { p_booking: full.id, p_by: user.id }, { role: 'service_role' }).catch(() => null)) as unknown as { balance_cents?: number } | null)?.balance_cents ?? 0) : 0;
  // r32: the licence, the proof of insurance and the card coverage checker, one tap each while the booking needs them
  const lic = full && ['requested', 'offered', 'pending_payment', 'confirmed', 'on_rent'].includes(full.status) ? await licenceState(full.id, user.id) : null;
  const quick = full ? quickLinks({ ...full, missing: full.readiness?.missing ?? null }, (renterMissing(lic)?.length ?? 0) > 0) : [];
  const addr = ourAddress(settings);
  const now = full && step ? renterNow(full, step, { pickupPlace: placeText(full.pickup_place ?? addr, full.pickup_method, true), returnPlace: placeText(full.return_place ?? addr, full.return_method, false), balanceCents: balance }) : null;
  const phone = settings?.phone_display ?? settings?.phone ?? null;
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
          {/* 1203: what each request and booking still needs from the renter, first, while anything is not done */}
          {[...current, ...upcoming].map((b) => { const n = stillNeededOf(b); return showNeeds(n) ? <StillNeeded key={`sn-${b.id}`} number={b.booking_number} needs={n} carLabel={`${carTitle(b)}, ${b.booking_number}`} testId={`still-needed-${b.booking_number}`} /> : null; })}
          {now && <NowPanel testId="next-step" titleId="now-renter" kicker={now.kicker} headline={now.headline} detail={now.detail} urgent={now.urgent} actions={now.actions}
            extra={<>{phone && ['confirmed', 'on_rent'].includes(full!.status) ? <a className="btn now__btn" href={`tel:${settings?.phone ?? phone}`} data-testid="now-call">Call us</a> : null}
              {/* 1150: the digital incident card of the trip in progress */}
              {full!.status === 'on_rent' ? <Link prefetch={false} className="btn now__btn" href={incidentHref(full!.booking_number)} data-testid="now-incident-card">Incident card</Link> : null}</>} />}
          {/* r33: every other trip still to sign or pay, one card each (the nearest one's is the panel above) */}
          {others.map((b) => <SignPayCard key={`sp-${b.id}`} b={b} testId={`sign-pay-${b.booking_number}`} label={`${carTitle(b)}, ${b.booking_number}`} />)}
          {full && <QuickLinks number={full.booking_number} links={quick} />}
          {full && <TripHero b={full} photo={photo(full)} titleAs="h2" settings={settings} href={bookingPath(full.booking_number)} />}
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
      <MyCodes codes={codes} />
      {links && links.driver_trips.length > 0 && (
        <section className="stack" aria-labelledby="pt-driver-trips" data-testid="driver-trips">
          <h2 className="pu-section-title" id="pt-driver-trips">Trips where you are a driver</h2>
          <ul className="pu-trips pu-trips--grid">{links.driver_trips.map((d) => <li key={d.booking_number} className="pu-panel"><b>{d.vehicle_name}</b><p className="small">{when(d.pickup_at)} to {when(d.return_at)} · booking {d.booking_number}</p><p className="small muted">{d.accepted ? 'You accepted the agreement.' : 'Use the link in your email from CarmaCars to accept the agreement before pickup.'}</p><p><Link prefetch={false} className="link small" href={incidentHref(d.booking_number)} data-testid={`driver-incident-${d.booking_number}`}>Incident card</Link></p></li>)}</ul>
        </section>
      )}
    </>
  );
}
