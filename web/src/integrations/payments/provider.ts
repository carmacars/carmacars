// r50: the card provider seam. Stripe closed the account, so cards move to Helcim (helcim.ts); Stripe stays selectable in
// case it is restored, and "off" takes no card at all (the e-Transfer fallback of hotfix-nocard). One switch,
// PAYMENTS_PROVIDER, read here only: every card form, the webhook routes and the connector ask cardProvider().
// Pure (no server-only import) so the unit tests and the e-Transfer fallback can share it.

export type CardProvider = 'stripe' | 'helcim' | 'off' | 'fake';

export interface ProviderEnv {
  PAYMENTS_PROVIDER?: string;
  APP_ENV?: string;
  STRIPE_SECRET_KEY?: string;
  HELCIM_API_TOKEN?: string;
}

/** Which processor takes cards. A processor with no key is off (never a half-configured processor): helcim without
 *  HELCIM_API_TOKEN, stripe without STRIPE_SECRET_KEY. The fake is for local work and tests and never in production. */
export function cardProvider(e: ProviderEnv): CardProvider {
  const p = e.PAYMENTS_PROVIDER ?? 'fake';
  if (p === 'helcim') return e.HELCIM_API_TOKEN ? 'helcim' : 'off';
  if (p === 'stripe') return e.STRIPE_SECRET_KEY ? 'stripe' : 'off';
  if (p === 'off') return 'off';
  return e.APP_ENV === 'production' ? 'off' : 'fake';
}

/** Whether cards can be taken at all (the e-Transfer fallback shows instead when not). */
export const cardsOn = (p: CardProvider): boolean => p !== 'off';

/** The hold window of each processor, in days: how long an authorization can wait for its capture. Helcim: preauthorized
 *  payments must be captured within 7 days or they expire (devdocs.helcim.com, Preauthorize a Credit Card Payment). Stripe:
 *  7 days, up to about 30 with an extended authorization. A deposit for a rental longer than the window is charged and
 *  refunded at release instead of held (helcim.ts, holdPlan). */
export function holdWindowDays(p: CardProvider, extended = false): number {
  if (p === 'stripe') return extended ? 30 : 7;
  return 7;
}

/** The error a card call throws when cards are off: the pages say "pay by e-Transfer" instead of failing. */
export class CardsOffError extends Error {
  readonly code = 'cards_off';
  constructor() { super('Card payments are not available right now. Pay by Interac e-Transfer instead: the booking page shows how.'); }
}
