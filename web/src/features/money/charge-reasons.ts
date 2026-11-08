// The reasons of a charge to the renter after the trip (r33, 0750): Keep part of the deposit, A later charge and Charge
// the renter take one from this list (Other with its note); the database checks the same list (app.charge_reason_label)
// and puts the reason on the renter's receipt. And the card processor's answers in plain sentences: staff never see a raw
// processor error. Pure: charge-reasons.test.ts.

export const CHARGE_REASONS = [
  ['mileage', 'Mileage overage'], ['fuel', 'Fuel'], ['cleaning', 'Cleaning'], ['smoking', 'Smoking'], ['late_return', 'Late return'],
  ['tolls', 'Tolls'], ['tickets', 'Tickets/fines'], ['damage', 'Damage'], ['missing_items', 'Missing items'], ['other', 'Other']
] as const;
export type ChargeReason = (typeof CHARGE_REASONS)[number][0];
export const reasonLabel = (code: string | null | undefined) => CHARGE_REASONS.find(([c]) => c === code)?.[1] ?? null;

/** The reason in words, as the receipt shows it ("Fuel: a quarter tank"); null when it is not complete (Other needs its note). */
export function reasonText(code: string, note: string): string | null {
  const label = reasonLabel(code);
  if (!label) return null;
  const n = note.trim();
  if (code === 'other' && !n) return null;
  return n ? `${label}: ${n}` : label;
}

/** server_booking_charge_reasons (0750): the reason of each charge that has one, and the card fee of a debit deposit. */
export interface ChargeReasons {
  reasons: Array<{ payment_id: string; code: string; label: string; note: string | null }>;
  fees: Array<{ payment_id: string; fee_cents: number; status: string }>;
}

/** A hold that can no longer be kept from: Stripe ended it (it lapsed), or its expiry has passed. */
export function holdExpired(d: { method: string; status: string; hold_expires_at: string | null } | null | undefined, now = Date.now()): boolean {
  return !!d && d.method === 'card_hold' && d.status === 'held' && !!d.hold_expires_at && new Date(d.hold_expires_at).getTime() <= now;
}

/** The processor said the hold is gone (a capture refused because the PaymentIntent is canceled). */
export const isLapsedError = (raw: string | null | undefined) => /status of canceled|has been canceled|payment_intent_unexpected_state.*cancel|authorization.*expired|expired.*authoriz/i.test(raw ?? '');

/** A processor answer in one plain sentence (never the raw error). */
export function plainProcessorError(raw: string | null | undefined, what: 'charge' | 'keep' | 'release' | 'hold' = 'charge'): string {
  const r = raw ?? '';
  if (isLapsedError(r)) return what === 'release' ? 'The card hold had already expired: nothing is held on the card any more.' : 'The card hold has expired, so nothing can be kept from it. Charge the card on file instead.';
  if (/insufficient.funds/i.test(r)) return 'The card was declined: not enough funds. Try another card, or send the renter a pay link.';
  if (/expired.card|card.*has expired|exp_(month|year)/i.test(r)) return 'The card on file has expired. Send the renter a pay link to use a new card.';
  if (/authentication.required|requires_action|3d.?secure|authenticat/i.test(r)) return 'The bank wants the renter to approve this payment. Send the renter a pay link so they can approve it.';
  if (/do.not.honou?r|card.declined|declined|generic_decline|lost|stolen|fraud/i.test(r)) return 'The card was declined by the bank. Send the renter a pay link, or try again later.';
  if (/amount.*(exceed|greater|more than)|amount_too_large/i.test(r)) return 'The amount is more than the hold. Keep up to the amount held, or charge the card on file.';
  if (/already.(been )?captured|already.succeeded|status of succeeded/i.test(r)) return 'This hold was already kept. Reload the booking.';
  if (/no such|resource_missing|not found/i.test(r)) return 'The card processor does not know this card or hold any more. Send the renter a pay link.';
  if (/rate.limit|timeout|network|ECONN|reach/i.test(r)) return 'The card processor did not answer. Nothing changed: try again in a minute.';
  if (/^[A-Z][^{}<>]{0,160}[.!]$/.test(r) && !/PaymentIntent|payment_intent|Stripe|pi_|ch_|cus_|pm_|status of/i.test(r)) return r;
  return what === 'keep' ? 'The card processor refused to keep the deposit. Nothing changed: charge the card on file instead, or try again.'
    : what === 'release' ? 'The card processor refused the release. Nothing changed: try again in a minute.'
    : what === 'hold' ? 'The card processor refused the hold. Nothing changed: send the renter a deposit link instead.'
    : 'The card processor refused the charge. Nothing changed: send the renter a pay link instead.';
}
