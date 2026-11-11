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

export function readinessLines(f: ReadyFacts): ReadyLine[] {
  const r = f.readiness ?? {};
  const flag = (k: string) => r[k] === true;
  const lines: ReadyLine[] = [
    { key: 'offer', label: 'Offer accepted', done: !['requested', 'offered'].includes(f.status), hint: 'Edit the offer or send it again with a later expiry.' },
    { key: 'paid', label: f.insurerBilled ? 'Renter\'s part paid' : 'Rental paid', done: f.dueCents <= 0 || f.paidCents >= f.dueCents, hint: 'Send a pay link on Money (text or email), or take the card on this device.' },
    { key: 'identity', label: 'Licence and selfie verified', done: flag('all_drivers_verified'), hint: 'Review documents: approve, or reject with the reason the renter sees.' },
    { key: 'coverage', label: 'Coverage confirmed', done: flag('coverage_confirmed'), hint: 'Review the proof of coverage, or switch the booking to the Protection Plan.' },
    { key: 'deposit', label: 'Deposit held', done: flag('deposit_ok') || flag('deposit_taken') || flag('deposit_waived'), hint: 'Send the deposit link on Money.' },
    { key: 'drivers', label: 'Additional drivers accepted', done: r.additional_drivers_accepted !== false, hint: 'Send each driver their signing link (Documents).' },
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
