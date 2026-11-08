// The "Next step" panel at the top of a booking (Admin and staff booking pages, the owner, October 30: "not sure if it
// has become a booking or not... too many buttons"). One plain sentence of what happens next and who does it, from the
// status and the booking's readiness, and at most one button for that step. The other actions are in "More actions".
// No imports: unit tested in Node (next-step.test.ts).

export interface NextStepInput {
  status: string;
  /** the booking page's address, e.g. /admin/bookings/CC-123 */
  base: string;
  now: Date;
  pickupAt: string;
  returnAt: string;
  offerExpiresAt?: string | null;
  /** what the renter owes at booking (renter_due_at_booking_cents, else the total) */
  dueCents?: number | null;
  /** card and other payments that went through */
  paidCents?: number | null;
  /** readiness.awaiting_signature: the agreement is waiting for the renter's signature */
  awaitingSignature?: boolean | null;
  depositCents?: number | null;
  /** the deposit row's status (pending, held, captured, settled, failed, carried_forward), null before one exists */
  depositStatus?: string | null;
  checkedInAt?: string | null;
  /** an insurer pays the rental (bill_to is not the renter) */
  insurerBilled?: boolean;
  /** Release 24b: every driver's licence approved (readiness.all_drivers_verified); false puts the licence first */
  licenceOk?: boolean | null;
  /** Release 24b: the pickup Condition Report's photos are complete (after the check-in) */
  checkoutPhotosOk?: boolean | null;
  /** Release 24b: the return Condition Report has its photos, km and fuel */
  checkinOk?: boolean | null;
  /** r33 (0750): what the renter sees still to do, the same sentence as their Sign and pay card (sign-pay.ts) */
  renterLeft?: string | null;
  /** r33 (0750): the renter's step from the one rule: sign, drivers, pay */
  renterStep?: string | null;
  /** what this person may do: false hides a button they could not use (staff without that function) */
  can?: Partial<Record<'offer' | 'money' | 'sign' | 'handover' | 'settle', boolean>>;
}

export interface NextStep {
  /** a short code for tests and the page (data-step) */
  step: 'send_offer' | 'wait_offer' | 'wait_payment' | 'licence' | 'sign' | 'deposit' | 'checkout' | 'checkin' | 'settle' | 'done' | 'closed' | 'other';
  /** the plain sentence */
  text: string;
  /** who does it */
  who: string;
  action?: { label: string; href: string; testId: string };
  /** Release 24b: the handover essentials (licence, agreement, deposit, photos) with what is done, top of the booking */
  essentials?: Essential[];
}
export interface Essential { key: 'licence' | 'agreement' | 'deposit' | 'checkout_photos' | 'checkin'; label: string; done: boolean }

/** The three handover essentials (and the photos), in the order they are needed, for a booking on its way to the car or out. */
export function essentials(x: NextStepInput): Essential[] | undefined {
  if (!['pending_payment', 'confirmed', 'on_rent'].includes(x.status)) return undefined;
  const depositDone = !(Number(x.depositCents ?? 0) > 0) || x.insurerBilled === true || HELD.has(String(x.depositStatus ?? ''));
  const out: Essential[] = [
    { key: 'licence', label: 'Driver\'s licence approved', done: x.licenceOk !== false },
    { key: 'agreement', label: 'Rental agreement signed', done: x.status === 'pending_payment' ? x.renterStep === 'pay' : !x.awaitingSignature },
    { key: 'deposit', label: 'Deposit taken (or waived by an Admin)', done: depositDone },
    { key: 'checkout_photos', label: 'Check-in photos', done: x.status === 'on_rent' || x.checkoutPhotosOk === true }
  ];
  if (x.status === 'on_rent') out.push({ key: 'checkin', label: 'Check-out photos, km and fuel', done: x.checkinOk === true });
  return out;
}

const TZ = 'America/Toronto';
const dayKey = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
/** "Fri Oct 31, 10:00 a.m." in Toronto time */
export function when(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const day = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, weekday: 'short', month: 'short', day: 'numeric' }).format(d).replace(/\./g, '');
  const time = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, hour: 'numeric', minute: '2-digit', hour12: true }).format(d);
  return `${day}, ${time}`;
}
const money = (c: number) => `$${(c / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const HELD = new Set(['held', 'captured', 'settled', 'carried_forward']);

export function nextStep(x: NextStepInput): NextStep {
  const s = nextStepOnly(x);
  const e = essentials(x);
  return e ? { ...s, essentials: e } : s;
}

function nextStepOnly(x: NextStepInput): NextStep {
  const can = (k: keyof NonNullable<NextStepInput['can']>) => x.can?.[k] !== false;
  const btn = (k: keyof NonNullable<NextStepInput['can']>, label: string, href: string, testId: string) => (can(k) ? { action: { label, href, testId } } : {});
  const today = dayKey(x.now);
  const pickupDay = dayKey(new Date(x.pickupAt));
  const depositNeeded = Number(x.depositCents ?? 0) > 0 && !HELD.has(String(x.depositStatus ?? ''));
  switch (x.status) {
    case 'requested':
      return { step: 'send_offer', who: 'Sales or customer service', text: 'The renter asked for this car. Check the request and send the offer: it is booked once the renter approves.',
        ...btn('offer', 'Send the offer', `${x.base}?tab=review`, 'next-step-offer') };
    case 'offered':
      return { step: 'wait_offer', who: 'The renter', text: `Waiting for the renter to approve the offer${x.offerExpiresAt ? ` (open until ${when(x.offerExpiresAt)})` : ''}. Nothing to do unless they call: then use Renter approved by phone in More actions.` };
    case 'pending_payment': {
      const open = Math.max(0, Number(x.dueCents ?? 0) - Number(x.paidCents ?? 0));
      // r33: the same thing the renter sees ("The renter sees: Two steps left: sign the rental agreement, then pay $X.")
      const sees = x.renterLeft ? ` The renter sees: "${x.renterLeft}"` : '';
      if (x.renterStep === 'sign' || x.renterStep === 'drivers') return { step: 'wait_payment', who: 'The renter',
        text: `Booked: the renter approved the offer and still has to sign${open > 0 ? `, then pay ${money(open)}` : ''}.${sees} To sign in person, use Sign on this device.`,
        ...btn('sign', 'Sign on this device', `${x.base}/sign-now`, 'next-step-sign') };
      return { step: 'wait_payment', who: 'The renter, or staff when they pay another way',
        text: `Booked: the renter approved the offer${x.renterStep === 'pay' ? ' and signed' : ''}. Payment due${open > 0 ? `: ${money(open)} open` : ''}.${sees} Record cash or e-Transfer, or send a pay link.`,
        ...btn('money', 'Record a payment or send a pay link', `${x.base}?tab=money`, 'next-step-pay') };
    }
    case 'confirmed': {
      // Release 24b: the licence first (no car without it), then the signature, then the deposit
      if (x.licenceOk === false) return { step: 'licence', who: 'The renter, then customer service', text: `The driver's licence is not approved yet. The renter uploads it (photo, HEIC or PDF scan) and staff approve it before pickup (${when(x.pickupAt)}).`,
        ...btn('handover', 'Review the licence', `${x.base}?tab=documents`, 'next-step-licence') };
      if (x.awaitingSignature) return { step: 'sign', who: 'The renter', text: 'Booked and paid. The renter signs the rental agreement: on this device, or from the link in their email.',
        ...btn('sign', 'Sign on this device', `${x.base}/sign-now`, 'next-step-sign') };
      if (pickupDay <= today) return { step: 'checkout', who: 'The person at the pickup',
        text: `Pickup ${pickupDay < today ? 'was' : 'is'} ${when(x.pickupAt)}. ${depositNeeded && !x.insurerBilled ? `No deposit yet: take the ${money(Number(x.depositCents))} deposit hold now, then check in the car` : 'Check in the car'}.`,
        ...btn('handover', 'Check in the car', '#c-check-in-check-out-and-signing', 'next-step-checkout') };
      if (depositNeeded && !x.insurerBilled) return { step: 'deposit', who: 'The person at the pickup',
        text: `Booked, paid and signed. At the pickup (${when(x.pickupAt)}), take the ${money(Number(x.depositCents))} deposit hold, then check in the car.` };
      return { step: 'checkout', who: 'The person at the pickup', text: `Booked, paid and signed. Check in the car at the pickup: ${when(x.pickupAt)}.` };
    }
    case 'on_rent': {
      const late = new Date(x.returnAt).getTime() < x.now.getTime();
      return { step: 'checkin', who: 'The person at the return',
        text: late ? `The return was due ${when(x.returnAt)}. Check the car in as soon as it is back.` : `The renter has the car. Return due ${when(x.returnAt)}: check the car in when it is back.`,
        ...btn('handover', 'Check out the car', '#c-check-in-check-out-and-signing', 'next-step-checkin') };
    }
    case 'returned':
      return { step: 'settle', who: 'Finance', text: Number(x.depositCents ?? 0) > 0 || x.depositStatus
        ? 'The car is back. Issue the final statement and settle the deposit (release it, or keep what is owed).'
        : 'The car is back. Issue the final statement.',
        ...btn('settle', 'Settle the deposit', `${x.base}?tab=money#c-deposit`, 'next-step-settle') };
    case 'closed':
      return { step: 'closed', who: 'Nobody', text: 'Closed. Nothing more to do.' };
    case 'cancelled':
      return { step: 'done', who: 'Nobody', text: 'Cancelled. Any refund shows on the Money tab.' };
    case 'declined':
      return { step: 'done', who: 'Nobody', text: 'Declined. It never became a booking.' };
    case 'expired':
      return { step: 'done', who: 'Sales or customer service', text: 'The offer ran out before the renter approved it, so it never became a booking. Reopen it from More actions if the renter still wants the car.' };
    default:
      return { step: 'other', who: 'Staff', text: `Status: ${x.status.replace(/_/g, ' ')}.` };
  }
}
