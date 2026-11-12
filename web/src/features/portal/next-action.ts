import type { NextStep, Progress } from './status.ts';
import type { BookingSummary } from './types.ts';
import { renterNow, type RenterNow } from './now.ts';
import { needHref, orderNeeds, type StillNeeded } from './still-needed.ts';
import { span } from '../../components/portal-ui/time.ts';

// r40 renter portal: "Do this next" (the owner: "make things that need to be done very obvious"). One card at the top of
// /account and of each booking, from the rules that already exist: the booking's next step (status.ts nextStep, which
// reads the sign-and-pay rule 0750), what the database says is still needed (1203), the balance owing (0132) and the
// trip's times. No new rules: this only picks which of them comes first and adds the deadline and the step tracker.
// Pure (next-action.test.ts).

/** The card's name, as the renter guide calls it. */
export const DO_NEXT = 'Do this next';

export type ActionKind = 'answer' | 'offer' | 'sign-pay' | 'verify' | 'pay-balance' | 'pickup' | 'return' | 'review' | 'wait' | 'done';
/** initial: the sentence ("Pickup in 2 days"); span: the time alone ("2 days"), for the card's figure. */
export interface Deadline { label: string; at: string; initial: string; span: string; before: string; after: string; late: boolean; soon: boolean }
export interface NextAction extends RenterNow { kind: ActionKind; deadline: Deadline | null }

const HOUR = 3600e3;
const deadline = (label: string, at: string | null | undefined, now: number, after = `${label} was {t} ago`): Deadline | null => {
  if (!at) return null;
  const left = new Date(at).getTime() - now;
  if (Number.isNaN(left)) return null;
  return { label, at, span: span(left), before: `${label} in`, after, initial: left > 0 ? `${label} in ${span(left)}` : after.replace('{t}', span(left)), late: left <= 0, soon: left > 0 && left < 24 * HOUR };
};

const kindOf = (b: BookingSummary, step: NextStep): ActionKind => {
  const h = step.href ?? '';
  if (h.endsWith('#questions')) return 'answer';
  if (h.endsWith('/offer')) return 'offer';
  if (h.endsWith('/checkout')) return 'sign-pay';
  if (h.endsWith('/verify')) return 'verify';
  if (b.status === 'on_rent') return 'return';
  if (b.status === 'confirmed') return 'pickup';
  if (b.status === 'requested' || b.status === 'returned') return 'wait';
  return 'done';
};

/**
 * The one thing to do next on a booking. Order: the booking's urgent step (answer, approve the offer, sign and pay,
 * upload the licence), then a balance owing, then the first item the database still needs from the renter, then the
 * trip itself (pick up, return), then a review once the rental is complete.
 */
export function nextAction(b: BookingSummary, step: NextStep, opts: {
  pickupPlace: string | null; returnPlace: string | null; balanceCents?: number; needs?: StillNeeded | null; reviewDue?: boolean; now?: number;
}): NextAction {
  const now = opts.now ?? Date.now();
  const base = renterNow(b, step, opts);
  const balance = Math.max(0, opts.balanceCents ?? 0);
  const path = `/account/bookings/${encodeURIComponent(b.booking_number)}`;
  let kind: ActionKind = step.urgent ? kindOf(b, step) : balance > 0 ? 'pay-balance' : kindOf(b, step);
  let out: RenterNow = base;

  // the database's checklist: the first thing still to send, when nothing more urgent comes first
  const need = !step.urgent && balance === 0 && opts.needs
    ? orderNeeds(opts.needs.items).find((i) => (i.status === 'missing' || i.status === 'rejected') && i.action) : undefined;
  if (need?.action) {
    kind = 'verify';
    const when = b.status === 'on_rent' ? '' : ' Needed before pickup.';
    out = {
      ...base,
      kicker: `${DO_NEXT} · ${b.booking_number}`,
      headline: need.status === 'rejected' ? `Send your ${need.label.toLowerCase()} again` : need.label,
      detail: need.reason ? `${need.reason}.${when}` : `${need.action.label} takes a minute.${when}`,
      urgent: true,
      actions: [{ key: 'need', label: need.action.label, href: needHref(b.booking_number, need.action.path), primary: true, testId: 'now-need' },
        ...base.actions.map((a) => ({ ...a, primary: false }))]
    };
  } else if (b.status === 'closed' && opts.reviewDue && b.booking_type !== 'owner') {
    kind = 'review';
    out = {
      ...base,
      kicker: `Rental complete · ${b.booking_number}`,
      headline: 'Leave a review',
      detail: 'Tell the next renter how it went. Stars and a few words take a minute.',
      urgent: false,
      actions: [{ key: 'review', label: 'Write a review', href: `${path}/review`, primary: true, testId: 'now-review' },
        ...base.actions.filter((a) => a.key !== 'message').map((a) => ({ ...a, primary: false }))]
    };
  } else if (step.urgent || balance > 0) {
    out = { ...base, kicker: `${DO_NEXT} · ${b.booking_number}` };
  }

  let dl: Deadline | null = null;
  if (b.status === 'offered') dl = deadline('Offer ends', b.offer_expires_at, now, 'The offer ended {t} ago');
  else if (['pending_payment', 'confirmed'].includes(b.status) && !b.handed_over_at) dl = deadline('Pickup', b.pickup_at, now);
  else if (b.status === 'on_rent') dl = deadline('Return', b.return_at, now, 'Return was due {t} ago');
  // a late return or an offer about to end is urgent even when the step itself is not
  const urgent = out.urgent || (!!dl && (dl.late || (dl.soon && (kind === 'offer' || kind === 'sign-pay' || kind === 'verify'))));
  return { ...out, urgent, kind, deadline: dl };
}

export type StageState = 'done' | 'now' | 'later';
export interface Stage { key: string; label: string; state: StageState; href?: string; /** the renter acts on it (a link), or waits for us */ yours: boolean }

// The booking's progress (status.ts progress, nine steps) in six plain stages for the tracker.
const STAGES: Array<{ key: string; label: string; from: string[] }> = [
  { key: 'offer', label: 'Approve the offer', from: ['Request sent', 'Offer approved'] },
  { key: 'sign-pay', label: 'Sign and pay', from: ['Agreement signed', 'Paid'] },
  { key: 'verify', label: 'Licence and insurance', from: ['Drivers verified', 'Coverage confirmed'] },
  { key: 'pickup', label: 'Pick up the car', from: ['Pickup'] },
  { key: 'return', label: 'Return the car', from: ['Return'] },
  { key: 'statement', label: 'Final statement', from: ['Statement'] }
];

const LIVE = ['confirmed', 'on_rent', 'returned', 'closed'];
/** The tracker: each stage done, now (the first not done) or later, with where to do it. A booking that is booked has
 *  its offer behind it (a rental our team added has none), and once the car is picked up every stage before is behind. */
export function stages(steps: Progress[], status?: string): Stage[] {
  let seenNow = false;
  const doneOf = (s: (typeof STAGES)[number]) => { const parts = steps.filter((p) => s.from.includes(p.label)); return parts.length > 0 && parts.every((p) => p.done); };
  const trip = ['pickup', 'return', 'statement'];
  const furthest = STAGES.reduce((n, s, i) => (trip.includes(s.key) && doneOf(s) ? i : n), -1);
  return STAGES.map((s, i) => {
    const parts = steps.filter((p) => s.from.includes(p.label));
    const done = doneOf(s) || i < furthest || (s.key === 'offer' && !!status && LIVE.includes(status));
    const href = parts.find((p) => !p.done && p.href)?.href;
    const state: StageState = done ? 'done' : seenNow ? 'later' : 'now';
    if (state === 'now') seenNow = true;
    return { key: s.key, label: s.label, state, href, yours: !!href };
  });
}

/** "Step 3 of 6: Licence and insurance" (or "All steps done"), for the tracker's heading and the screen reader. */
export function stageSummary(list: Stage[]): { done: number; total: number; text: string } {
  const done = list.filter((s) => s.state === 'done').length;
  const cur = list.find((s) => s.state === 'now');
  return { done, total: list.length, text: cur ? `Step ${list.indexOf(cur) + 1} of ${list.length}: ${cur.label}` : 'All steps done' };
}

/** The stages done since the renter last saw this booking (the tracker animates only those). */
export function newlyDone(list: Stage[], seen: string[] | null): string[] {
  if (!seen) return [];
  return list.filter((s) => s.state === 'done' && !seen.includes(s.key)).map((s) => s.key);
}
