// The deposit guard's money steps (migration 0155), pure: what the server asks Stripe for one payment the database
// marked (payments.server_action), and how Stripe's answer is reported back. The runner (server/deposit-guard.ts) does
// the calls; the unit test checks every step.

export type MoneyAction = 'capture_deposit' | 'release_hold' | 'refund_deposit' | 'charge_card' | 'protect_capture' | 'deposit_charge' | 'balance_charge';

/** public.server_money_action: one marked payment, with the Stripe ids it needs. */
export interface MoneyFacts {
  payment_id: string;
  action: MoneyAction;
  status: string;
  amount_cents: number;
  booking_id: string;
  booking_number: string;
  intent_id: string | null;
  charge_id: string | null;
  customer_id: string | null;
  method_id: string | null;
  skip_processor: boolean;
  idempotency_key: string;
  attempts: number;
}

export type MoneyStep =
  | { call: 'none'; reason: string }
  | { call: 'skip' }
  | { call: 'capture'; intentId: string; amountCents: number; key: string }
  | { call: 'cancel'; intentId: string; key: string }
  | { call: 'refund'; intentId: string | null; chargeId: string | null; amountCents: number; key: string; metadata: Record<string, string> }
  | { call: 'charge'; customerId: string; methodId: string; amountCents: number; key: string; description: string; metadata: Record<string, string> };

const WHY: Record<MoneyAction, string> = {
  capture_deposit: 'deposit', protect_capture: 'deposit', release_hold: 'deposit', refund_deposit: 'deposit refund',
  charge_card: 'charges after the rental', balance_charge: 'charges after the rental', deposit_charge: 'deposit'
};

/** The Stripe call for one marked payment (none: it cannot be made, with the reason in plain words). */
export function stepFor(f: MoneyFacts): MoneyStep {
  if (f.status !== 'pending') return { call: 'none', reason: 'Not waiting any more' };
  if (f.amount_cents <= 0) return { call: 'none', reason: 'No amount' };
  switch (f.action) {
    case 'capture_deposit':
    case 'protect_capture':
      if (!f.intent_id) return { call: 'none', reason: 'The card hold has no Stripe reference' };
      return { call: 'capture', intentId: f.intent_id, amountCents: f.amount_cents, key: f.idempotency_key };
    case 'release_hold':
      // a capture of the same hold already ended it: Stripe released the rest with the capture
      if (f.skip_processor) return { call: 'skip' };
      if (!f.intent_id) return { call: 'none', reason: 'The card hold has no Stripe reference' };
      return { call: 'cancel', intentId: f.intent_id, key: f.idempotency_key };
    case 'refund_deposit':
      if (!f.intent_id && !f.charge_id) return { call: 'none', reason: 'The deposit payment has no Stripe reference' };
      return { call: 'refund', intentId: f.intent_id, chargeId: f.charge_id, amountCents: f.amount_cents, key: f.idempotency_key,
        metadata: { refund_id: f.payment_id, booking_id: f.booking_id, purpose: 'deposit_refund' } };
    case 'charge_card':
    case 'balance_charge':
    case 'deposit_charge':
      if (!f.customer_id || !f.method_id) return { call: 'none', reason: 'No saved card' };
      return { call: 'charge', customerId: f.customer_id, methodId: f.method_id, amountCents: f.amount_cents, key: f.idempotency_key,
        description: `CarmaCars booking ${f.booking_number}: ${WHY[f.action]}`,
        metadata: { booking_id: f.booking_id, purpose: 'deposit_guard', payment_id: f.payment_id, action: f.action } };
  }
}

/** What public.server_money_action_finish is told. */
export interface MoneyOutcome { ok: boolean; error?: string | null; intent_status?: string | null; intent_id?: string | null; charge_id?: string | null; refund_id?: string | null; refund_status?: string | null }

/** Stripe's answer, in the words the database records. A capture or a charge is done only when the intent succeeded;
 *  a release only when it is canceled; a refund when Stripe accepted it (the bank may confirm it later). */
export function outcomeOf(step: MoneyStep, r: { status?: string; id?: string; chargeId?: string | null; lastError?: string | null; failureReason?: string | null }): MoneyOutcome {
  switch (step.call) {
    case 'skip': return { ok: true };
    case 'none': return { ok: false, error: step.reason };
    case 'capture':
    case 'charge':
      return r.status === 'succeeded' ? { ok: true, intent_id: r.id ?? null, charge_id: r.chargeId ?? null, intent_status: r.status }
        : { ok: false, intent_status: r.status ?? null, error: r.lastError ?? `Stripe answered ${r.status ?? 'nothing'}` };
    case 'cancel':
      return r.status === 'canceled' ? { ok: true, intent_status: 'canceled' } : { ok: false, intent_status: r.status ?? null, error: r.lastError ?? `Stripe answered ${r.status ?? 'nothing'}` };
    case 'refund':
      return r.status === 'succeeded' || r.status === 'pending' || r.status === 'requires_action'
        ? { ok: true, refund_id: r.id ?? null, refund_status: r.status === 'succeeded' ? 'succeeded' : 'pending', intent_id: step.intentId }
        : { ok: false, error: r.failureReason ?? `Stripe answered ${r.status ?? 'nothing'}` };
  }
}

/** The order the runner takes a settlement's steps in: captures first (a release after a capture is then skipped). */
export function settlementOrder<T extends { action: string }>(actions: T[]): T[] {
  const rank = (a: string) => (a === 'capture_deposit' || a === 'protect_capture' ? 0 : a === 'charge_card' ? 1 : 2);
  return [...actions].sort((a, b) => rank(a.action) - rank(b.action));
}

/** A Stripe "payment_intent.canceled" that means a deposit hold lapsed (not one we canceled ourselves). */
export function isHoldLapse(type: string, o: Record<string, unknown>): boolean {
  const meta = o.metadata && typeof o.metadata === 'object' ? (o.metadata as Record<string, string>) : {};
  return type === 'payment_intent.canceled' && o.object === 'payment_intent' && o.cancellation_reason === 'automatic'
    && meta.purpose === 'staff_request' && meta.covers === 'deposit';
}
