// Staff pay links take the same cards as the booking's pay page (2026-10-30, migration 0213: server_payreq_card_ok): what
// to do with the card once Stripe has authorized it. A charge is authorized first (manual capture) so a card refused is
// never charged; a hold refused is voided. Saving a card is not concerned.
export type PayCardStep = 'refuse' | 'capture' | 'settle';
export const CARD_NOT_CREDIT = 'Please use a credit card. If you only have a debit or prepaid card, contact us. Nothing was charged.';

export function payCardStep(kind: 'charge' | 'hold' | 'setup', status: string, cardOk: boolean): PayCardStep {
  if (kind === 'setup') return 'settle';
  const authorized = status === 'requires_capture' || status === 'succeeded';
  if (authorized && !cardOk) return 'refuse';
  if (kind === 'charge' && status === 'requires_capture') return 'capture';
  return 'settle';
}

// 0262: the deposit hold on a debit or prepaid card is higher (Program settings, Deposit with a debit or prepaid card).
// A hold authorized for another amount than the card needs is asked again for the right amount.
export function holdAmountStep(authorizedCents: number, neededCents: number | null | undefined): { reask: false } | { reask: true; amountCents: number } {
  if (!neededCents || neededCents <= 0 || neededCents === authorizedCents) return { reask: false };
  return { reask: true, amountCents: neededCents };
}
const dollars = (c: number) => `$${(c / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
export function holdAmountMessage(funding: string | null | undefined, cents: number): string {
  return funding === 'debit' || funding === 'prepaid'
    ? `With a debit or prepaid card the deposit hold is ${dollars(cents)}. Nothing was held: enter the card again to place it.`
    : `With a credit card the deposit hold is ${dollars(cents)}. Nothing was held: enter the card again to place it.`;
}

/** r42: the words Stripe gives the renter's browser when it refuses the extended authorization of a deposit hold as the
 *  card is confirmed (the refusal of 2026-10-30). An ordinary decline never matches: only this makes the pay page ask
 *  for the same hold again as a standard one. */
export function extendedRefusedText(message: string | null | undefined): boolean {
  return /not eligible for the requested card features|extended authori[sz]ation|request_extended_authorization/i.test(message ?? '');
}
