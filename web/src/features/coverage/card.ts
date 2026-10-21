// Credit card rental coverage (Coverage Option 2, Rental Agreement 8.2): only on the card that paid for the
// booking, which must be a credit card (Stripe's card.funding "credit", never debit or prepaid) in the renter's
// name. The database decides (app.card_coverage_check); this module gives the same rule in words for the pages,
// and the staff hint per card type from what Stripe tells us (brand, funding, country), with no outside lookup.

export type Funding = 'credit' | 'debit' | 'prepaid' | 'unknown';
export type CardProblem = 'no_card' | 'not_credit' | 'name_mismatch';
export interface CardFacts { brand: string | null; last4: string | null; funding: Funding | null; cardholder_name: string | null; country?: string | null }

/** The same test as app.same_person_name: letters and digits only, case ignored. */
export function sameName(a: string | null | undefined, b: string | null | undefined): boolean {
  const k = (s: string | null | undefined) => (s ?? '').normalize('NFKD').replace(/[^\p{L}\p{N}]+/gu, '').toLowerCase();
  return !!k(a) && k(a) === k(b);
}

/** Why the card cannot carry the renter's rental coverage, or null when it can. */
export function cardCoverageProblem(card: CardFacts | null, renterName: string | null): CardProblem | null {
  if (!card || !card.last4) return 'no_card';
  if (card.funding !== 'credit') return 'not_credit';
  if (!sameName(card.cardholder_name, renterName)) return 'name_mismatch';
  return null;
}

const BRANDS: Record<string, string> = { visa: 'Visa', mastercard: 'Mastercard', amex: 'American Express', discover: 'Discover', jcb: 'JCB', unionpay: 'UnionPay', diners: 'Diners Club' };
export const brandLabel = (brand: string | null | undefined) => (brand ? BRANDS[brand.toLowerCase()] ?? brand.charAt(0).toUpperCase() + brand.slice(1) : 'Card');
export const cardLabel = (c: Pick<CardFacts, 'brand' | 'last4'>) => `${brandLabel(c.brand)} ending ${c.last4 ?? '????'}`;
export const fundingLabel = (f: Funding | null | undefined) => (f === 'credit' ? 'Credit' : f === 'debit' ? 'Debit' : f === 'prepaid' ? 'Prepaid' : 'Unknown type');

/** The renter's message for a card that cannot be used for coverage (none when it can). */
export function cardCoverageMessage(problem: CardProblem | null, card: CardFacts | null): string | null {
  switch (problem) {
    case null: return null;
    case 'no_card': return 'Pay for the booking with the credit card that has the rental car coverage first.';
    case 'not_credit': return `The card you paid with (${cardLabel(card ?? { brand: null, last4: null })}) is ${card?.funding === 'debit' ? 'a debit' : card?.funding === 'prepaid' ? 'a prepaid' : 'not a credit'} card. Rental coverage counts only on a credit card: choose OPCF 27 on your own auto policy or the Protection Plan instead.`;
    case 'name_mismatch': return 'The card you paid with is not in your name. Credit card rental coverage must be on a card in the renter\'s name: choose OPCF 27 on your own auto policy or the Protection Plan instead.';
  }
}

/** What staff can expect of this card type ("coverage known for this card type"), or null when nothing is known. */
export function cardCoverageHint(card: Pick<CardFacts, 'brand' | 'funding' | 'country'> | null): string | null {
  if (!card) return null;
  if (card.funding === 'debit' || card.funding === 'prepaid') return 'Debit and prepaid cards carry no rental car coverage. Option 2 is not available on this card.';
  if (card.funding !== 'credit') return 'Stripe could not tell whether this is a credit card. Option 2 needs a credit card.';
  const foreign = card.country && card.country !== 'CA' ? ` Issued outside Canada (${card.country}): check that the benefit covers rentals in Ontario.` : '';
  const tail = ' Check the benefit document for the most days per rental and the classes it leaves out (often luxury, exotic and large vans).';
  switch ((card.brand ?? '').toLowerCase()) {
    case 'amex': return 'Coverage known for this card type: most American Express credit cards include rental car damage coverage when the rental is paid in full on the card.' + tail + foreign;
    case 'visa': return 'Coverage known for this card type: depends on the Visa card. Premium cards (Infinite, Avion and similar) usually include it; many basic cards do not.' + tail + foreign;
    case 'mastercard': return 'Coverage known for this card type: depends on the Mastercard. Premium cards (World Elite and similar) usually include it; many basic cards do not.' + tail + foreign;
    case 'discover': case 'jcb': case 'unionpay': case 'diners': return 'Rental car coverage is uncommon on this card type. Ask the renter for the benefit document before approving.' + foreign;
    default: return null;
  }
}
