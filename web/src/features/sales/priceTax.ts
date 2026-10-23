// Plus tax or tax included, on a price typed by hand (migration 0112). The database does the arithmetic: a price typed
// tax included is kept as its amount before tax, with the rest recorded as HST, so the renter pays exactly that amount.
export type PriceTax = 'plus' | 'included';
export const PRICE_TAX_LABEL: Record<PriceTax, string> = { plus: 'Plus tax', included: 'Tax included' };
export const PRICE_TAX_OPTIONS: Array<[PriceTax, string]> = [['plus', PRICE_TAX_LABEL.plus], ['included', PRICE_TAX_LABEL.included]];
/** The database's split of a typed price (app.price_tax_split). */
export type PriceTaxSplit = { tax: PriceTax; before_tax_cents: number; hst_cents: number; with_tax_cents: number };
export const priceTaxLabel = (t: string | null | undefined) => PRICE_TAX_LABEL[t === 'included' ? 'included' : 'plus'];
