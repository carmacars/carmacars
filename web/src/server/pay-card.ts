// Staff pay links take the same cards as the booking's pay page (2026-10-30, migration 0213: server_payreq_card_ok): what
// to do with the card once Stripe has authorized it. A charge is authorized first (manual capture) so a card refused is
// never charged; a hold refused is voided. Saving a card is not concerned.
export type PayCardStep = 'refuse' | 'capture' | 'settle';
export const CARD_NOT_CREDIT = 'Please use a credit card. Debit and prepaid cards cannot be used for a rental. Nothing was charged.';

export function payCardStep(kind: 'charge' | 'hold' | 'setup', status: string, cardOk: boolean): PayCardStep {
  if (kind === 'setup') return 'settle';
  const authorized = status === 'requires_capture' || status === 'succeeded';
  if (authorized && !cardOk) return 'refuse';
  if (kind === 'charge' && status === 'requires_capture') return 'capture';
  return 'settle';
}
