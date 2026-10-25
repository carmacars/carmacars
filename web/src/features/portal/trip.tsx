import Link from 'next/link';
import type { ReactNode } from 'react';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import type { Photo, SiteSettings } from '@/lib/types';
import { CarPhoto, LiveCountdown, PortalHero, PortalIcon, StatCard, StatGrid } from '@/components/portal-ui';
import { StatusBadge, placeText } from './Blocks';
import { awaitingSignature, bookingPath, carName, type NextStep } from './status';
import { mapLink, shortWhen, tripClock } from './trip-model';
import type { BookingSummary, MyBooking } from './types';

// The renter portal's trip pieces on portal-ui (October 24, 2026): the trip hero (the car's photo, its name, the status,
// the clock, pickup and return with a map link, the key numbers and the next step), the trip cards of the lists and the
// header of the step pages. Display only: every value comes from the existing loaders.

/** The car's photo for a booking: the photo of the car booked (0140), else the listing's cover, else none (placeholder). */
export const tripPhoto = (photos: Record<string, Photo> | null, b: Pick<BookingSummary, 'vehicle_id'>, cover?: Photo | null): Photo | null =>
  photos?.[b.vehicle_id] ?? cover ?? null;

/** The car without its code ("2023 Toyota Corolla"); the code goes on its own line. */
export const carTitle = (b: Pick<BookingSummary, 'vehicle_year' | 'vehicle_make' | 'vehicle_model'>) => `${b.vehicle_year} ${b.vehicle_make} ${b.vehicle_model}`;

/** Where "Our location" is, for the map link: the business address in the site settings. */
export const ourAddress = (s: SiteSettings | null) => {
  const b = s?.business;
  return [b?.street ?? s?.street_address, b?.city, b?.region].filter(Boolean).join(', ') || null;
};

function Place({ label, at, place, method, pickup, address, testId }: { label: string; at: string; place: string | null; method: string; pickup: boolean; address: string | null; testId: string }) {
  const map = mapLink(place ?? address);
  return <StatCard icon="pin" label={label} value={shortWhen(at)} sub={placeText(place, method, pickup)} href={map ?? undefined} testId={testId} />;
}

export function NextStepBox({ step, kicker = 'Next step', testId, ctaTestId, extra, calm }: { step: NextStep; kicker?: string; testId?: string; ctaTestId?: string; extra?: ReactNode; calm?: boolean }) {
  return (
    <section className={`pu-next${calm ? ' pu-next--calm' : ''}`} aria-labelledby={`${testId ?? 'pu-next'}-h`} data-testid={testId}>
      <p className="pu-next__kicker">{kicker}</p>
      <h2 className="pu-next__title" id={`${testId ?? 'pu-next'}-h`}>{step.title}</h2>
      <p className="pu-next__note">{step.note}</p>
      {step.href && step.cta && <Link prefetch={false} className={`btn ${calm ? 'btn--ghost' : step.urgent ? 'btn--primary' : 'btn--light'}`} href={step.href} data-testid={ctaTestId}>{step.cta}<PortalIcon name="arrow" size={18} /></Link>}
      {extra}
    </section>
  );
}

/** The trip hero: the photo with the name and the status on glass, the clock, then pickup, return and the key numbers. */
export function TripHero({ b, photo, titleAs = 'h1', settings, next, children, kmDriven, prepaidFuel, href }: {
  b: BookingSummary | MyBooking; photo: Photo | null; titleAs?: 'h1' | 'h2'; settings: SiteSettings | null; next?: ReactNode; children?: ReactNode;
  kmDriven?: number | null; prepaidFuel?: boolean; href?: string;
}) {
  const clock = tripClock(b);
  const addr = ourAddress(settings);
  const live = ['confirmed', 'on_rent'].includes(b.status);
  const title = href ? <Link prefetch={false} href={href} className="pu-hero__link">{carTitle(b)}</Link> : carTitle(b);
  return (
    <PortalHero photo={photo} alt={`${carTitle(b)}${b.vehicle_colour ? `, ${b.vehicle_colour}` : ''}`} titleAs={titleAs} eager
      chips={<><StatusBadge s={b.status} awaiting={awaitingSignature(b)} /><span className="pu-hero__kicker" data-testid="booking-number">{b.booking_number}</span></>}
      title={title}
      subtitle={<>{[b.vehicle_colour, b.car_code ? `car code ${b.car_code}` : null].filter(Boolean).join(' · ') || `${b.billable_days} days`}{clock && <><br /><span className="pu-countline"><PortalIcon name="clock" size={16} />
        <span>{b.status === 'on_rent' ? clock.label : <LiveCountdown until={clock.until} before={clock.before} after={clock.after} initial={clock.initial} testId="trip-countdown" />}</span>
        {b.status === 'on_rent' && <span className="pu-hero__kicker"><LiveCountdown until={clock.until} before={clock.before} after={clock.after} initial={clock.initial} testId="trip-countdown" /></span>}</span></>}</>}
      aside={next}>
      <StatGrid label="Trip details">
        <Place label="Pickup" at={b.pickup_at} place={b.pickup_place} method={b.pickup_method} pickup address={addr} testId="trip-pickup" />
        <Place label="Return" at={b.return_at} place={b.return_place} method={b.return_method} pickup={false} address={addr} testId="trip-return" />
        <StatCard icon="gauge" label="Kilometres" value={b.km_allowance_total ? `${b.km_allowance_total.toLocaleString('en-CA')} km` : 'Unlimited'}
          sub={kmDriven !== null && kmDriven !== undefined ? `${kmDriven.toLocaleString('en-CA')} km driven` : b.km_allowance_total && b.overage_cents_per_km ? `included, then ${money(b.overage_cents_per_km, { cents: true })} per km` : 'included'} testId="trip-km" />
        <StatCard icon="fuel" label="Fuel" value={prepaidFuel ? 'Prepaid' : 'Same as pickup'} sub={prepaidFuel ? 'return it at any level' : 'return it with the same fuel or charge'} testId="trip-fuel" />
        {live && b.deposit_cents > 0 && <StatCard icon="shield" label="Deposit" value={money(b.deposit_cents)} sub={b.status === 'on_rent' ? 'held, released after the return' : 'taken at pickup'} />}
        <StatCard icon="calendar" label="Length" value={`${b.billable_days} ${b.billable_days === 1 ? 'day' : 'days'}`} sub={`${when(b.pickup_at, false)} to ${when(b.return_at, false)}`} />
      </StatGrid>
      {children}
    </PortalHero>
  );
}

/** A trip in a list: thumbnail, status, the car and the dates. */
export function TripCard({ b, photo }: { b: BookingSummary; photo: Photo | null }) {
  const clock = tripClock(b);
  return (
    <li>
      <Link prefetch={false} className="pu-trip" href={bookingPath(b.booking_number)} data-testid="trip-row">
        <span className="pu-trip__img"><CarPhoto photo={photo} alt="" sizes="104px" /></span>
        <span className="pu-trip__body">
          <span className="pu-trip__top"><StatusBadge s={b.status} awaiting={awaitingSignature(b)} /><span className="xs muted">{b.booking_number}</span></span>
          <span className="pu-trip__name">{carTitle(b)}</span>
          <span className="pu-trip__meta">{clock ? clock.label : `${when(b.pickup_at, false)} to ${when(b.return_at, false)}`}</span>
        </span>
      </Link>
    </li>
  );
}

/** A past trip: thumbnail, dates, total and "Book again". */
export function PastTripCard({ b, photo }: { b: BookingSummary; photo: Photo | null }) {
  const done = ['returned', 'closed'].includes(b.status);
  return (
    <li className="pu-trip pu-trip--past" data-testid="past-trip">
      <span className="pu-trip__img"><CarPhoto photo={photo} alt="" sizes="72px" /></span>
      <span className="pu-trip__body">
        <span className="pu-trip__top"><StatusBadge s={b.status} /><Link prefetch={false} className="xs link" href={bookingPath(b.booking_number)} data-testid="trip-row">{b.booking_number}<span className="vh">, {carTitle(b)}</span></Link></span>
        <span className="pu-trip__name">{carTitle(b)}</span>
        <span className="pu-trip__meta">{when(b.pickup_at, false)} to {when(b.return_at, false)}</span>
        <span className="pu-trip__foot">
          <span className="pu-trip__total">{done && b.renter_due_at_booking_cents > 0 ? money(b.renter_due_at_booking_cents, { cents: true }) : ''}</span>
          <Link prefetch={false} className="btn btn--ghost btn--sm" href={b.slug ? `/cars/${b.slug}` : '/cars'} data-testid="book-again"><PortalIcon name="repeat" size={16} />Book again<span className="vh"> the {carTitle(b)}</span></Link>
        </span>
      </span>
    </li>
  );
}

/** The header of a step page (sign, pay, verify, the photo report): the car's thumbnail, the title, the trip, the steps. */
export function StepHeader({ b, photo, kicker, title, step, steps = 3 }: { b: BookingSummary | MyBooking; photo: Photo | null; kicker?: ReactNode; title: ReactNode; step?: number; steps?: number }) {
  return (
    <header className="pu-steph">
      <span className="pu-steph__img"><CarPhoto photo={photo} alt="" sizes="96px" /></span>
      <span className="pu-steph__text">
        {kicker && <span className="pt-kicker">{kicker}</span>}
        <h1 className="pu-steph__title">{title}</h1>
        <span className="pu-steph__meta">{carName(b)} · {when(b.pickup_at)} to {when(b.return_at)}</span>
        {step && <span className="pu-dots" aria-hidden="true">{Array.from({ length: steps }, (_, i) => <span key={i} className={i + 1 < step ? 'is-done' : i + 1 === step ? 'is-now' : ''} />)}</span>}
      </span>
    </header>
  );
}
