// The charges CarmaCars bills an insurer on an insurance replacement rental (migration 0191): VLF, LDW, T&LDW, PAP/PEC
// and Waiver Saver. Staff type a rate a day on each insurer booking (no default price); the line is the rate times the
// rental days, plus HST. The database refuses them on a booking the renter pays. Pure: Add a rental, the review screen,
// the booking's Insurance replacement card and the unit tests share it.
// Relative imports with their extension: the unit tests run this file in Node directly.

export type InsurerFeeCode = 'vlf' | 'ldw' | 'tldw' | 'pap_pec' | 'waiver_saver';

/** In the order of the form; `box` is where Blind Spot's agreement prints it. */
export const INSURER_FEES: ReadonlyArray<{ code: InsurerFeeCode; short: string; label: string; box: string }> = [
  { code: 'vlf', short: 'VLF', label: 'VLF (vehicle licence fee)', box: '43' },
  { code: 'ldw', short: 'LDW', label: 'LDW (loss damage waiver)', box: '45' },
  { code: 'tldw', short: 'T&LDW', label: 'T&LDW (theft and loss damage waiver)', box: '46' },
  { code: 'pap_pec', short: 'PAP/PEC', label: 'PAP/PEC (personal accident and effects coverage)', box: '47' },
  { code: 'waiver_saver', short: 'Waiver Saver', label: 'Waiver Saver', box: 'Waiver Saver' }
];
export const INSURER_FEE_CODES: ReadonlySet<string> = new Set(INSURER_FEES.map((f) => f.code));
export const isInsurerFee = (code: string | null | undefined): boolean => !!code && INSURER_FEE_CODES.has(code);

/** A rate typed in dollars ("12", "$12.50") in cents; null: empty or not a number (0 is none). */
export function rateCents(typed: string | null | undefined): number | null {
  const t = String(typed ?? '').replace(/[$,\s]/g, '');
  if (!t) return null;
  if (!/^\d+(\.\d{0,2})?$/.test(t)) return null;
  return Math.round(Number(t) * 100);
}

/** The rates typed ({code: dollars}) as the database takes them ({code: cents a day}); an empty or 0 box is none. Only
 *  the boxes that differ from `before` (the booking's rates, in cents) are sent, an emptied one as null; a box that is
 *  not a number is left out (the screen says so under it). */
export function insurerFeesPayload(typed: Record<string, string>, before: Record<string, number> = {}): Record<string, number | null> {
  const out: Record<string, number | null> = {};
  for (const f of INSURER_FEES) {
    if (rateProblem(typed[f.code])) continue;
    const now = rateCents(typed[f.code]) || null;
    const was = before[f.code] ?? null;
    if (now !== was) out[f.code] = now;
  }
  return out;
}

/** Every rate the booking has, removed (a booking going back to the renter). */
export function insurerFeesRemoval(before: Record<string, number> = {}): Record<string, null> {
  return Object.fromEntries(Object.keys(before).filter((k) => INSURER_FEE_CODES.has(k)).map((k) => [k, null]));
}

/** A rate typed that is not a number (shown under the box). */
export function rateProblem(typed: string | null | undefined): string | null {
  return String(typed ?? '').trim() && rateCents(typed) === null ? 'Type the rate a day in dollars and cents, for example 12.50.' : null;
}

/** "= $36.00 for 3 days" under a box: the rate times the days. */
export function feeForDays(rate: number | null, days: number, money: (c: number) => string): string {
  if (!rate || !(days > 0)) return '';
  return `= ${money(rate * days)} for ${days} day${days === 1 ? '' : 's'}`;
}

/** The rates a booking has, as the boxes start ({code: dollars}). */
export function typedFrom(rates: Record<string, number> | null | undefined): Record<string, string> {
  return Object.fromEntries(Object.entries(rates ?? {}).filter(([k, v]) => INSURER_FEE_CODES.has(k) && v > 0).map(([k, v]) => [k, (v / 100).toFixed(2)]));
}
