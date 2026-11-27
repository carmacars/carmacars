// r35 UX (1106): "make sure a renter is good to go for a rental". The get-ready checklist of a booking for the office
// (Admin, customer service, Sales): one line per thing the pickup needs, done or not, with what to press when it is not.
// Pure: the booking page and the unit tests share it (readiness.test.ts).

export interface ReadyFacts {
  status: string;
  /** what the renter owes at booking and what is paid (cents) */
  dueCents: number; paidCents: number;
  /** the booking's readiness (app.booking_readiness) */
  readiness: Record<string, unknown> | null;
  insurerBilled: boolean;
  /** the add-ons to put in the car and how many are ticked by field staff (0930) */
  addons?: { total: number; ticked: number } | null;
}
export interface ReadyLine { key: string; label: string; done: boolean; hint: string }

const ACTIVE = ['offered', 'pending_payment', 'tentative', 'confirmed'];
export const showReadiness = (status: string) => ACTIVE.includes(status);

/** r48 (2920): the coverage line says exactly what is missing (app.coverage_state, the rule Approve all and the renter's
 *  checklist read): what the renter still has to send, or that it waits for our review. */
export function coverageHint(r: Record<string, unknown>): string {
  const needs = Array.isArray(r.coverage_needs) ? (r.coverage_needs as unknown[]).filter((x): x is string => typeof x === 'string') : [];
  if (needs.length) return `Waiting for the renter to send ${needs.map((n) => n.replace(/^your /, 'their ')).join(' and ')}. Nothing to approve yet: their checklist asks for it.`;
  if (r.coverage_waiting === true) return 'Ready for review: Approve all on Documents.';
  return 'Review the proof of coverage, or switch the booking to the Protection Plan.';
}

/** How many drivers besides the renter (app.booking_readiness drivers); null when the readiness does not list them. */
export function extraDrivers(r: Record<string, unknown>): number | null {
  if (!Array.isArray(r.drivers)) return null;
  return (r.drivers as Array<{ role?: unknown }>).filter((d) => d && d.role !== 'renter').length;
}

export function readinessLines(f: ReadyFacts): ReadyLine[] {
  const r = f.readiness ?? {};
  const flag = (k: string) => r[k] === true;
  const lines: ReadyLine[] = [
    { key: 'offer', label: 'Offer accepted', done: !['requested', 'offered'].includes(f.status), hint: 'Edit the offer or send it again with a later expiry.' },
    { key: 'paid', label: f.insurerBilled ? 'Renter\'s part paid' : 'Rental paid', done: f.dueCents <= 0 || f.paidCents >= f.dueCents, hint: 'Send a pay link on Money (text or email), or take the card on this device.' },
    { key: 'identity', label: 'Licence and selfie verified', done: flag('all_drivers_verified'), hint: 'Review documents: approve, or reject with the reason the renter sees.' },
    { key: 'coverage', label: 'Coverage confirmed', done: flag('coverage_confirmed'), hint: coverageHint(r) },
    { key: 'deposit', label: 'Deposit held', done: flag('deposit_ok') || flag('deposit_taken') || flag('deposit_waived'), hint: 'Send the deposit link on Money.' },
    // r48 part 2: one driver only is "No additional drivers", not a ticked "Additional drivers accepted"
    extraDrivers(r) === 0
      ? { key: 'drivers', label: 'No additional drivers', done: true, hint: '' }
      : { key: 'drivers', label: 'Additional drivers accepted', done: r.additional_drivers_accepted !== false, hint: 'Send each driver their signing link (Documents).' },
    { key: 'agreement', label: 'Agreement signed', done: flag('agreement_completed'), hint: 'Send the agreement again from the Agreement panel.' }
  ];
  if (f.addons && f.addons.total > 0) lines.push({ key: 'prepare', label: `Add-ons in the car (${f.addons.ticked} of ${f.addons.total})`, done: f.addons.ticked >= f.addons.total, hint: 'Field staff tick each one on the pickup.' });
  return lines;
}

/** "4 of 7 ready" */
export function readinessSummary(lines: ReadyLine[]): string {
  const done = lines.filter((l) => l.done).length;
  return done === lines.length ? 'Good to go: everything is ready for the pickup.' : `${done} of ${lines.length} ready`;
}

/** r38 (owner, Nov 11): where each line's action is, so "What's left" jumps straight to it: the booking page's tab and the
 *  section's anchor id on that tab (BookingPage puts the ids). */
export const READY_TARGET: Record<string, { tab: string; anchor: string }> = {
  offer: { tab: 'review', anchor: 'bk-review' },
  paid: { tab: 'money', anchor: 'bk-money' },
  deposit: { tab: 'money', anchor: 'bk-money' },
  identity: { tab: 'documents', anchor: 'bk-documents' },
  coverage: { tab: 'documents', anchor: 'bk-documents' },
  drivers: { tab: 'documents', anchor: 'bk-documents' },
  agreement: { tab: 'documents', anchor: 'bk-documents' },
  prepare: { tab: 'overview', anchor: 'booking-readiness' }
};
/** The link of a line: its tab and anchor on the booking page at `base`. */
export function readinessHref(key: string, base: string): string {
  const t = READY_TARGET[key] ?? { tab: 'overview', anchor: 'booking-readiness' };
  return `${base}?tab=${t.tab}#${t.anchor}`;
}
/** The first thing still to do (the phone's compact bar), or null when all is done. */
export const readyNext = (lines: ReadyLine[]) => lines.find((l) => !l.done) ?? null;

/** r50 hotfix 2: the staff steps from the sale to the pickup, as the stepped tracker draws them (Milestones). The steps the
 *  renter does say they wait on the renter; the others are the team's. Done steps stay done whatever their order; the
 *  first one not done is the one to do now. */
export interface SaleStep { key: string; label: string; state: 'done' | 'now' | 'later'; hint: string | null; href: string | null; cta: string | null; yours: boolean; turn: string }
export const SALE_STATUSES = ['requested', 'offered', 'pending_payment', 'tentative', 'confirmed', 'on_rent', 'returned', 'closed'];
export function saleSteps(f: ReadyFacts, base: string): SaleStep[] {
  const lines = readinessLines(f);
  const line = (k: string) => lines.find((l) => l.key === k);
  const out = ['on_rent', 'returned', 'closed'].includes(f.status);
  const raw: Array<{ key: string; label: string; done: boolean; hint: string; renter: boolean; line: string }> = [
    { key: 'answer', label: 'Request answered with an offer', done: f.status !== 'requested', hint: 'Check the car and the dates, then send the offer from Review.', renter: false, line: 'offer' },
    { key: 'accept', label: 'Offer accepted', done: !!line('offer')?.done, hint: line('offer')!.hint, renter: true, line: 'offer' },
    { key: 'agreement', label: 'Agreement signed', done: !!line('agreement')?.done, hint: line('agreement')!.hint, renter: true, line: 'agreement' },
    { key: 'paid', label: line('paid')!.label, done: !!line('paid')?.done, hint: line('paid')!.hint, renter: true, line: 'paid' },
    { key: 'verified', label: 'Licence and coverage checked', done: !!line('identity')?.done && !!line('coverage')?.done, hint: `${line('identity')!.hint} ${line('coverage')!.hint}`, renter: false, line: line('identity')?.done ? 'coverage' : 'identity' },
    { key: 'deposit', label: 'Deposit and drivers', done: !!line('deposit')?.done && !!line('drivers')?.done, hint: `${line('deposit')!.hint} ${line('drivers')!.hint}`.trim(), renter: true, line: line('deposit')?.done ? 'drivers' : 'deposit' },
    { key: 'prepared', label: 'Car prepared for the pickup', done: line('prepare') ? !!line('prepare')!.done : f.status === 'confirmed' || out, hint: line('prepare')?.hint ?? 'Clean, fuelled, photos ready and the add-ons in the car.', renter: false, line: 'prepare' },
    { key: 'pickup', label: 'Picked up', done: out, hint: 'Record the pickup: the photos, the km and the fuel.', renter: false, line: 'prepare' }
  ];
  // once the car is out, every step before counts as done
  const done = raw.map((r) => out || r.done);
  const first = done.indexOf(false);
  return raw.map((r, i) => ({ key: r.key, label: r.label, state: done[i] ? 'done' : i === first ? 'now' : 'later', hint: done[i] ? null : r.hint,
    href: done[i] ? null : readinessHref(r.line, base), cta: done[i] ? null : 'Go there', yours: !r.renter, turn: r.renter ? 'Waiting on the renter: nudge them' : 'Your turn' }));
}
