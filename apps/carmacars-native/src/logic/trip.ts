// A trip's next step for its renter, from what the server already worked out (the one rule for signing and paying,
// app.sign_pay_state, and what the booking still needs, app.renter_still_needed). Nothing is decided here: this turns
// the server's answer into the one button the trip screen leads with.
export interface TripLike {
  booking_number: string; status: string; pickup_at: string; return_at: string; current_offer_version?: number | null;
  sign_pay?: { step: 'offer' | 'sign' | 'drivers' | 'pay' | 'none'; due_cents: number; stale?: boolean } | null;
  still_needed?: { items: Array<{ key: string; label: string; status: 'missing' | 'review' | 'rejected' | 'done'; reason: string | null; action?: { label: string; path: string } | null }>; complete: boolean } | null;
}
/** `path` is a page of the site (the same address the website's button goes to): the app opens its own screen for it when
 *  it has one (src/logic/links.ts), else the page in the in-app browser. */
export interface NextStep { key: 'offer' | 'sign' | 'drivers' | 'pay' | 'need' | 'checkin' | 'extend' | 'none'; title: string; cta: string | null; path: string | null }

export function nextStep(b: TripLike, o: { selfCheckin?: boolean } = {}): NextStep {
  const base = `/account/bookings/${b.booking_number}`;
  const sp = b.sign_pay?.step ?? 'none';
  if (b.status === 'offered' || sp === 'offer') return { key: 'offer', title: 'Your offer is ready', cta: 'Review the offer', path: base };
  if (sp === 'sign') return { key: 'sign', title: b.sign_pay?.stale ? 'Your offer changed: sign the updated agreement' : 'Sign your rental agreement', cta: 'Read and sign', path: `${base}/checkout` };
  if (sp === 'drivers') return { key: 'drivers', title: 'Waiting for another driver to sign', cta: null, path: null };
  if (sp === 'pay') return { key: 'pay', title: 'Pay to confirm your booking', cta: 'Pay now', path: `${base}/checkout#pay` };
  // what the booking still needs, as the database lists it: what was not accepted first, then what is missing
  if (['requested', 'offered', 'pending_payment', 'confirmed'].includes(b.status)) {
    const open = (b.still_needed?.items ?? []).filter((i) => (i.status === 'rejected' || i.status === 'missing') && i.action);
    const first = open.find((i) => i.status === 'rejected') ?? open[0];
    if (first?.action) return { key: 'need', title: first.status === 'rejected' ? `Not accepted: ${first.label}` : first.label, cta: first.action.label, path: first.action.path };
  }
  if (b.status === 'confirmed' && o.selfCheckin) return { key: 'checkin', title: 'Check in at the car', cta: 'Start check-in', path: `${base}/pickup` };
  if (b.status === 'on_rent') return { key: 'extend', title: 'Need the car longer?', cta: 'Extend', path: `${base}/extend` };
  return { key: 'none', title: '', cta: null, path: null };
}
export const STATUS_WORD: Record<string, string> = { requested: 'Request sent', offered: 'Offer ready', pending_payment: 'Awaiting payment', confirmed: 'Confirmed', on_rent: 'On trip', returned: 'Returned', closed: 'Completed',
  cancelled: 'Cancelled', expired: 'Expired', declined: 'Declined' };
/** Trips in the order a renter needs them: on trip, then upcoming by pickup, then past, newest first. */
export function sortTrips<T extends { status: string; pickup_at: string }>(list: readonly T[]): { current: T[]; past: T[] } {
  const live = (s: string) => ['requested', 'offered', 'pending_payment', 'confirmed', 'on_rent'].includes(s);
  const current = list.filter((b) => live(b.status)).sort((a, b) => (a.status === 'on_rent' ? -1 : 0) - (b.status === 'on_rent' ? -1 : 0) || a.pickup_at.localeCompare(b.pickup_at));
  const past = list.filter((b) => !live(b.status)).sort((a, b) => b.pickup_at.localeCompare(a.pickup_at));
  return { current, past };
}
