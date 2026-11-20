import { money, pct } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { amountText, viewOf } from './insights';
import { bookingMoney, bucketTotals, nights, statusOf, type Bucket, type Tl } from './bookings';
import type { OwnerBooking } from './types';

// The owner's Bookings page, redesigned (r48 ops, the owner, Nov 20: "confusing and badly organised"): one card a booking
// with its dates, car, status and money said plainly, and a timeline of the cars. Server-rendered; what an owner may see
// of a booking is the database's decision (0156), read through viewOf and bookingMoney.
const EXPENSE: Record<string, string> = { cleaning: 'Cleaning', repair: 'Repair', fuel: 'Fuel', platform_fee: 'Platform fee', other: 'Other' };
const cents = (c: number) => money(c, { cents: true });
const dm = (iso: string) => { const d = new Date(iso); return { d: new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', day: 'numeric' }).format(d), m: new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short' }).format(d).replace('.', '') }; };

export function OwnerBookingCard({ b, withCar = true }: { b: OwnerBooking; withCar?: boolean }) {
  const v = viewOf(b);
  const m = bookingMoney(b);
  const st = statusOf(b);
  const a = dm(b.pickup_at), z = dm(b.return_at);
  const n = nights(b);
  return (
    <li className="ob-card" data-testid="owner-booking-row" data-view={v} data-status={b.status}>
      <div className="ob-card__dates" aria-hidden="true">
        <span className="ob-card__day"><b>{a.d}</b><span>{a.m}</span></span>
        <span className="ob-card__arrow" />
        <span className="ob-card__day"><b>{z.d}</b><span>{z.m}</span></span>
      </div>
      <div className="ob-card__body">
        <p className="ob-card__title">{withCar && <b>{b.vehicle_name}</b>}{v !== 'unavailable' && b.booking_number && <span className="ob-card__num">{b.booking_number}</span>}
          <span className={`pu-pill pu-pill--${st.tone}`} data-testid="owner-booking-status">{st.label}</span></p>
        <p className="ob-card__when"><span>{when(b.pickup_at)}</span> to <span>{when(b.return_at)}</span><span className="ob-card__n"> · {n} {n === 1 ? 'day' : 'days'}</span></p>
        {v !== 'unavailable' && b.renter_name && <p className="ob-card__line">Renter: {b.renter_name}{b.renter_mobile ? `, ${b.renter_mobile}` : ''}</p>}
        {(b.owner_expenses ?? []).map((e, i) => <p key={i} className="ob-card__line" data-testid="owner-booking-expense">Booking expense: {EXPENSE[e.category] ?? e.category} {cents(-e.amount_cents)}, {e.reason}{e.receipt ? ' (receipt on file)' : ''}</p>)}
        {b.booking_share_bps !== null && b.booking_share_bps !== undefined && <p className="ob-card__line" data-testid="owner-booking-share">Revenue Share for this booking: {pct(b.booking_share_bps)}</p>}
      </div>
      <div className={`ob-card__money ob-card__money--${m.kind}`} data-testid="owner-booking-money">
        <span className="ob-card__mk">{m.kind === 'amount' ? m.label : 'Money'}</span>
        <span className="ow-amount">{amountText(b, cents)}</span>
        <span className="ob-card__mnote">{m.note}</span>
      </div>
    </li>
  );
}

const EMPTY: Record<Bucket, [string, string]> = {
  trip: ['No car is out right now', 'When a renter picks up one of your cars, the trip shows here until the car is back.'],
  upcoming: ['Nothing booked ahead yet', 'Confirmed bookings show here as soon as a renter books one of your cars.'],
  past: ['No past bookings yet', 'Finished and cancelled bookings are kept here.']
};
/** One list (on a trip, upcoming or past): its totals in a line, then its cards; `more` says how many older ones are in the history. */
export function BookingList({ bucket, list, max, withCar = true }: { bucket: Bucket; list: OwnerBooking[]; max?: number; withCar?: boolean }) {
  if (!list.length) return <div className="pt-empty ob-empty" data-testid={`owner-bookings-empty-${bucket}`}><p className="d4">{EMPTY[bucket][0]}</p><p className="muted">{EMPTY[bucket][1]}</p></div>;
  const t = bucketTotals(list);
  const shown = max ? list.slice(0, max) : list;
  return (
    <>
      <dl className="ob-totals" data-testid={`owner-bookings-totals-${bucket}`}>
        <div><dt>Bookings</dt><dd>{t.bookings}</dd></div>
        <div><dt>Rental days</dt><dd>{t.days}</dd></div>
        <div><dt>Rental charges shown</dt><dd>{t.shown ? cents(t.cents) : 'None yet'}</dd></div>
        {t.onStatement > 0 && <div><dt>Amounts still to come</dt><dd>{t.onStatement} with your statement</dd></div>}
      </dl>
      <ul className="ob-list">{shown.map((b) => <OwnerBookingCard key={b.booking_id} b={b} withCar={withCar} />)}</ul>
      {max && list.length > max ? <p className="small muted" data-testid="owner-bookings-older">Showing the {max} most recent of {list.length}. Every rental is in the <a className="link" href="#rental-history">rental history</a> below.</p> : null}
    </>
  );
}

/** The cars over six weeks: a row a car, a bar a booking, today as a line. The bars are for the eye; each has its words. */
export function OwnerTimeline({ tl, title, testId = 'owner-timeline' }: { tl: Tl; title: string; testId?: string }) {
  if (!tl.rows.length) return null;
  return (
    <section className="ob-tl" aria-label={title} data-testid={testId}>
      <header className="ob-tl__head"><h2 className="ob-tl__h">{title}</h2>
        <p className="ob-tl__key" aria-hidden="true"><span><i className="ob-bar ob-bar--trip" /> on a trip</span><span><i className="ob-bar ob-bar--upcoming" /> booked</span><span><i className="ob-bar ob-bar--past" /> finished</span><span><i className="ob-bar ob-bar--own" /> your own use</span><span><i className="ob-bar ob-bar--unavailable" /> unavailable</span></p></header>
      <div className="ob-tl__grid">
        <div className="ob-tl__weeks" aria-hidden="true">{tl.weeks.map((w) => <span key={w.left} style={{ left: `${w.left}%` }}>{w.label}</span>)}</div>
        {tl.rows.map((r) => (
          <div key={r.vehicle_id} className="ob-tl__row" data-testid="owner-timeline-row">
            <span className="ob-tl__car">{r.name}</span>
            <div className="ob-tl__lane">
              {tl.today !== null && <span className="ob-tl__today" style={{ left: `${tl.today}%` }} aria-hidden="true" />}
              {r.bars.map((x) => <span key={x.id} className={`ob-bar ob-bar--${x.kind}${x.clippedStart ? ' is-cut-start' : ''}${x.clippedEnd ? ' is-cut-end' : ''}`} style={{ left: `${x.left}%`, width: `${x.width}%` }} title={x.title} data-testid="owner-timeline-bar"><span className="vh">{x.title}</span></span>)}
              {!r.bars.length && <span className="ob-tl__free">Free these weeks</span>}
            </div>
          </div>))}
      </div>
    </section>
  );
}
