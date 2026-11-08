// The one rule for signing and paying a booking (migration 0750, app.sign_pay_state), as every page reads it: the
// renter's booking page and home, the Sign and pay page, the payment (startPayment, through the payment facts) and the
// Admin and staff booking page's Next step. The database decides; this only puts it in words. Pure (sign-pay.test.ts).

export type SignPayStep = 'offer' | 'sign' | 'drivers' | 'pay' | 'none';
export interface SignPay {
  step: SignPayStep;
  /** the renter signed the agreement for the approved offer, and every driver who must sign before payment did */
  signed: boolean;
  /** signed, but for an older version of the offer: a fresh agreement is opened for the current one */
  stale: boolean;
  /** a payment follows the signature (waiting for payment, or a rental added while underway with a payment link) */
  pay_after: boolean;
  due_cents: number;
  /** the additional drivers who must still sign before payment */
  waiting: string[];
  signed_at?: string | null;
}

const NONE: SignPay = { step: 'none', signed: false, stale: false, pay_after: false, due_cents: 0, waiting: [] };

/** The rule's answer on a booking read (my_booking, my_bookings: sign_pay), or none when the read has none. */
export function signPayOf(b: { sign_pay?: Partial<SignPay> | null } | null | undefined): SignPay {
  const s = b?.sign_pay;
  if (!s) return NONE;
  return { ...NONE, ...s, waiting: Array.isArray(s.waiting) ? s.waiting : [], due_cents: Number(s.due_cents ?? 0) };
}

/** Is there something for the renter to sign or pay now? */
export const signPayOpen = (s: SignPay) => s.step === 'sign' || s.step === 'drivers' || s.step === 'pay';

const dollars = (c: number) => `$${(c / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const names = (w: string[]) => (w.length <= 1 ? w[0] ?? 'the other driver' : `${w.slice(0, -1).join(', ')} and ${w[w.length - 1]}`);

export interface SignPayWords {
  /** the card's title: "Sign and pay", "Pay", "Sign your agreement", "Waiting for a driver to sign" */
  title: string;
  /** exactly what is left, in one plain sentence with the amount */
  left: string;
  /** the one button */
  cta: string;
}

/** What is left, in the renter's words (the Admin and staff page quotes the same sentence). */
export function signPayWords(s: SignPay): SignPayWords | null {
  const amount = s.pay_after && s.due_cents > 0 ? dollars(s.due_cents) : null;
  switch (s.step) {
    case 'sign':
      if (s.stale) return { title: amount ? 'Sign and pay' : 'Sign your agreement', cta: amount ? `Sign and pay ${amount}` : 'Sign the agreement',
        left: `Your offer was updated after you signed. Sign the updated rental agreement${amount ? `, then pay ${amount}` : ''}.` };
      return amount
        ? { title: 'Sign and pay', cta: `Sign and pay ${amount}`, left: `Two steps left: sign the rental agreement, then pay ${amount}.` }
        : { title: 'Sign your agreement', cta: 'Sign the agreement', left: 'One step left: sign the rental agreement.' };
    case 'drivers':
      return { title: 'Waiting for a driver to sign', cta: 'See who still signs',
        left: `You signed. ${names(s.waiting)} must sign the agreement too${amount ? `, then you pay ${amount}` : ''}.` };
    case 'pay':
      return amount
        ? { title: 'Pay', cta: `Pay ${amount}`, left: `One step left: pay ${amount}. Your agreement is signed.` }
        : { title: 'Nothing to pay now', cta: 'Open', left: 'Your agreement is signed. Nothing is due now: we confirm the booking shortly.' };
    default:
      return null;
  }
}

/** The two steps of the Sign and pay page (2 at most): each done, current or to come. */
export function signPaySteps(s: SignPay): Array<{ label: string; state: 'done' | 'now' | 'next' }> {
  const signDone = s.step === 'pay' || (s.step === 'none' && s.signed);
  const out: Array<{ label: string; state: 'done' | 'now' | 'next' }> = [{ label: 'Sign', state: signDone ? 'done' : 'now' }];
  if (s.pay_after) out.push({ label: 'Pay', state: s.step === 'pay' ? 'now' : s.step === 'none' ? 'done' : 'next' });
  return out;
}
