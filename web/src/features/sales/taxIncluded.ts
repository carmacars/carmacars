// Amounts typed after tax (2026-10-27, migration 0175). Staff often know what the renter paid, HST included ("$270
// after tax for the rental, $50 for the Protection Plan, $320 in all"). The screens take those amounts and work each line
// back to its amount before tax, the way the database does it, so what is sent stays before-tax cents (or the rental
// charge with price_tax 'included', 0112) and the database logic is unchanged. Pure: the screens, the assistant and the
// unit tests share it. The HST rate always comes from the settings (the quote or the booking), never a constant here.

export type TaxMode = 'before' | 'after';
export const TAX_MODE_KEY = 'cc-amounts-typed';
export const TAX_MODE_OPTIONS: Array<[TaxMode, string]> = [['before', 'Before tax'], ['after', 'After tax (HST included)']];

/** amount x bps / 10000, rounded half away from zero (public.calc_bps, so public.calc_hst). */
export function bpsOf(amount: number, bps: number): number {
  const n = Math.abs(Math.trunc(amount)) * Math.max(0, Math.trunc(bps));
  const r = Math.floor((n + 5000) / 10000);
  return amount < 0 ? -r : r;
}
/** The HST on an amount before tax, as each price line carries it. */
export const hstOf = (beforeCents: number, bps: number) => bpsOf(beforeCents, bps);
/** The amount before tax inside an amount that includes HST: round(after / (1 + rate)), half away from zero
 *  (app.price_before_tax). */
export function beforeTax(afterCents: number, bps: number): number {
  const a = Math.abs(Math.trunc(afterCents));
  const den = 10000 + Math.max(0, Math.trunc(bps));
  const r = Math.floor((2 * a * 10000 + den) / (2 * den));
  return afterCents < 0 ? -r : r;
}
/** A line's amount with its HST (none when HST does not apply to it). */
export const withTax = (beforeCents: number, bps: number, hst = true) => beforeCents + (hst ? hstOf(beforeCents, bps) : 0);
/** The rental charge typed tax included, split as the database keeps it: the amount before tax, the HST what is left
 *  (so before + HST is exactly the amount typed). */
export function splitIncluded(withTaxCents: number, bps: number): { before: number; hst: number; with: number } {
  const before = beforeTax(withTaxCents, bps);
  return { before, hst: withTaxCents - before, with: withTaxCents };
}

/** A typed amount (cents) as the database takes it: before tax. After tax only changes lines HST applies to. */
export function toBeforeTax(typedCents: number, mode: TaxMode, hst: boolean, bps: number): number {
  return mode === 'after' && hst ? beforeTax(typedCents, bps) : typedCents;
}
/** What to show in a box after the toggle changes, so the box keeps meaning the same money. */
export function convertTyped(typedCents: number, from: TaxMode, to: TaxMode, hst: boolean, bps: number): number {
  if (from === to || !hst) return typedCents;
  return to === 'after' ? withTax(typedCents, bps) : beforeTax(typedCents, bps);
}

/** Lines typed after tax, worked back to before tax. A line typed after tax may land a cent away from the amount typed
 *  once its own HST is rounded (before + HST of before); residual is the sum of those cents, for the rental charge to
 *  take so the total is still what was typed. */
export function linesBeforeTax(lines: Array<{ key: string; typed: number; hst: boolean }>, mode: TaxMode, bps: number): { cents: Record<string, number>; residual: number } {
  const out: Record<string, number> = {};
  let residual = 0;
  for (const l of lines) {
    const before = toBeforeTax(l.typed, mode, l.hst, bps);
    out[l.key] = before;
    if (mode === 'after' && l.hst) residual += l.typed - withTax(before, bps);
  }
  return { cents: out, residual };
}

/** The rental charge (tax included) that makes the total come to the target: the other lines are kept as they are and
 *  the rounding goes on the rental line. totalNow: the total priced with rentalWithTaxNow as the rental line (its amount
 *  plus its HST). The lines that follow the rental charge (a non-refundable discount, a promo code) move with it, so a
 *  second step may be needed: call it again with the new total until the difference is 0. null: the target is below the
 *  other lines (no rental charge can make it). */
export function solveRental(target: number, totalNow: number, rentalWithTaxNow: number): number | null {
  const w = rentalWithTaxNow + (target - totalNow);
  return w < 0 ? null : w;
}

/** The price lines' before-tax breakdown, for the live summary under the total typed. */
export function breakdown(lines: Array<{ amount_cents: number; hst_cents: number }>): { subtotal: number; hst: number; total: number } {
  const subtotal = lines.reduce((s, l) => s + l.amount_cents, 0);
  const hst = lines.reduce((s, l) => s + l.hst_cents, 0);
  return { subtotal, hst, total: subtotal + hst };
}

/** Dollars typed as cents ("$1,250.50" is 125050); empty or not a number: null. */
export function dollarsToCents(s: string | null | undefined): number | null {
  const t = String(s ?? '').replace(/[$,\s]/g, '');
  if (!t) return null;
  const n = Number(t);
  return Number.isFinite(n) && n >= 0 ? Math.round(n * 100) : null;
}
export const centsToDollars = (c: number) => (c / 100).toFixed(2);

/** The staff member's last choice on this device (a private window or blocked storage: before tax). */
export function readTaxMode(): TaxMode {
  try { return globalThis.localStorage?.getItem(TAX_MODE_KEY) === 'after' ? 'after' : 'before'; } catch { return 'before'; }
}
export function saveTaxMode(m: TaxMode): void {
  try { globalThis.localStorage?.setItem(TAX_MODE_KEY, m); } catch { /* private window */ }
}

/** The difference between the total the database priced and the total typed, in words ('' when they match). */
export function totalDifference(serverTotal: number, typedTotal: number | null, money: (c: number) => string): string {
  if (typedTotal === null) return '';
  const d = serverTotal - typedTotal;
  if (d === 0) return '';
  return `The total priced is ${money(serverTotal)}: ${money(Math.abs(d))} ${d > 0 ? 'more' : 'less'} than the ${money(typedTotal)} typed.`;
}
