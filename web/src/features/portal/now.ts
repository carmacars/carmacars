import type { NextStep } from './status.ts';
import type { BookingSummary } from './types.ts';

// The renter home's first panel (r27 portals, the owner's ask: the portal opens on "what do I need to do or know right
// now", the next action first, e.g. "Return the Jetta today 7pm at X, Extend, Pay $Y"). One sentence, the place, the one
// button for the next step, then the few things a renter does on a live trip. Pure: the home renders it, the unit tests
// check it. Times in Toronto.

export interface NowAction { key: string; label: string; href: string; primary?: boolean; testId?: string }
export interface RenterNow {
  kicker: string;
  /** The sentence: what to do, with the car and when ("Return the 2024 Volkswagen Jetta today at 7:00 p.m."). */
  headline: string;
  /** Where (the pickup or return place), or the step's note. */
  detail: string | null;
  urgent: boolean;
  actions: NowAction[];
}

const TZ = 'America/Toronto';
const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
const time = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: TZ, hour: 'numeric', minute: '2-digit', hour12: true }).format(d)
  .replace(/\s?a\.?m\.?/i, ' a.m.').replace(/\s?p\.?m\.?/i, ' p.m.');

/** "today at 7:00 p.m.", "tomorrow at 10:00 a.m.", "Fri, Nov 6 at 9:00 a.m." (the day in words when it is near). */
export function whenWords(iso: string, now: number): string {
  const d = new Date(iso);
  const day = ymd(d);
  const today = ymd(new Date(now));
  const tomorrow = ymd(new Date(now + 86_400_000));
  const yesterday = ymd(new Date(now - 86_400_000));
  const dayWord = day === today ? 'today' : day === tomorrow ? 'tomorrow' : day === yesterday ? 'yesterday'
    : new Intl.DateTimeFormat('en-CA', { timeZone: TZ, weekday: 'short', month: 'short', day: 'numeric' }).format(d).replace(/\./g, '');
  return `${dayWord} at ${time(d)}`;
}

const car = (b: Pick<BookingSummary, 'vehicle_year' | 'vehicle_make' | 'vehicle_model'>) => `${b.vehicle_year} ${b.vehicle_make} ${b.vehicle_model}`;
const dollars = (cents: number) => `$${(cents / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

/**
 * What the renter needs now, for their nearest trip. `step` is the booking's next step (status.ts nextStep); `place`
 * the pickup or return place in words (whichever is next); `balanceCents` what is still owing after a change or a charge
 * (tolls, damage, a late return), with Pay.
 */
export function renterNow(b: BookingSummary, step: NextStep, opts: { pickupPlace: string | null; returnPlace: string | null; balanceCents?: number; now?: number }): RenterNow {
  const now = opts.now ?? Date.now();
  const path = `/account/bookings/${encodeURIComponent(b.booking_number)}`;
  const balance = Math.max(0, opts.balanceCents ?? 0);
  const actions: NowAction[] = [];
  const stepAction = step.href && step.cta && step.href !== path ? { key: 'step', label: step.cta, href: step.href, primary: true, testId: 'now-step' } : null;
  let headline = step.title;
  let detail: string | null = step.note;
  let kicker = `Next step · ${b.booking_number}`;
  if (!step.urgent && b.status === 'on_rent') {
    headline = `Return the ${car(b)} ${whenWords(b.return_at, now)}`;
    detail = opts.returnPlace;
    kicker = `On your trip · ${b.booking_number}`;
  } else if (!step.urgent && b.status === 'confirmed') {
    headline = `Pick up the ${car(b)} ${whenWords(b.pickup_at, now)}`;
    detail = opts.pickupPlace ? `${opts.pickupPlace}. Bring your original licence and the card you paid with.` : 'Bring your original licence and the card you paid with.';
    kicker = `Booked · ${b.booking_number}`;
  } else if (step.urgent && ['confirmed', 'on_rent'].includes(b.status)) {
    // sign, pay or upload first; the time still shows
    detail = `${step.note} ${b.status === 'on_rent' ? `Return ${whenWords(b.return_at, now)}.` : `Pickup ${whenWords(b.pickup_at, now)}.`}`;
  } else if (!['requested', 'offered', 'pending_payment'].includes(b.status)) {
    kicker = b.booking_number;
  }
  if (stepAction && step.urgent) actions.push(stepAction);
  if (balance > 0) actions.push({ key: 'pay', label: `Pay ${dollars(balance)}`, href: `${path}#pt-bal`, primary: !actions.some((a) => a.primary), testId: 'now-pay' });
  if (['confirmed', 'on_rent'].includes(b.status)) actions.push({ key: 'extend', label: 'Extend', href: `${path}/extend`, testId: 'now-extend' });
  if (stepAction && !step.urgent && !actions.some((a) => a.href === stepAction.href)) actions.push({ ...stepAction, primary: !actions.some((a) => a.primary) });
  actions.push({ key: 'trip', label: 'Trip details', href: path, testId: 'now-trip' });
  actions.push({ key: 'message', label: 'Message us', href: `${path}#messages`, testId: 'now-message' });
  return { kicker, headline, detail, urgent: !!step.urgent || balance > 0, actions };
}
