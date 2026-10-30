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
  /** what this person may do: false hides a button they could not use (staff without that function) */
  can?: Partial<Record<'offer' | 'money' | 'sign' | 'handover' | 'settle', boolean>>;
}

export interface NextStep {
  /** a short code for tests and the page (data-step) */
  step: 'send_offer' | 'wait_offer' | 'wait_payment' | 'sign' | 'deposit' | 'checkout' | 'checkin' | 'settle' | 'done' | 'closed' | 'other';
  /** the plain sentence */
  text: string;
  /** who does it */
  who: string;
  action?: { label: string; href: string; testId: string };
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
  const can = (k: keyof NonNullable<NextStepInput['can']>) => x.can?.[k] !== false;
  const btn = (k: keyof NonNullable<NextStepInput['can']>, label: string, href: string, testId: string) => (can(k) ? { action: { label, href, testId } } : {});
  const today = dayKey(x.now);
  const pickupDay = dayKey(new Date(x.pickupAt));
  const depositNeeded = Number(x.depositCents ?? 0) > 0 && !HELD.has(String(x.depositStatus ?? ''));
  switch (x.status) {
    case 'requested':
      return { step: 'send_offer', who: 'Sales or customer service', text: 'The renter asked for this car. Check the request and send the offer: it is not a booking until the renter approves and pays.',
        ...btn('offer', 'Send the offer', `${x.base}?tab=review`, 'next-step-offer') };
    case 'offered':
      return { step: 'wait_offer', who: 'The renter', text: `Waiting for the renter to approve the offer${x.offerExpiresAt ? ` (open until ${when(x.offerExpiresAt)})` : ''}. Nothing to do unless they call: then use Renter approved by phone in More actions.` };
    case 'pending_payment': {
      const open = Math.max(0, Number(x.dueCents ?? 0) - Number(x.paidCents ?? 0));
      return { step: 'wait_payment', who: 'The renter, or staff when they pay another way',
        text: `The renter approved the offer. Waiting for payment${open > 0 ? `: ${money(open)} open` : ''}. Record cash or e-Transfer, or send a pay link.`,
        ...btn('money', 'Record a payment or send a pay link', `${x.base}?tab=money`, 'next-step-pay') };
    }
    case 'confirmed': {
      if (x.awaitingSignature) return { step: 'sign', who: 'The renter', text: 'Booked and paid. The renter signs the rental agreement: on this device, or from the link in their email.',
        ...btn('sign', 'Sign on this device', `${x.base}/sign-now`, 'next-step-sign') };
      if (pickupDay <= today) return { step: 'checkout', who: 'The person at the pickup',
        text: `Pickup ${pickupDay < today ? 'was' : 'is'} ${when(x.pickupAt)}. Check out the car${depositNeeded && !x.insurerBilled ? ` and take the ${money(Number(x.depositCents))} deposit hold` : ''}.`,
        ...btn('handover', 'Check out the car', '#c-check-out-check-in-and-signing', 'next-step-checkout') };
      if (depositNeeded && !x.insurerBilled) return { step: 'deposit', who: 'The person at the pickup',
        text: `Booked, paid and signed. At the pickup (${when(x.pickupAt)}), take the ${money(Number(x.depositCents))} deposit hold, then check out the car.` };
      return { step: 'checkout', who: 'The person at the pickup', text: `Booked, paid and signed. Check out the car at the pickup: ${when(x.pickupAt)}.` };
    }
    case 'on_rent': {
      const late = new Date(x.returnAt).getTime() < x.now.getTime();
      return { step: 'checkin', who: 'The person at the return',
        text: late ? `The return was due ${when(x.returnAt)}. Check the car in as soon as it is back.` : `The renter has the car. Return due ${when(x.returnAt)}: check the car in when it is back.`,
        ...btn('handover', 'Check in the car', '#c-check-out-check-in-and-signing', 'next-step-checkin') };
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
