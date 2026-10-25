import type { CSSProperties } from 'react';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';

// The top of a booking (admin portal design, October 25, 2026): where the booking is on its way from request to closed,
// drawn as a line of seven steps, and the four facts staff look for first (the dates, the days, the total, who pays).
// The steps are a picture of the status badge beside the booking number, which says the same in words, so the line is
// hidden from screen readers and its step names are drawn by the stylesheet (admin-ui.css). Nothing is worked out here.

export const STEPS: Array<[string, string]> = [
  ['requested', 'Request'], ['offered', 'Offer'], ['pending_payment', 'Sign and pay'], ['confirmed', 'Confirmed'], ['on_rent', 'On trip'], ['returned', 'Returned'], ['closed', 'Closed']
];

/** The step the status is at, or -1 for a booking off the way (cancelled, expired, declined, no-show). */
export const stepOf = (status: string) => STEPS.findIndex(([s]) => s === status);

const BILL: Record<string, string> = { renter: 'The renter', insurer: 'The insurer', split: 'Renter and insurer' };

export function BookingSummary({ status, pickupAt, returnAt, days, totalCents, billTo }: { status: string; pickupAt: string; returnAt: string; days: number; totalCents: number; billTo: string }) {
  const at = stepOf(status);
  return (
    <section className="ad-bsum" aria-label="This booking at a glance" data-testid="booking-summary">
      {at >= 0 && (
        <ol className="ad-steps-line" aria-hidden="true" style={{ '--at': at } as CSSProperties}>
          {STEPS.map(([s, l], i) => <li key={s} data-label={l} className={i < at ? 'is-done' : i === at ? 'is-now' : undefined} />)}
        </ol>
      )}
      <dl className="ad-bsum__facts">
        <div className="ad-bsum__when"><dt>Pickup to return</dt><dd>{when(pickupAt)} <span className="ad-bsum__arrow" aria-hidden="true">&rarr;</span><span className="vh"> to </span> {when(returnAt)}</dd></div>
        <div><dt>Days</dt><dd>{days}</dd></div>
        <div><dt>Total at booking</dt><dd>{money(Number(totalCents), { cents: true })}</dd></div>
        <div><dt>Bill to</dt><dd>{BILL[billTo] ?? billTo.replace(/_/g, ' ')}</dd></div>
      </dl>
    </section>
  );
}
