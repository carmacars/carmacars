import { More } from '@/features/portal/Chrome';
import { OwnBookingForm } from '@/features/owner/OwnerForms';
import { ownerBookings } from '@/server/owner/data';
import type { OwnerCtx } from '@/features/owner/ctx';
import type { OwnerBooking } from '@/features/owner/types';
import { bookingTitle } from '@/features/owner/Blocks';
import { bucketParam, firstBucket, sortBookings, timeline, windowFor } from '@/features/owner/bookings';
import { BookingList, OwnerTimeline } from '@/features/owner/BookingCards';
import { instantOfTorontoInput } from '@/lib/dates';
import { BookingBuckets } from '@/features/owner/BookingBuckets';
import type { HistoryQuery } from '@/features/owner/history';
import { RentalHistory } from './RentalHistory';

const TZ = 'America/Toronto';
const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
const WEEK = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

// A month of the owner's cars: each day shows the bookings on it. Renter names only where the
// database gives them (Self-Managed rentals and the owner's own bookings).
function Month({ year, month, bookings }: { year: number; month: number; bookings: OwnerBooking[] }) {
  const first = new Date(Date.UTC(year, month, 1));
  const days = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
  const lead = first.getUTCDay();
  const cells: Array<{ d: number; iso: string } | null> = [...Array(lead).fill(null), ...Array.from({ length: days }, (_, i) => ({ d: i + 1, iso: `${year}-${String(month + 1).padStart(2, '0')}-${String(i + 1).padStart(2, '0')}` }))];
  const on = (iso: string) => bookings.filter((b) => ymd(new Date(b.pickup_at)) <= iso && ymd(new Date(b.return_at)) >= iso);
  const title = new Intl.DateTimeFormat('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(first);
  return (
    <section className="pt-card" aria-label={title}>
      <h2 className="d4">{title}</h2>
      <p className="vh">{(() => { const n = bookings.filter((b) => ymd(new Date(b.return_at)) >= `${year}-${String(month + 1).padStart(2, '0')}-01` && ymd(new Date(b.pickup_at)) <= `${year}-${String(month + 1).padStart(2, '0')}-${days}`).length; return n ? `${n} bookings this month, listed below.` : 'No bookings this month.'; })()}</p>
      <div className="ow-cal" aria-hidden="true">
        <div className="ow-cal__head">{WEEK.map((w) => <span key={w}>{w}</span>)}</div>
        <div className="ow-cal__grid">
          {cells.map((c, i) => c ? (
            <div key={i} className={`ow-cal__day${on(c.iso).length ? ' is-booked' : ''}`}>
              <span className="ow-cal__n">{c.d}</span>
              {on(c.iso).slice(0, 2).map((b) => <span key={b.booking_id} className={`ow-cal__b${b.booking_type === 'owner' ? ' is-owner' : ''}`} title={bookingTitle(b)}>{b.booking_number ?? 'Unavailable'}</span>)}
            </div>
          ) : <div key={i} className="ow-cal__day is-blank" />)}
        </div>
      </div>
    </section>
  );
}

// Cars > Bookings (redesigned in r48 ops; the owner, Nov 20: "confusing and badly organised"). In order: the cars over
// the next six weeks (a timeline), a filter by car, then every booking in one of three lists (on a trip, upcoming, past),
// each a card with its dates, status and money (only what the database lets an owner see: 0156), then the rental history
// (r44: every rental, paged), the month calendar and booking your own car.
export async function BookingsTab({ user, home, vehicle, history, when: whenParam }: OwnerCtx & { vehicle?: string; history: HistoryQuery; when?: string }) {
  const list = await ownerBookings(user);
  const now = new Date();
  const [y, m] = ymd(now).split('-').map(Number) as [number, number];
  const bookable = home.vehicles.filter((v) => ['available', 'ready_to_list', 'cleaning', 'exit_notice'].includes(v.status)).map((v) => ({ id: v.vehicle_id, name: v.name }));
  // r48 ops: the three lists, one car or all; the timeline of the weeks around today
  const cars = home.vehicles.filter((v) => v.status !== 'declined').map((v) => ({ vehicle_id: v.vehicle_id, name: v.name }));
  const car = history.car && cars.some((c) => c.vehicle_id === history.car) ? history.car : null;
  const t = now.getTime();
  const sorted = sortBookings(list, t, car);
  const chosen = bucketParam(whenParam);
  const todayStart = Date.parse(instantOfTorontoInput(`${ymd(now)}T00:00`) ?? '') || t;
  const shownCars = car ? cars.filter((c) => c.vehicle_id === car) : cars;
  const ahead = windowFor('upcoming', todayStart), back = windowFor('past', todayStart);
  return (
    <>
      {bookable.length > 0 && <p className="ph__phone-only"><a className="btn btn--ghost btn--sm" href="#book-own">Book my own car</a></p>}
      <div className="pt-split">
        <div className="stack-lg">
          <OwnerTimeline tl={timeline(list, shownCars, ahead.from, ahead.days, t)} title="Your cars, the next six weeks" />
          <BookingBuckets cars={cars} car={car} initial={chosen ?? firstBucket(sorted)} counts={{ trip: sorted.trip.length, upcoming: sorted.upcoming.length, past: sorted.past.length }} panels={{
            trip: <BookingList bucket="trip" list={sorted.trip} />,
            upcoming: <BookingList bucket="upcoming" list={sorted.upcoming} />,
            past: <><OwnerTimeline tl={timeline(list, shownCars, back.from, back.days, t)} title="The last six weeks" testId="owner-timeline-past" /><BookingList bucket="past" list={sorted.past} max={12} /></> }} />
          <p className="small muted ob-explain">On a managed rental we show dates and status only; renter details stay with CarmaCars. A booking marked Booked shows its amount once CarmaCars approves the statement that covers it. Dates marked Unavailable are not part of your revenue. Amounts are rental charges before tax: your share and every deduction are on your statement.</p>
          <RentalHistory user={user} q={history} />
          <More summary="Calendar: this month and next" testId="owner-calendar">
            <Month year={y} month={m - 1} bookings={list} />
            <Month year={m === 12 ? y + 1 : y} month={m % 12} bookings={list} />
          </More>
        </div>
        <aside className="pt-split__aside">
          <section className="pt-card" aria-labelledby="book-own" id="book-own"><h2 className="d4">Book my own car</h2><OwnBookingForm vehicles={bookable} initial={vehicle} /></section>
        </aside>
      </div>
    </>
  );
}
